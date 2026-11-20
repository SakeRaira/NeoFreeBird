//
//  Chat.x
//  NeoFreeBird
//
//  XChat's typing indicator has two carriers: a one-off POST to the
//  jot/client_event analytics endpoint, and a periodic push over the
//  persistent chat-ws.x.com websocket. The jot POST is blocked outright
//  below (a normal NSURLSession data task). The websocket also carries
//  message delivery/read-receipts/presence, so it can't be blocked outright
//  -- instead, only the specific outgoing frame shape used for the typing
//  heartbeat is dropped; everything else on the socket passes through
//  untouched. See the field-shape comment on isTypingIndicatorFrame for how
//  that shape was identified.
//

#import <mach-o/dyld.h>
#import <string.h>
#import "HookHelpers.h"

// MARK: - Hide typing indicator

%hook Subsystem_ios_iosArm64_mainXChatConnectionManagerImpl
- (void)onMeTypingConversationId:(id)conversationID {
    if ([BHTSettings boolForKey:@"hide_typing_indicator"]) return;
    %orig(conversationID);
}
%end

// MARK: - No read receipts

// XChat's shared (Kotlin) code reports how far you've read a conversation
// through one LastSeenSendHandler: automatically as messages scroll into view
// (maybeUpdateLastSeenByMe...), and from the inbox's Mark as read. That is
// what the other side sees as "Seen", so with the option on neither is sent.
// The conversation then stays unread on your side too; Mark as unread is left
// alone.
//
// The implementing class is Kotlin's and isn't in the class dump, so it's
// found by name in the app's own images, without realizing every class
// (objc_copyClassList would, which costs a lot in an app this size).

static const char* const kKotlinExportPrefix = "Subsystem_ios_iosArm64_main";

static BOOL ReadReceiptsBlocked(void) {
    return [BHTSettings boolForKey:@"no_dm_read_receipts"];
}

static BOOL ClassConformsToProtocolDeep(Class cls, Protocol* protocol) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if (class_conformsToProtocol(current, protocol)) {
            return YES;
        }
    }
    return NO;
}

static void BlockOneArgumentSelector(Class cls, SEL selector) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return;
    }
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id receiver, id argument) {
        if (ReadReceiptsBlocked()) {
            return;
        }
        ((void (*)(id, SEL, id))original)(receiver, selector, argument);
    });
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}

static void BlockLastSeenUpdates(Class cls) {
    SEL selector = @selector(maybeUpdateLastSeenByMeConvId:visibleReadableSequenceNumbers:scrolledToBottom:previewLatestSeqNum:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return;
    }
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id receiver, id conversationID, id sequenceNumbers,
                                                    BOOL scrolledToBottom, id latestSequenceNumber) {
        if (ReadReceiptsBlocked()) {
            return;
        }
        ((void (*)(id, SEL, id, id, BOOL, id))original)(receiver, selector, conversationID, sequenceNumbers,
                                                        scrolledToBottom, latestSequenceNumber);
    });
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}

static BOOL NameMayBeLastSeenHandler(const char* name) {
    return strncmp(name, kKotlinExportPrefix, strlen(kKotlinExportPrefix)) == 0 &&
           (strstr(name, "Seen") || strstr(name, "ReadReceipt") || strstr(name, "MarkRead") ||
            strstr(name, "ReadState"));
}

// Safe to call more than once: it stops looking after a successful pass, and
// a pass that finds nothing (the image not loaded yet) is tried again later.
static void HookLastSeenSendHandlers(void) {
    static BOOL hooked = NO;
    if (hooked) {
        return;
    }

    Protocol* protocol = objc_getProtocol("Subsystem_ios_iosArm64_mainLastSeenSendHandler");
    // Matched by the bundle's own folder name: dyld and NSBundle can spell
    // the path up to it differently (/var against /private/var).
    NSString* bundleName = NSBundle.mainBundle.bundlePath.lastPathComponent;
    if (!protocol || bundleName.length == 0) {
        return;
    }
    char bundleFolder[PATH_MAX];
    snprintf(bundleFolder, sizeof(bundleFolder), "/%s/", bundleName.fileSystemRepresentation);

    NSUInteger found = 0;
    void (^blockReceiptsIn)(Class) = ^(Class cls) {
        BlockOneArgumentSelector(cls, @selector(markReadConvId:));
        BlockOneArgumentSelector(cls, @selector(markReadConvIds:));
        BlockLastSeenUpdates(cls);
    };

    // Classes the Kotlin runtime registers itself aren't listed under any
    // image; try the usual names for those.
    for (NSString* guess in @[@"LastSeenSendHandlerImpl", @"DefaultLastSeenSendHandler",
                              @"RealLastSeenSendHandler", @"LastSeenSendHandlerImplementation"]) {
        NSString* name = [@(kKotlinExportPrefix) stringByAppendingString:guess];
        Class cls = objc_getClass(name.UTF8String);
        if (cls && ClassConformsToProtocolDeep(cls, protocol)) {
            blockReceiptsIn(cls);
            found++;
        }
    }
    if (found > 0) {
        hooked = YES;
        return;
    }

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char* imagePath = _dyld_get_image_name(i);
        if (!imagePath || !strstr(imagePath, bundleFolder)) {
            continue;
        }

        unsigned int classCount = 0;
        const char** names = objc_copyClassNamesForImage(imagePath, &classCount);
        for (unsigned int j = 0; names && j < classCount; j++) {
            if (!NameMayBeLastSeenHandler(names[j])) {
                continue;
            }

            Class cls = objc_getClass(names[j]);
            if (!cls || !ClassConformsToProtocolDeep(cls, protocol)) {
                continue;
            }
            blockReceiptsIn(cls);
            found++;
        }
        free(names);
    }

    hooked = found > 0;
}

// MARK: - Tint chat buttons

static void nfb_applyChatScreenTint(UIView* view) {
    if ([BHTSettings boolForKey:@"tab_bar_theming"]) {
        view.tintColor = CurrentAccentColor();
    }
}

%hook TFNBarButtonItemButton
- (void)didMoveToWindow {
    %orig;
    nfb_applyChatScreenTint(self);
}
%end

// MARK: - Chat screenshot protection

static NSInteger nfb_secureEntrySuppression = 0;

static void* NFBNeutralizedCanvasKey = &NFBNeutralizedCanvasKey;

static void nfb_disableSecureCanvas(UIView* protectionView) {
    UIView* canvas = nfb_objectIvar(protectionView, "secureCanvasView");
    if (!canvas ||
        objc_getAssociatedObject(protectionView, NFBNeutralizedCanvasKey) == canvas) {
        return;
    }

    // The field is kept in a separate ivar (it has to be retained somewhere for
    // the canvas to keep working)
    UITextField* owner = nil;
    unsigned int count = 0;
    Ivar* ivars = class_copyIvarList(object_getClass(protectionView), &count);
    for (unsigned int i = 0; i < count && !owner; i++) {
        const char* type = ivar_getTypeEncoding(ivars[i]);
        if (!type || type[0] != '@') {
            continue;
        }
        id value = object_getIvar(protectionView, ivars[i]);
        if ([value isKindOfClass:[UITextField class]]) {
            owner = value;
        }
    }
    free(ivars);

    if (!owner && [canvas.superview isKindOfClass:[UITextField class]]) {
        owner = (UITextField*)canvas.superview;
    }

    if (owner) {
        owner.secureTextEntry = NO;
    } else {
        for (UIView* content in [canvas.subviews copy]) {
            BOOL usesAutoLayout = !content.translatesAutoresizingMaskIntoConstraints;
            CGRect frame = [canvas convertRect:content.frame toView:protectionView];
            [protectionView addSubview:content];
            if (usesAutoLayout) {
                [NSLayoutConstraint activateConstraints:@[
                    [content.leadingAnchor constraintEqualToAnchor:protectionView.leadingAnchor],
                    [content.trailingAnchor constraintEqualToAnchor:protectionView.trailingAnchor],
                    [content.topAnchor constraintEqualToAnchor:protectionView.topAnchor],
                    [content.bottomAnchor constraintEqualToAnchor:protectionView.bottomAnchor],
                ]];
            } else {
                content.frame = frame;
                content.autoresizingMask =
                    UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            }
        }
        [canvas removeFromSuperview];
    }

    objc_setAssociatedObject(protectionView, NFBNeutralizedCanvasKey, canvas,
                             OBJC_ASSOCIATION_ASSIGN);
}

static BOOL nfb_shouldDropScreenshotProtection(UIView* protectionView) {
    if ([BHTSettings boolForKey:@"block_screenshot_detection"]) {
        return YES;
    }
    return !nfb_boolIvar(protectionView, "isProtectionEnabled", YES);
}

%hook UITextField
- (void)setSecureTextEntry:(BOOL)secure {
    if (secure && nfb_secureEntrySuppression > 0) {
        %orig(NO);
        return;
    }
    %orig;
}
%end

%hook _TtC16ChatConversation24ScreenshotProtectionView

- (void)didMoveToWindow {
    BOOL drop = nfb_shouldDropScreenshotProtection(self);
    if (drop) {
        if ([BHTSettings boolForKey:@"block_screenshot_detection"]) {
            nfb_setBoolIvar(self, "isProtectionEnabled", NO);
        }
        nfb_secureEntrySuppression++;
    }
    %orig;
    if (drop) {
        nfb_secureEntrySuppression--;
        nfb_disableSecureCanvas(self);
    }
}

- (void)layoutSubviews {
    BOOL drop = nfb_shouldDropScreenshotProtection(self);
    if (drop) {
        nfb_secureEntrySuppression++;
    }
    %orig;
    if (drop) {
        nfb_secureEntrySuppression--;
        nfb_disableSecureCanvas(self);
    }
}

%end

%ctor {
    %init;

    HookLastSeenSendHandlers();
    // In case the chat framework is loaded after launch.
    dispatch_async(dispatch_get_main_queue(), ^{
        HookLastSeenSendHandlers();
    });
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* notification) {
                                                    HookLastSeenSendHandlers();
                                                }];
}

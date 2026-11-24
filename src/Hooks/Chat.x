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
// The handler's class is Kotlin's and usually not one the app ships: Kotlin
// makes an Objective-C class for it at runtime ("kobjcc<n>") the first time
// it hands the object over, right before the screen uses it. So the handler
// is caught three ways:
//  - the chat object graph's -lastSeenSendHandler getter is wrapped, and
//    hooks the class of whatever handler it returns before returning it;
//  - classes Kotlin has already made are looked up by name, cheaply, one by
//    one (no objc_copyClassList, which would realize every class in the app);
//  - classes the app ships are found in its own images.
// Every hook is recorded, with a count of blocked calls, for the status row
// in the chat settings.

static const char* const kKotlinExportPrefix = "Subsystem_ios_iosArm64_main";
static const char* const kHandlerProtocolName = "Subsystem_ios_iosArm64_mainLastSeenSendHandler";
static const char* const kGraphProtocolName = "Subsystem_ios_iosArm64_mainBaseDmObjectGraph";

static NSString* const kReadReceiptsStatusKey = @"no_dm_read_receipts_status";

static NSMutableSet<NSString*>* HookedHandlerClasses;
static NSMutableSet<NSString*>* HookedGraphClasses;
static NSObject* ReadReceiptsLock;
static volatile long BlockedReadReceipts;

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

// A short summary for the settings row, kept in the defaults so the generic
// page can show it.
static void UpdateReadReceiptsStatus(void) {
    NSString* key;
    @synchronized(ReadReceiptsLock) {
        if (HookedHandlerClasses.count > 0) {
            key = @"READ_RECEIPTS_STATUS_ACTIVE";
        } else if (HookedGraphClasses.count > 0) {
            key = @"READ_RECEIPTS_STATUS_WAITING";
        } else {
            key = @"READ_RECEIPTS_STATUS_NOT_FOUND";
        }
    }
    NSString* summary = [[BHTBundle sharedBundle] localizedStringForKey:key];
    long blocked = __atomic_load_n(&BlockedReadReceipts, __ATOMIC_RELAXED);
    if (blocked > 0) {
        NSString* format = [[BHTBundle sharedBundle] localizedStringForKey:@"READ_RECEIPTS_STATUS_BLOCKED_FORMAT"];
        summary = [NSString stringWithFormat:format, summary, blocked];
    }
    [NSUserDefaults.standardUserDefaults setObject:summary forKey:kReadReceiptsStatusKey];
}

// What was hooked and how often it stopped a read marker, for the alert
// behind the status row.
NSString* BHTReadReceiptsStatusDetail(void) {
    NSArray* handlers;
    NSArray* graphs;
    @synchronized(ReadReceiptsLock) {
        handlers = HookedHandlerClasses.allObjects ?: @[];
        graphs = HookedGraphClasses.allObjects ?: @[];
    }
    return [NSString stringWithFormat:@"handler: %@\ngraph: %@\nblocked: %ld",
                                      handlers.count ? [handlers componentsJoinedByString:@", "] : @"-",
                                      graphs.count ? [graphs componentsJoinedByString:@", "] : @"-",
                                      __atomic_load_n(&BlockedReadReceipts, __ATOMIC_RELAXED)];
}

static void CountBlockedReadReceipt(void) {
    long blocked = __atomic_add_fetch(&BlockedReadReceipts, 1, __ATOMIC_RELAXED);
    // The summary only needs to move now and then.
    if (blocked <= 3 || blocked % 20 == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UpdateReadReceiptsStatus();
        });
    }
}

static void BlockOneArgumentSelector(Class cls, SEL selector) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return;
    }
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id receiver, id argument) {
        if (ReadReceiptsBlocked()) {
            CountBlockedReadReceipt();
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
            CountBlockedReadReceipt();
            return;
        }
        ((void (*)(id, SEL, id, id, BOOL, id))original)(receiver, selector, conversationID, sequenceNumbers,
                                                        scrolledToBottom, latestSequenceNumber);
    });
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}

// Once per class; the getter below calls this every time a handler passes.
static void HookHandlerClass(Class cls) {
    if (!cls) {
        return;
    }
    NSString* name = NSStringFromClass(cls);
    @synchronized(ReadReceiptsLock) {
        if ([HookedHandlerClasses containsObject:name]) {
            return;
        }
        [HookedHandlerClasses addObject:name];
        BlockOneArgumentSelector(cls, @selector(markReadConvId:));
        BlockOneArgumentSelector(cls, @selector(markReadConvIds:));
        BlockLastSeenUpdates(cls);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UpdateReadReceiptsStatus();
    });
}

static void HookGraphClass(Class cls) {
    SEL getter = @selector(lastSeenSendHandler);
    Method method = cls ? class_getInstanceMethod(cls, getter) : NULL;
    if (!method) {
        return;
    }
    NSString* name = NSStringFromClass(cls);
    @synchronized(ReadReceiptsLock) {
        if ([HookedGraphClasses containsObject:name]) {
            return;
        }
        [HookedGraphClasses addObject:name];
        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^id(id receiver) {
            id handler = ((id (*)(id, SEL))original)(receiver, getter);
            if (handler) {
                HookHandlerClass(object_getClass(handler));
            }
            return handler;
        });
        class_replaceMethod(cls, getter, replacement, method_getTypeEncoding(method));
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UpdateReadReceiptsStatus();
    });
}

static void ConsiderReadReceiptClass(Class cls, Protocol* handlerProtocol, Protocol* graphProtocol) {
    if (!cls) {
        return;
    }
    if (ClassConformsToProtocolDeep(cls, handlerProtocol)) {
        HookHandlerClass(cls);
    } else if (graphProtocol && ClassConformsToProtocolDeep(cls, graphProtocol)) {
        HookGraphClass(cls);
    }
}

static BOOL NameMayBeReadReceiptClass(const char* name) {
    return strncmp(name, kKotlinExportPrefix, strlen(kKotlinExportPrefix)) == 0 &&
           (strstr(name, "Seen") || strstr(name, "ReadReceipt") || strstr(name, "MarkRead") ||
            strstr(name, "ReadState") || strstr(name, "Graph") || strstr(name, "Component"));
}

// The classes the app ships, from its own images. They don't change, so this
// runs once.
static void ScanImagesForReadReceiptClasses(Protocol* handlerProtocol, Protocol* graphProtocol) {
    static BOOL scanned = NO;
    if (scanned) {
        return;
    }
    // Matched by the bundle's own folder name: dyld and NSBundle can spell
    // the path up to it differently (/var against /private/var).
    NSString* bundleName = NSBundle.mainBundle.bundlePath.lastPathComponent;
    if (bundleName.length == 0) {
        return;
    }
    scanned = YES;
    char bundleFolder[PATH_MAX];
    snprintf(bundleFolder, sizeof(bundleFolder), "/%s/", bundleName.fileSystemRepresentation);

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char* imagePath = _dyld_get_image_name(i);
        if (!imagePath || !strstr(imagePath, bundleFolder)) {
            continue;
        }
        unsigned int classCount = 0;
        const char** names = objc_copyClassNamesForImage(imagePath, &classCount);
        for (unsigned int j = 0; names && j < classCount; j++) {
            if (NameMayBeReadReceiptClass(names[j])) {
                ConsiderReadReceiptClass(objc_getClass(names[j]), handlerProtocol, graphProtocol);
            }
        }
        free(names);
    }
}

// Classes Kotlin has made at runtime so far, numbered from 0 with no gaps.
// Each lookup is one hash probe; classes already hooked are skipped.
static void ScanKotlinRuntimeClasses(Protocol* handlerProtocol, Protocol* graphProtocol) {
    unsigned int misses = 0;
    for (unsigned int n = 0; n < 100000 && misses < 64; n++) {
        char name[32];
        snprintf(name, sizeof(name), "kobjcc%u", n);
        Class cls = objc_lookUpClass(name);
        if (!cls) {
            misses++;
            continue;
        }
        misses = 0;
        ConsiderReadReceiptClass(cls, handlerProtocol, graphProtocol);
    }
}

// Safe to call any number of times; each pass only adds hooks.
static void HookLastSeenSendHandlers(void) {
    Protocol* handlerProtocol = objc_getProtocol(kHandlerProtocolName);
    Protocol* graphProtocol = objc_getProtocol(kGraphProtocolName);
    if (!handlerProtocol) {
        return;
    }
    if (!ReadReceiptsLock) {
        ReadReceiptsLock = [NSObject new];
        HookedHandlerClasses = [NSMutableSet set];
        HookedGraphClasses = [NSMutableSet set];
    }
    ScanImagesForReadReceiptClasses(handlerProtocol, graphProtocol);
    ScanKotlinRuntimeClasses(handlerProtocol, graphProtocol);
    UpdateReadReceiptsStatus();
}

// Opening Chats looks again, before a conversation is opened from there.
%hook _TtC14T1TwitterSwift27XChatDMNavigationController

- (void)viewWillAppear:(BOOL)animated {
    HookLastSeenSendHandlers();
    %orig;
}

%end

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

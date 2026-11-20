//
//  TweetLog.x
//  NeoFreeBird
//
//  Records the Tweets shown in the timeline (BHTTweetLog) and adds a tab
//  listing them to the sidebar's History.
//

#import "HookHelpers.h"
#import "Core/BHTTweetLog.h"
#import "Settings/Pages/TweetLogViewController.h"

// MARK: - Recording

static const void* LastRecordedStatusIDKey = &LastRecordedStatusIDKey;

static BOOL IsInHomeTimeline(UIViewController* controller) {
    Class homeClass =
        NSClassFromString(@"_TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController");
    if (!homeClass) {
        return NO;
    }
    for (UIViewController* current = controller; current; current = current.parentViewController) {
        if ([current isKindOfClass:homeClass]) {
            return YES;
        }
    }
    return NO;
}

// The TFNTwitterStatus behind a cell's status view, which may hold it
// directly or through a view model or two.
static id DisplayedStatus(T1StatusCell* cell) {
    Class statusClass = objc_getClass("TFNTwitterStatus");
    UIView* statusView = [cell respondsToSelector:@selector(statusView)] ? cell.statusView : nil;
    id object = BHTSafeObject(statusView, @selector(viewModel));

    for (NSUInteger depth = 0; object && statusClass && depth < 4; depth++) {
        if ([object isKindOfClass:statusClass]) {
            return object;
        }
        id next = nil;
        for (NSString* name in @[@"statusViewModel", @"tweet", @"status"]) {
            next = BHTSafeObject(object, NSSelectorFromString(name));
            if (next && next != object) {
                break;
            }
            next = nil;
        }
        object = next;
    }
    return nil;
}

static NSString* FirstString(id object, NSArray<NSString*>* selectors) {
    for (NSString* name in selectors) {
        NSString* value = BHTSafeString(object, NSSelectorFromString(name));
        if (value.length > 0) {
            return value;
        }
    }
    return nil;
}

static NSString* UserDisplayName(id user) {
    return FirstString(user, @[@"displayFullName", @"fullName"]);
}

static NSArray<NSDictionary*>* MediaOfStatus(id status) {
    NSArray* media = BHTSafeObject(BHTSafeObject(status, @selector(entities)), @selector(media));
    if (![media isKindOfClass:NSArray.class]) {
        return @[];
    }

    NSMutableArray* items = [NSMutableArray array];
    for (id item in media) {
        NSString* url = FirstString(item, @[@"mediaURL", @"imageURLString"]);
        if (url.length == 0) {
            continue;
        }
        BOOL video = BHTSafeObject(item, @selector(videoInfo)) != nil;
        [items addObject:@{@"url": url, @"video": @(video)}];
        if (items.count == 4) {
            break;
        }
    }
    return items;
}

// A property-list snapshot of what the timeline showed. For a retweet, the
// retweeted post, with who retweeted it.
static NSDictionary* LogEntryForStatus(id status) {
    id shown = status;
    NSString* retweetedBy = nil;
    if (BHTSafeBool(status, @selector(isRetweet))) {
        id original = BHTSafeObject(status, @selector(representedStatus))
                          ?: BHTSafeObject(status, @selector(retweetedStatus));
        if (original && original != status) {
            retweetedBy = UserDisplayName(BHTSafeObject(status, @selector(fromUser)));
            shown = original;
        }
    }

    long long statusID = BHTSafeLongLong(shown, @selector(statusID));
    if (statusID <= 0) {
        return nil;
    }

    id user = BHTSafeObject(shown, @selector(fromUser));
    NSMutableDictionary* entry = [NSMutableDictionary dictionary];
    entry[@"id"] = [NSString stringWithFormat:@"%lld", statusID];
    entry[@"name"] = UserDisplayName(user) ?: @"";
    entry[@"handle"] = FirstString(user, @[@"username"]) ?: BHTSafeString(shown, @selector(fromUserName)) ?: @"";

    NSString* avatar = BHTSafeString(BHTSafeObject(user, @selector(profileImageMediaEntity)), @selector(mediaURL));
    if (avatar.length > 0) {
        entry[@"avatar"] = avatar;
    }

    NSString* longText = BHTSafeString(BHTSafeObject(shown, @selector(noteTweet)), @selector(text));
    entry[@"text"] = longText.length > 0
                         ? longText
                         : (FirstString(shown, @[@"displayText", @"textWithExpandedURLs", @"fullText", @"text"]) ?: @"");

    id date = BHTSafeObject(shown, @selector(date));
    if ([date isKindOfClass:NSDate.class]) {
        entry[@"date"] = date;
    }

    entry[@"media"] = MediaOfStatus(shown);
    entry[@"replies"] = @(BHTSafeLongLong(shown, @selector(replyCount)));
    entry[@"retweets"] = @(BHTSafeLongLong(shown, @selector(retweetCount)));
    entry[@"likes"] = @(BHTSafeLongLong(shown, @selector(favoriteCount)));
    if (retweetedBy.length > 0) {
        entry[@"rtBy"] = retweetedBy;
    }
    return entry;
}

static void RecordDisplayedCell(T1StatusCell* cell, id dataViewController) {
    if (!BHTTweetLog.enabled) {
        return;
    }
    if (![BHTSettings boolForKey:BHTTweetLogAllScreensKey] &&
        !([dataViewController isKindOfClass:UIViewController.class] && IsInHomeTimeline(dataViewController))) {
        return;
    }

    id status = DisplayedStatus(cell);
    if (!status || BHTSafeBool(status, @selector(isPromoted))) {
        return;
    }

    // The same cell reports the same post repeatedly while it stays visible.
    NSNumber* statusID = @(BHTSafeLongLong(status, @selector(statusID)));
    if ([objc_getAssociatedObject(cell, LastRecordedStatusIDKey) isEqual:statusID]) {
        return;
    }
    objc_setAssociatedObject(cell, LastRecordedStatusIDKey, statusID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSDictionary* entry = LogEntryForStatus(status);
    if (entry) {
        [BHTTweetLog recordEntry:entry];
    }
}

%hook T1StatusCell

- (void)didDisplayInDataViewController:(id)controller
                           atIndexPath:(id)indexPath
                   visibleIntersection:(CGRect)intersection {
    %orig;
    @try {
        RecordDisplayedCell(self, controller);
    } @catch (__unused NSException* exception) {
    }
}

- (void)prepareForReuse {
    %orig;
    objc_setAssociatedObject(self, LastRecordedStatusIDKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%end

// MARK: - History tab

// History (XActivityHistory.ActivityHistoryContainerViewController) is the
// data source and delegate of a segmented view controller, through
// Objective-C protocol calls, so one more tab can be added after X's own:
// one more in the count, a page and a label for that index. X keeps its pages
// in a Swift array and indexes into it in its delegate callbacks, where an
// index past the end traps, so those callbacks never see the added tab.
// X's own tab count, set only while the tab bar was last told there is one
// more. Every check goes by this rather than the live setting, so switching
// the log off with History open can't hand X the added index.
static const void* OriginalTabCountKey = &OriginalTabCountKey;
static const void* TweetLogPageKey = &TweetLogPageKey;

static long long OriginalTabCount(id container) {
    NSNumber* count = objc_getAssociatedObject(container, OriginalTabCountKey);
    return [count isKindOfClass:NSNumber.class] ? count.longLongValue : -1;
}

static BOOL HasTweetLogTab(id container) {
    return OriginalTabCount(container) > 0;
}

static BOOL IsTweetLogTab(id container, long long index) {
    return HasTweetLogTab(container) && index == OriginalTabCount(container);
}

static UIViewController* TweetLogPage(id container) {
    UIViewController* page = objc_getAssociatedObject(container, TweetLogPageKey);
    if (!page) {
        page = [TweetLogViewController new];
        objc_setAssociatedObject(container, TweetLogPageKey, page, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return page;
}

static NSString* TweetLogTabTitle(void) {
    return [[BHTBundle sharedBundle] localizedStringForKey:@"TWEET_LOG_TAB_TITLE"];
}

static id TabSlot(SEL selector, id argument, BOOL persists) {
    Class slotClass = objc_getClass("_TtC10TFNUISwift13LegacyTabSlot");
    if (![slotClass respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL, id, BOOL))objc_msgSend)(slotClass, selector, argument, persists);
}

static id TweetLogTabLabelSlot(void) {
    return TabSlot(@selector(label:persistsWhenDeselected:), TweetLogTabTitle(), YES);
}

// What goes where X's first tab (Bookmarks) has an extra slot, such as a
// folder caret, which the added tab shouldn't show: a zero-width spacer, so
// a slot that can't be empty still isn't. Nothing where it has nothing.
static id BlankInPlaceOf(id slot) {
    if (!slot) {
        return nil;
    }
    Class slotClass = objc_getClass("_TtC10TFNUISwift13LegacyTabSlot");
    SEL spacer = @selector(spacer:persistsWhenDeselected:);
    if (![slotClass respondsToSelector:spacer]) {
        return slot;
    }
    id blank = ((id (*)(id, SEL, double, BOOL))objc_msgSend)(slotClass, spacer, 0, YES);
    return blank ?: slot;
}

// A label tab styled like `reference`, X's own first tab: its colors, with
// its main slot replaced by the label and its extras blanked out.
static id TweetLogTabDescriptor(id reference) {
    Class descriptorClass = objc_getClass("_TtC10TFNUISwift19LegacyTabDescriptor");
    SEL initSelector = @selector(initWithLeadingAccessory:leadingMain:trailingMain:trailingAccessory:tabAccessibilityLabel:selectedColor:deselectedColor:highlightBarColor:);
    id label = TweetLogTabLabelSlot();
    if (!descriptorClass || !reference || !label || ![descriptorClass instancesRespondToSelector:initSelector]) {
        return nil;
    }

    // Colors X leaves unset (it then uses the theme's) stay unset; nil where
    // the reference has nil is known to be accepted.
    return ((id (*)(id, SEL, id, id, id, id, id, id, id, id))objc_msgSend)(
        [descriptorClass alloc], initSelector,
        BlankInPlaceOf(BHTSafeObject(reference, @selector(leadingAccessory))), label,
        BlankInPlaceOf(BHTSafeObject(reference, @selector(trailingMain))),
        BlankInPlaceOf(BHTSafeObject(reference, @selector(trailingAccessory))), TweetLogTabTitle(),
        BHTSafeObject(reference, @selector(selectedColor)),
        BHTSafeObject(reference, @selector(deselectedColor)),
        BHTSafeObject(reference, @selector(highlightBarColor)));
}

// Fallback for when a new descriptor can't be made: relabels one X has just
// built, the same way as above.
static BOOL RelabelTabDescriptor(id descriptor) {
    id label = TweetLogTabLabelSlot();
    if (!label || ![descriptor respondsToSelector:@selector(setLeadingMain:)]) {
        return NO;
    }

    ((void (*)(id, SEL, id))objc_msgSend)(descriptor, @selector(setLeadingMain:), label);
    for (NSString* name in @[@"leadingAccessory", @"trailingMain", @"trailingAccessory"]) {
        id slot = BHTSafeObject(descriptor, NSSelectorFromString(name));
        NSString* setterName = [NSString stringWithFormat:@"set%@%@:",
                                                          [[name substringToIndex:1] uppercaseString],
                                                          [name substringFromIndex:1]];
        SEL setter = NSSelectorFromString(setterName);
        if (slot && [descriptor respondsToSelector:setter]) {
            ((void (*)(id, SEL, id))objc_msgSend)(descriptor, setter, BlankInPlaceOf(slot));
        }
    }
    if ([descriptor respondsToSelector:@selector(setTabAccessibilityLabel:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(descriptor, @selector(setTabAccessibilityLabel:),
                                              TweetLogTabTitle());
    }
    return YES;
}

%hook _TtC16XActivityHistory38ActivityHistoryContainerViewController

- (long long)numberOfTabsIn:(id)controller {
    long long count = %orig;
    BOOL addTab = BHTTweetLog.enabled && count > 0;
    objc_setAssociatedObject(self, OriginalTabCountKey, addTab ? @(count) : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return addTab ? count + 1 : count;
}

- (id)segmentedViewController:(id)controller pageViewControllerAtIndex:(long long)index {
    if (IsTweetLogTab(self, index)) {
        return TweetLogPage(self);
    }
    return %orig;
}

- (id)segmentedViewController:(id)controller descriptorAtIndex:(long long)index {
    if (!IsTweetLogTab(self, index)) {
        return %orig;
    }
    id reference = %orig(controller, 0);
    id descriptor = TweetLogTabDescriptor(reference);
    if (descriptor) {
        return descriptor;
    }

    // X builds descriptors anew on each call unless it caches them; only a
    // fresh one can be relabelled without renaming X's own first tab.
    id fresh = %orig(controller, 0);
    if (fresh && fresh != reference && RelabelTabDescriptor(fresh)) {
        return fresh;
    }
    return reference;
}

- (id)cachedPageViewControllersIn:(id)controller {
    id pages = %orig;
    UIViewController* page = objc_getAssociatedObject(self, TweetLogPageKey);
    if (page && HasTweetLogTab(self) && [pages isKindOfClass:NSArray.class] && ![pages containsObject:page]) {
        return [pages arrayByAddingObject:page];
    }
    return pages;
}

- (void)segmentedViewController:(id)controller
       willSelectViewController:(id)viewController
                        atIndex:(long long)index
                   indexChanged:(BOOL)changed {
    if (IsTweetLogTab(self, index)) {
        return;
    }
    %orig;
}

- (void)segmentedViewController:(id)controller
        didSelectViewController:(id)viewController
                        atIndex:(long long)index
                  previousIndex:(long long)previousIndex
                        trigger:(long long)trigger {
    if (IsTweetLogTab(self, index)) {
        return;
    }
    // Coming back from the added tab: as far as X knows, nothing changed.
    if (IsTweetLogTab(self, previousIndex)) {
        previousIndex = index;
    }
    %orig(controller, viewController, index, previousIndex, trigger);
}

- (void)segmentedViewController:(id)controller didScrollToFractionalIndex:(double)index {
    long long count = OriginalTabCount(self);
    if (count > 0 && index > count - 1) {
        index = count - 1;
    }
    %orig(controller, index);
}

- (void)segmentedViewController:(id)controller didTapTabAtIndex:(long long)index {
    if (IsTweetLogTab(self, index)) {
        return;
    }
    %orig;
}

- (void)segmentedViewController:(id)controller didLongPressAtIndex:(long long)index {
    if (IsTweetLogTab(self, index)) {
        return;
    }
    %orig;
}

%end

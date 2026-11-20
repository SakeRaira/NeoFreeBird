//
//  HomeBars.x
//  NeoFreeBird
//

#import <string.h>
#import "HookHelpers.h"

// MARK: - Hide custom timelines

static __weak NSObject* PinnedTimelinesRepository;
static NSArray* LastPinnedTimelineModels;
static BOOL PinnedTimelinesWriteBypass = NO;

// Applies a toggle without relaunching. Hiding rewrites the UNCHANGED pinned
// list purely to republish — updatePinnedTimelines: persists server-side, so
// anything else would unpin for real; the delegate hook below swaps in the
// empty list on the way through.
void applyHideCustomTimelinesSetting(void) {
    NSObject* repository = PinnedTimelinesRepository;
    if (!repository) {
        return;
    }

    if ([BHTSettings boolForKey:@"hide_custom_timelines"]) {
        NSArray* models = LastPinnedTimelineModels;
        if (models.count > 0) {
            PinnedTimelinesWriteBypass = YES;
            ((void (*)(id, SEL, id))objc_msgSend)(repository, @selector(updatePinnedTimelines:), models);
            PinnedTimelinesWriteBypass = NO;
        }
    } else if ([repository respondsToSelector:@selector(fetchPinnedTimelinesWithThrottleEnabled:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            repository, @selector(fetchPinnedTimelinesWithThrottleEnabled:), NO);
    }
}

// The trailing accessory is only reconfigured while the strip is showing, so a
// button built before hiding mid-session survives; sync its visibility here. The
// property is a Swift lazy var whose storage ivar KVC can't see, hence the fallback.
static void SyncHomeAddTabButton(id container, BOOL hidden) {
    UIView* button = nil;

    @try {
        button = [container valueForKey:@"addTabButton"];
    } @catch (__unused NSException* exception) {
        unsigned int ivarCount = 0;
        Ivar* ivars = class_copyIvarList([container class], &ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char* name = ivar_getName(ivars[i]);
            if (name && strstr(name, "addTabButton")) {
                button = object_getIvar(container, ivars[i]);
                break;
            }
        }
        free(ivars);
    }

    if ([button isKindOfClass:[UIView class]]) {
        button.hidden = hidden;
    }
}

// MARK: - Hide the For You tab

// For You is always Home's first tab, Following the second. Removing a tab
// would shift every index X's own Swift code uses with the tab strip (it
// selects tabs by index directly, out of reach of a hook), so the tab keeps
// its place: drawn as an empty, zero-width tab that can't be selected, never
// prewarmed, and left for Following whenever Home lands on it. Swiping
// between tabs is turned off while it's hidden, so For You can't slide in.

static NSString* const kHideForYouTabKey = @"hide_for_you_tab";
static const void* HomeTabCountKey = &HomeTabCountKey;
static const void* HomePagingDisabledKey = &HomePagingDisabledKey;
static const long long kForYouTabIndex = 0;
static const long long kFollowingTabIndex = 1;

static NSHashTable<UIViewController*>* HomeContainers(void) {
    static NSHashTable* containers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        containers = [NSHashTable weakObjectsHashTable];
    });
    return containers;
}

static BOOL HidesForYouTab(id container) {
    if (![BHTSettings boolForKey:kHideForYouTabKey]) {
        return NO;
    }
    // Never with For You as the only tab.
    NSNumber* count = objc_getAssociatedObject(container, HomeTabCountKey);
    return [count isKindOfClass:NSNumber.class] && count.longLongValue > kFollowingTabIndex;
}

static UIViewController* HomeSegmentedController(UIViewController* container) {
    Class segmentedClass = objc_getClass("_TtC10TFNUISwift29LegacySegmentedViewController");
    if (!segmentedClass) {
        return nil;
    }
    NSMutableArray<UIViewController*>* queue = [container.childViewControllers mutableCopy];
    for (NSUInteger i = 0; i < queue.count && i < 32; i++) {
        if ([queue[i] isKindOfClass:segmentedClass]) {
            return queue[i];
        }
        [queue addObjectsFromArray:queue[i].childViewControllers];
    }
    return nil;
}

// An empty tab with For You's colors: zero-width spacers wherever For You has
// a slot, so no slot that must hold something is left empty.
static id BlankHomeTabDescriptor(id reference) {
    Class descriptorClass = objc_getClass("_TtC10TFNUISwift19LegacyTabDescriptor");
    Class slotClass = objc_getClass("_TtC10TFNUISwift13LegacyTabSlot");
    SEL initSelector = @selector(initWithLeadingAccessory:leadingMain:trailingMain:trailingAccessory:tabAccessibilityLabel:selectedColor:deselectedColor:highlightBarColor:);
    SEL spacerSelector = @selector(spacer:persistsWhenDeselected:);
    if (!reference || ![descriptorClass instancesRespondToSelector:initSelector] ||
        ![slotClass respondsToSelector:spacerSelector]) {
        return nil;
    }

    id (^blank)(SEL) = ^id(SEL slotSelector) {
        if (!BHTSafeObject(reference, slotSelector)) {
            return nil;
        }
        return ((id (*)(id, SEL, double, BOOL))objc_msgSend)(slotClass, spacerSelector, 0, YES);
    };
    id main = ((id (*)(id, SEL, double, BOOL))objc_msgSend)(slotClass, spacerSelector, 0, YES);
    if (!main) {
        return nil;
    }

    return ((id (*)(id, SEL, id, id, id, id, id, id, id, id))objc_msgSend)(
        [descriptorClass alloc], initSelector, blank(@selector(leadingAccessory)), main,
        blank(@selector(trailingMain)), blank(@selector(trailingAccessory)), @"",
        BHTSafeObject(reference, @selector(selectedColor)),
        BHTSafeObject(reference, @selector(deselectedColor)),
        BHTSafeObject(reference, @selector(highlightBarColor)));
}

// Moves Home off For You the way a tap on Following would, so X's own
// selection callbacks run, and keeps paging in step with the setting.
static void KeepHomeOffForYou(UIViewController* container) {
    UIViewController* segmented = HomeSegmentedController(container);
    if (!segmented) {
        return;
    }

    BOOL hide = HidesForYouTab(container);
    SEL pagingSetter = @selector(setIsHorizontalPagingEnabled:);
    if ([segmented respondsToSelector:pagingSetter]) {
        BOOL disabledHere = objc_getAssociatedObject(segmented, HomePagingDisabledKey) != nil;
        if (hide && !disabledHere && BHTSafeBool(segmented, @selector(isHorizontalPagingEnabled))) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(segmented, pagingSetter, NO);
            objc_setAssociatedObject(segmented, HomePagingDisabledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (!hide && disabledHere) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(segmented, pagingSetter, YES);
            objc_setAssociatedObject(segmented, HomePagingDisabledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    if (!hide || BHTSafeLongLong(segmented, @selector(selectedIndex)) != kForYouTabIndex) {
        return;
    }

    id tabBarView = BHTSafeObject(segmented, @selector(tabBarView));
    SEL tapSelector = @selector(tabBarView:didSelectTabAt:);
    if (tabBarView && [segmented respondsToSelector:tapSelector]) {
        ((void (*)(id, SEL, id, long long))objc_msgSend)(segmented, tapSelector, tabBarView, kFollowingTabIndex);
    } else if ([segmented respondsToSelector:@selector(setSelectedIndex:animated:)]) {
        ((void (*)(id, SEL, long long, BOOL))objc_msgSend)(segmented, @selector(setSelectedIndex:animated:),
                                                           kFollowingTabIndex, NO);
    }
}

// Applies a toggle without relaunching.
void applyHideForYouTabSetting(void) {
    for (UIViewController* container in HomeContainers().allObjects) {
        UIViewController* segmented = HomeSegmentedController(container);
        if ([segmented respondsToSelector:@selector(reloadTabBar)]) {
            ((void (*)(id, SEL))objc_msgSend)(segmented, @selector(reloadTabBar));
        }
        KeepHomeOffForYou(container);
    }
}

// The repository publishes the pinned list through this single delegate call, so
// handing it an empty array hides the tabs without touching persisted state.
%hook _TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController

- (long long)numberOfTabsIn:(id)controller {
    long long count = %orig;
    objc_setAssociatedObject(self, HomeTabCountKey, @(count), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return count;
}

- (id)segmentedViewController:(id)controller descriptorAtIndex:(long long)index {
    id descriptor = %orig;
    if (index != kForYouTabIndex || !HidesForYouTab(self)) {
        return descriptor;
    }
    return BlankHomeTabDescriptor(descriptor) ?: descriptor;
}

- (BOOL)segmentedViewController:(id)controller shouldSelectViewControllerAtIndex:(long long)index {
    if (index == kForYouTabIndex && HidesForYouTab(self)) {
        return NO;
    }
    return %orig;
}

- (BOOL)segmentedViewController:(id)controller isPrewarmableTabAtIndex:(long long)index {
    if (index == kForYouTabIndex && HidesForYouTab(self)) {
        return NO;
    }
    return %orig;
}

- (void)segmentedViewController:(id)controller didTapTabAtIndex:(long long)index {
    if (index == kForYouTabIndex && HidesForYouTab(self)) {
        return;
    }
    %orig;
}

- (void)segmentedViewController:(id)controller didLongPressAtIndex:(long long)index {
    if (index == kForYouTabIndex && HidesForYouTab(self)) {
        return;
    }
    %orig;
}

- (void)segmentedViewController:(id)controller
        didSelectViewController:(id)viewController
                        atIndex:(long long)index
                  previousIndex:(long long)previousIndex
                        trigger:(long long)trigger {
    %orig;
    if (index == kForYouTabIndex && HidesForYouTab(self)) {
        __weak UIViewController* weakSelf = (UIViewController*)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController* container = weakSelf;
            if (container) {
                KeepHomeOffForYou(container);
            }
        });
    }
}

- (void)pinnedTimelinesRepository:(id)repository
    didChangeWithPinnedTimelineModels:(NSArray*)models {
    PinnedTimelinesRepository = repository;
    if (models.count > 0) {
        LastPinnedTimelineModels = [models copy];
    }
    BOOL hide = [BHTSettings boolForKey:@"hide_custom_timelines"];

    %orig(repository, hide ? @[] : models);
    SyncHomeAddTabButton(self, hide);
}

- (id)tfn_navigationBarAccessoryView {
    id accessoryView = %orig;
    SyncHomeAddTabButton(self, [BHTSettings boolForKey:@"hide_custom_timelines"]);
    return accessoryView;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SyncHomeAddTabButton(self, [BHTSettings boolForKey:@"hide_custom_timelines"]);
    attachNeoFreeBirdSettingsGesture((UIViewController*)self);
    [HomeContainers() addObject:(UIViewController*)self];
    KeepHomeOffForYou((UIViewController*)self);
}

%end

// While hiding, the overridden pinned-tabs feature switches make the app compute
// an empty pinned list; freeze writes so it can't overwrite the real tabs.
%hook _TtC32TwitterHomeFeatureImplementation31CachedPinnedTimelinesRepository

- (void)updatePinnedTimelines:(id)timelines {
    if (!PinnedTimelinesWriteBypass && [BHTSettings boolForKey:@"hide_custom_timelines"]) {
        return;
    }

    %orig;
}

%end

// MARK: - Force tweet images to full frame

%hook T1StandardStatusAttachmentViewAdapter

// attachmentType 2 = photos, displayType 1 = full frame
- (NSUInteger)displayType {
    if (self.attachmentType == 2) {
        return [BHTSettings boolForKey:@"force_tweet_full_frame"] ? 1 : %orig;
    }

    return %orig;
}

// Attachment types 2, 3, and 4 are photo, video, and GIF media respectively.
// Returning NO removes only the inline attachment; the post itself remains
// available to open, where the media can still be viewed.
- (BOOL)shouldBeVisibleForViewModel:(id)viewModel {
    BOOL visible = %orig;
    if (!visible || ![BHTSettings boolForKey:@"hide_media_previews"]) {
        return visible;
    }

    NSUInteger attachmentType = self.attachmentType;
    return attachmentType != 2 && attachmentType != 3 && attachmentType != 4;
}

%end

// MARK: - Hide the Spaces bar

// The bar is still the repurposed Fleets line; both home timeline implementations
// share this visibility gate, re-evaluated on every content or settings update.
%hook T1FleetLineHeaderController

- (BOOL)_t1_shouldShowFleetLine {
    if ([BHTSettings boolForKey:@"hide_spaces"]) {
        return NO;
    }

    return %orig;
}

%end

%hook _TtC14T1TwitterSwift28FleetLineAccessoryController

- (BOOL)isHidden {
    return [BHTSettings boolForKey:@"hide_spaces"] ? YES : %orig;
}

- (UIView*)accessoryView {
    return [BHTSettings boolForKey:@"hide_spaces"] ? nil : %orig;
}

%end

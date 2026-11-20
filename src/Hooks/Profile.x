//
//  Profile.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Copy profile info

static void PresentCopyProfileInfoSheet(T1ProfileUserViewModel* viewModel) {
    NSMutableArray<TFNActionItem*>* items = [NSMutableArray array];

    void (^addCopyItem)(NSString*, NSString*, NSString*) =
        ^(NSString* titleKey, NSString* iconName, NSString* value) {
            if (!value.length) {
                return;
            }
            TFNActionItem* item = [%c(TFNActionItem)
                actionItemWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:titleKey]
                          imageName:iconName
                             action:^{
                                 UIPasteboard.generalPasteboard.string = value;
                             }];
            if (item) {
                [items addObject:item];
            }
        };

    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_3", @"account", viewModel.fullName);
    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_2", @"at", viewModel.username);
    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_1", @"news_stroke", viewModel.bio);
    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_5", @"location_stroke", viewModel.location);
    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_4", @"link", viewModel.url);
    if (viewModel.username.length) {
        addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_6", @"link",
                    [NSString stringWithFormat:@"https://x.com/%@", viewModel.username]);
    }
    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_7", @"bar_chart", [NSString stringWithFormat:@"%ld", (long)viewModel.userDataSource.user.userID]);
    NSDateFormatter* dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateStyle = NSDateFormatterLongStyle;
    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_8", @"calendar",
                [dateFormatter stringFromDate:viewModel.userDataSource.user.createdDate]);

    if (!items.count) {
        return;
    }

    TFNMenuSheetViewController* sheet = [[%c(TFNMenuSheetViewController) alloc]
        initWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_TITLE"]
          actionItems:items];
    [sheet tfnPresentedCustomPresentFromViewController:topMostController()
                                              animated:YES
                                            completion:nil];
}

%hook T1ProfileHeaderViewController

- (id)profileMoreActionsBaseActionItemsWithSender:(id)sender {
    NSArray* items = %orig;

    if (![BHTSettings boolForKey:@"copy_profile_info"] ||
        ![items isKindOfClass:[NSArray class]]) {
        return items;
    }

    // Only extend a menu built the way this expects: if the action items ever
    // stop being TFNActionItems, the copy entry drops out rather than handing
    // the menu something it cannot show.
    if (![items.firstObject isKindOfClass:%c(TFNActionItem)]) {
        return items;
    }

    T1ProfileUserViewModel* viewModel = self.viewModel;
    if (![viewModel respondsToSelector:@selector(username)]) {
        return items;
    }

    TFNActionItem* copyItem = [%c(TFNActionItem)
        actionItemWithTitle:[[BHTBundle sharedBundle]
                                localizedStringForKey:@"COPY_PROFILE_INFO_TITLE"]
                  imageName:@"copy_stroke"
                     action:^{
                         // The more-actions menu is still on its way out when
                         // the action fires, so let it finish before stacking
                         // the copy sheet on top.
                         dispatch_async(dispatch_get_main_queue(), ^{
                             PresentCopyProfileInfoSheet(viewModel);
                         });
                     }];

    return copyItem ? [items arrayByAddingObject:copyItem] : items;
}

%end

// MARK: - Hide premium offer

%hook T1ProfileSummaryView

- (BOOL)shouldShowGetVerifiedButton {
    return [BHTSettings boolForKey:@"hide_premium_offer"] ? NO : %orig;
}

%end

// MARK: - Show unrounded follower/following counts

%hook T1ProfileFriendsFollowingViewModel

- (id)_t1_followCountTextWithLabel:(__unsafe_unretained id)label
                     singularLabel:(__unsafe_unretained id)singularLabel
                             count:(NSNumber*)count
                       highlighted:(BOOL)highlighted {
    id original = %orig;
    if (![BHTSettings boolForKey:@"show_unrounded_counts"]) {
        return original;
    }

    if (![count isKindOfClass:[NSNumber class]] ||
        ![original isKindOfClass:[NSAttributedString class]]) {
        return original;
    }

    NSString* abbreviated = [count tfs_twitterAbbreviated];
    NSNumberFormatter* formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    NSString* fullCount = [formatter stringFromNumber:count];

    if (!abbreviated.length || !fullCount.length || [abbreviated isEqualToString:fullCount]) {
        return original;
    }

    NSRange range = [[original string] rangeOfString:abbreviated];
    if (range.location == NSNotFound) {
        return original;
    }

    NSMutableAttributedString* expanded = [original mutableCopy];
    [expanded replaceCharactersInRange:range withString:fullCount];
    return [expanded copy];
}

%end

// MARK: - Open the Media tab on Photos

// The Media tab is a group of Videos and Photos inner tabs that opens on
// Videos. The profile's tab bar asks the profile for each tab's label, inner
// tabs and page by outer tab index, and the provider's groupActiveIndices
// decides which inner tab that is; the group is pointed at Photos from there,
// before the Media tab's label or page exist, once per profile.
//
// The first version did this from inside -contentMainEntries, which X calls
// throughout building the profile, including while it walks
// groupActiveIndices, and changing the array under it crashed every profile.
// So nothing here runs inside a provider getter, the array is replaced instead
// of changed in place, and a re-entrant call does nothing.
static const void* PhotosDefaultSettledKey = &PhotosDefaultSettledKey;
static BOOL PreferringPhotos = NO;

static T1ProfileDisplayNormalMainContentProvider* MainContentProvider(T1ProfileViewController* profile) {
    NSArray* providers = [profile respondsToSelector:@selector(displayContentProviders)]
                             ? profile.displayContentProviders
                             : nil;
    Class mainClass = objc_getClass("T1ProfileDisplayNormalMainContentProvider");
    if (![providers isKindOfClass:NSArray.class] || !mainClass) {
        return nil;
    }

    for (id provider in providers) {
        if ([provider isKindOfClass:mainClass]) {
            return provider;
        }
    }
    return nil;
}

static BOOL EntryHasCachedViewController(id entry) {
    SEL selector = @selector(hasCachedViewController);
    return [entry respondsToSelector:selector] &&
           ((BOOL (*)(id, SEL))objc_msgSend)(entry, selector);
}

static void SettlePhotosDefault(T1ProfileDisplayNormalMainContentProvider* provider) {
    objc_setAssociatedObject(provider, PhotosDefaultSettledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void PointMediaGroupAtPhotos(T1ProfileDisplayNormalMainContentProvider* provider,
                                    long long tabIndex) {
    NSArray* entries = provider.contentMainEntries;
    id photoEntry = provider.photoEntry;
    if (![entries isKindOfClass:NSArray.class] || !photoEntry || tabIndex < 0 ||
        tabIndex >= (long long)entries.count) {
        return;
    }

    // Any tab but Media: wait for the Media one.
    NSArray* group = entries[(NSUInteger)tabIndex];
    if (![group isKindOfClass:NSArray.class]) {
        return;
    }
    NSUInteger photoIndex = [group indexOfObjectIdenticalTo:photoEntry];
    if (photoIndex == NSNotFound) {
        return;
    }

    // videoEntry may be built on demand instead of kept, in which case it is
    // never the instance in the group; the Media group's other tab is.
    id videoEntry = provider.videoEntry;
    NSUInteger videoIndex = videoEntry ? [group indexOfObjectIdenticalTo:videoEntry] : NSNotFound;
    if (videoIndex == NSNotFound && group.count == 2) {
        videoIndex = 1 - photoIndex;
    }
    // A Videos page that already exists (opened or prewarmed) stays.
    if (videoIndex == NSNotFound || EntryHasCachedViewController(group[videoIndex])) {
        SettlePhotosDefault(provider);
        return;
    }

    NSArray* active = provider.groupActiveIndices;
    if (![active isKindOfClass:NSArray.class]) {
        return;
    }

    // One slot per outer tab, or one per group. An array X hasn't filled yet
    // fits neither and is left for a later call.
    NSUInteger groupCount = 0;
    NSUInteger groupOrdinal = 0;
    for (NSUInteger i = 0; i < entries.count; i++) {
        if ([entries[i] isKindOfClass:NSArray.class]) {
            if (i < (NSUInteger)tabIndex) {
                groupOrdinal++;
            }
            groupCount++;
        }
    }

    NSUInteger slot;
    if (active.count == entries.count) {
        slot = (NSUInteger)tabIndex;
    } else if (active.count == groupCount) {
        slot = groupOrdinal;
    } else {
        return;
    }

    // Decided for this profile from here on, so a later tap on Videos sticks.
    SettlePhotosDefault(provider);

    id current = active[slot];
    if (![current isKindOfClass:NSNumber.class] || [current integerValue] != (NSInteger)videoIndex) {
        return;
    }

    NSMutableArray* updated = [active mutableCopy];
    updated[slot] = @(photoIndex);
    provider.groupActiveIndices = updated;
}

static void PreferPhotosInMediaGroup(T1ProfileViewController* profile, long long tabIndex) {
    if (PreferringPhotos || ![BHTSettings boolForKey:@"profile_media_photos_first"]) {
        return;
    }

    T1ProfileDisplayNormalMainContentProvider* provider = MainContentProvider(profile);
    if (!provider || objc_getAssociatedObject(provider, PhotosDefaultSettledKey) ||
        ![provider respondsToSelector:@selector(contentMainEntries)] ||
        ![provider respondsToSelector:@selector(groupActiveIndices)] ||
        ![provider respondsToSelector:@selector(setGroupActiveIndices:)] ||
        ![provider respondsToSelector:@selector(photoEntry)] ||
        ![provider respondsToSelector:@selector(videoEntry)]) {
        return;
    }

    PreferringPhotos = YES;
    @try {
        PointMediaGroupAtPhotos(provider, tabIndex);
    } @catch (__unused NSException* exception) {
        // Whatever X's structure turned out to be, keep Videos and stop trying.
        SettlePhotosDefault(provider);
    } @finally {
        PreferringPhotos = NO;
    }
}

// MARK: - Show unrounded tweet/post count

%hook T1ProfileDisplayNormalMainContentProvider

- (id)_tweetsSubtitle {
    id original = %orig;

    if (![BHTSettings boolForKey:@"show_unrounded_counts"]) {
        return original;
    }

    NSNumber* count = self.viewModel.tweetCount;
    if (![count isKindOfClass:[NSNumber class]] || ![original isKindOfClass:[NSString class]]) {
        return original;
    }

    NSString* abbreviated = [count tfs_twitterAbbreviated];
    NSNumberFormatter* formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    NSString* fullCount = [formatter stringFromNumber:count];

    if (!abbreviated.length || !fullCount.length || [abbreviated isEqualToString:fullCount]) {
        return original;
    }

    NSRange range = [(NSString*)original rangeOfString:abbreviated];
    if (range.location == NSNotFound) {
        return original;
    }

    return [(NSString*)original stringByReplacingCharactersInRange:range withString:fullCount];
}

%end

// MARK: - Message/Follow buttons under the username

// The large Message/Follow row is a subheader below the profile header, laid
// out after the bio, stats and social proof. The header keeps no order of its
// own: it asks the profile for its subheaders on every layout and stacks them
// in the order given, so returning the row first puts it straight under the
// name and @username. Only the returned copy is reordered.
static NSArray* SubheadersWithActionButtonsFirst(NSArray* subheaders) {
    Class buttonsClass = objc_getClass("T1ProfileActionButtonsSubheaderViewController");
    if (!buttonsClass || ![subheaders isKindOfClass:NSArray.class] || subheaders.count < 2) {
        return subheaders;
    }

    NSUInteger index = [subheaders indexOfObjectPassingTest:^BOOL(id subheader, NSUInteger idx, BOOL* stop) {
        return [subheader isKindOfClass:buttonsClass];
    }];
    if (index == NSNotFound || index == 0) {
        return subheaders;
    }

    NSMutableArray* reordered = [subheaders mutableCopy];
    id buttons = reordered[index];
    [reordered removeObjectAtIndex:index];
    [reordered insertObject:buttons atIndex:0];
    return [reordered copy];
}

// MARK: - Compose button on profiles

// The floating compose button belongs to the tab navigation and stays on
// screen over every page, profiles included. While someone else's profile is
// showing it is hidden (on the account's own profile it stays, for posting
// from there); X shows it again by itself (after scrolling, on relayout), so
// it is re-hidden whenever it tries.
static const void* HiddenForProfileKey = &HiddenForProfileKey;

static NSHashTable<UIViewController*>* VisibleProfiles(void) {
    static NSHashTable* profiles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        profiles = [NSHashTable weakObjectsHashTable];
    });
    return profiles;
}

static NSHashTable<UIView*>* FloatingComposeButtons(void) {
    static NSHashTable* buttons;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        buttons = [NSHashTable weakObjectsHashTable];
    });
    return buttons;
}

// Asked each time rather than when the profile appears: the view model can
// still be loading then.
static BOOL ProfileIsOwn(UIViewController* profile) {
    id viewModel = BHTSafeObject(profile, @selector(viewModel));
    return BHTSafeBool(viewModel, @selector(isViewingOwnProfile)) ||
           BHTSafeBool(viewModel, @selector(viewingOwnProfile));
}

static BOOL ShouldHideComposeButtonForProfile(void) {
    if (![BHTSettings boolForKey:@"hide_tweet_button_on_profiles"]) {
        return NO;
    }
    for (UIViewController* profile in VisibleProfiles().allObjects) {
        if (!ProfileIsOwn(profile)) {
            return YES;
        }
    }
    return NO;
}

// The associated value is what the button was like before a profile hid it,
// @[hidden, userInteractionEnabled], and is put back once no profile shows.
static void ApplyProfileComposeButtonVisibility(UIView* button) {
    NSArray<NSNumber*>* saved = objc_getAssociatedObject(button, HiddenForProfileKey);
    if (ShouldHideComposeButtonForProfile()) {
        if (!saved) {
            objc_setAssociatedObject(button, HiddenForProfileKey,
                                     @[@(button.hidden), @(button.userInteractionEnabled)],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!button.hidden) {
            button.hidden = YES;
        }
        if (button.userInteractionEnabled) {
            button.userInteractionEnabled = NO;
        }
        return;
    }

    if (![saved isKindOfClass:NSArray.class] || saved.count != 2) {
        return;
    }
    objc_setAssociatedObject(button, HiddenForProfileKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // "Hide the Tweet button" keeps it hidden everywhere (Misc.x).
    if (![BHTSettings boolForKey:@"hide_tweet_button"]) {
        button.hidden = saved[0].boolValue;
        button.userInteractionEnabled = saved[1].boolValue;
    }
}

static void ApplyProfileComposeButtonVisibilityEverywhere(void) {
    for (UIView* button in FloatingComposeButtons().allObjects) {
        ApplyProfileComposeButtonVisibility(button);
    }
}

%hook TFNFloatingActionButton

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [FloatingComposeButtons() addObject:self];
    }
    ApplyProfileComposeButtonVisibility(self);
}

- (void)layoutSubviews {
    %orig;
    if (objc_getAssociatedObject(self, HiddenForProfileKey) || ShouldHideComposeButtonForProfile()) {
        ApplyProfileComposeButtonVisibility(self);
    }
}

- (void)showAnimated:(BOOL)animated completion:(id)completion {
    %orig;
    ApplyProfileComposeButtonVisibility(self);
}

%end

// The subheader order (SubheadersWithActionButtonsFirst()), the Media tab
// default (PreferPhotosInMediaGroup(): whichever of the tab bar's data source
// calls comes first for the Media tab settles it) and the compose button.
%hook T1ProfileViewController

// Counted from about to appear until fully gone, so a cancelled swipe back
// or a push on top keeps the right state.
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [VisibleProfiles() addObject:self];
    ApplyProfileComposeButtonVisibilityEverywhere();
}

// Once on screen the view model knows whose profile this is, which it may
// not have yet when the profile is about to appear.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApplyProfileComposeButtonVisibilityEverywhere();
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [VisibleProfiles() removeObject:self];
    ApplyProfileComposeButtonVisibilityEverywhere();
}

- (id)resizableHeaderSubheaderViewControllersForResizableHeaderViewController:(id)controller {
    id subheaders = %orig;
    return [BHTSettings boolForKey:@"profile_buttons_under_username"]
               ? SubheadersWithActionButtonsFirst(subheaders)
               : subheaders;
}

- (id)segmentedViewController:(id)controller descriptorAtIndex:(long long)index {
    PreferPhotosInMediaGroup(self, index);
    return %orig;
}

- (id)segmentedViewController:(id)controller tabGroupAtIndex:(long long)index {
    PreferPhotosInMediaGroup(self, index);
    return %orig;
}

- (id)segmentedViewController:(id)controller pageViewControllerAtIndex:(long long)index {
    PreferPhotosInMediaGroup(self, index);
    return %orig;
}

// X opening a profile's Videos tab on purpose (the immersive player's link to
// a profile's videos) beats the default.
- (void)showProfileVideosTabWithPersist:(BOOL)persist {
    T1ProfileDisplayNormalMainContentProvider* provider = MainContentProvider(self);
    if (provider) {
        SettlePhotosDefault(provider);
    }
    %orig;
}

%end

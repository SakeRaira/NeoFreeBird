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
// Videos. Point the group at Photos once per active-index array: X builds a new
// array when it rebuilds the groups, and a tap by the user only changes the
// existing one in place, which is left alone after the first adjustment.
static const void* PhotosFirstAppliedKey = &PhotosFirstAppliedKey;
// Set on a profile's providers when X opens its Videos tab on purpose (the
// immersive player's link to a profile's videos), which the default must not
// undo.
static const void* VideosRequestedKey = &VideosRequestedKey;

static void SelectPhotosInMediaGroup(T1ProfileDisplayNormalMainContentProvider* provider,
                                     NSArray* entries) {
    if (![BHTSettings boolForKey:@"profile_media_photos_first"] ||
        objc_getAssociatedObject(provider, VideosRequestedKey) ||
        ![entries isKindOfClass:NSArray.class] ||
        ![provider respondsToSelector:@selector(groupActiveIndices)] ||
        ![provider respondsToSelector:@selector(photoEntry)] ||
        ![provider respondsToSelector:@selector(videoEntry)]) {
        return;
    }

    NSMutableArray* activeIndices = provider.groupActiveIndices;
    if (![activeIndices isKindOfClass:NSMutableArray.class] ||
        objc_getAssociatedObject(activeIndices, PhotosFirstAppliedKey)) {
        return;
    }

    id photoEntry = provider.photoEntry;
    id videoEntry = provider.videoEntry;
    if (!photoEntry) {
        return;
    }

    NSUInteger groupCount = 0;
    for (id entry in entries) {
        if ([entry isKindOfClass:NSArray.class]) {
            groupCount++;
        }
    }

    NSUInteger groupOrdinal = 0;
    for (NSUInteger tabIndex = 0; tabIndex < entries.count; tabIndex++) {
        NSArray* group = entries[tabIndex];
        if (![group isKindOfClass:NSArray.class]) {
            continue;
        }

        NSUInteger photoIndex = [group indexOfObjectIdenticalTo:photoEntry];
        if (photoIndex == NSNotFound) {
            groupOrdinal++;
            continue;
        }

        // videoEntry may be built on demand instead of kept, in which case it
        // is never the instance in the group; the Media group's other tab is.
        NSUInteger videoIndex = videoEntry ? [group indexOfObjectIdenticalTo:videoEntry] : NSNotFound;
        if (videoIndex == NSNotFound && group.count == 2) {
            videoIndex = 1 - photoIndex;
        }
        if (videoIndex == NSNotFound) {
            return;
        }

        // One slot per outer tab, or one per group. Anything else (including
        // an array X hasn't filled yet) is left for a later call.
        NSUInteger slot;
        if (activeIndices.count == entries.count) {
            slot = tabIndex;
        } else if (activeIndices.count == groupCount) {
            slot = groupOrdinal;
        } else {
            return;
        }

        id current = activeIndices[slot];
        if ([current isKindOfClass:NSNumber.class] &&
            [current integerValue] == (NSInteger)videoIndex) {
            @try {
                activeIndices[slot] = @(photoIndex);
            } @catch (__unused NSException* exception) {
                // An immutable array behind the mutable type; leave it.
            }
        }
        objc_setAssociatedObject(activeIndices, PhotosFirstAppliedKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
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

// Media tab default, see SelectPhotosInMediaGroup().
- (NSArray*)contentMainEntries {
    NSArray* entries = %orig;
    SelectPhotosInMediaGroup(self, entries);
    return entries;
}

%end

%hook T1ProfileViewController

- (void)showProfileVideosTabWithPersist:(BOOL)persist {
    NSArray* providers = [self respondsToSelector:@selector(displayContentProviders)]
                             ? self.displayContentProviders
                             : nil;
    if ([providers isKindOfClass:NSArray.class]) {
        for (id provider in providers) {
            objc_setAssociatedObject(provider, VideosRequestedKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    %orig;
}

%end

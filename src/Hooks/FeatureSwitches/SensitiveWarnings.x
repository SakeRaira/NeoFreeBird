//
//  SensitiveWarnings.x
//  NeoFreeBird
//
//  Sensitive warnings beyond the posts themselves (the other view models a
//  timeline shows a post through, a profile's notice), and registered places
//  (BHTSensitiveZones) bringing them back or taking them away live.
//

#import "FeatureSwitches.h"

// Timelines in 12.45 show the post through other view models (a Swift
// adapter, URT timeline items, translated posts), each answering these
// checks itself, so with only TFNTwitterStatus covered a timeline still
// drew the "may contain sensitive content, change settings" tombstone where
// the opened post showed the media.

// MARK: - Retweets judged by the original post

// X gives a retweet the warning of the account that retweeted it (an account
// X considers sensitive has the mark on everything it posts, retweets
// included), even over a post that carries no mark of its own. The mark can
// sit on the retweet or reach the original it shows, and the media's overlay
// is decided from either. With "Judge retweets by the original post" on, a
// post shown through a retweet whose original has no sensitive mark (its own
// flag, its media's, or its author's flag or account) gets no warning: the
// checks below answer no, and an overlay drawn anyway is opened the way the
// Show button would (FeatureSwitches.m). A warning is never added.

BOOL BHTViewModelShowsRetweetOfUnflaggedPost(id viewModel);

static BOOL JudgeRetweetsByOriginal(void) {
    return [BHTSettings boolForKey:@"sensitive_by_original_post"];
}

// Set while an original's own marks are read: its checks go through the
// hooks below too, and then answer as X would.
static __thread BOOL ReadingOwnMarks;

static Class StatusClass(void) {
    static Class statusClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        statusClass = objc_getClass("TFNTwitterStatus");
    });
    return statusClass;
}

static id InnerModel(id model) {
    for (NSString* name in @[@"statusViewModel", @"tweet", @"status"]) {
        id inner = BHTSafeObject(model, NSSelectorFromString(name));
        if (inner && inner != model) {
            return inner;
        }
    }
    return nil;
}

// The post a model shows: the TFNTwitterStatus itself, or the one a view
// model wraps, up to three deep.
static id StatusBehind(id model) {
    Class statusClass = StatusClass();
    for (NSUInteger depth = 0; model && statusClass && depth < 4; depth++) {
        if ([model isKindOfClass:statusClass]) {
            return model;
        }
        model = InnerModel(model);
    }
    return nil;
}

// A moderation label on any of the post's media (adult content, violence...).
// The label object can exist with every category off.
static BOOL MediaHasWarning(id post) {
    NSArray* media = BHTSafeObject(BHTSafeObject(post, @selector(entities)), @selector(media));
    if (![media isKindOfClass:NSArray.class]) {
        return NO;
    }
    for (id item in media) {
        id warning = BHTSafeObject(item, @selector(sensitiveMediaWarning));
        if (!warning) {
            continue;
        }
        if (![warning respondsToSelector:@selector(hasAnyWarning)] || BHTSafeBool(warning, @selector(hasAnyWarning))) {
            return YES;
        }
    }
    return NO;
}

// The caller holds ReadingOwnMarks.
static BOOL PostHasSensitiveMark(id post) {
    id author = BHTSafeObject(post, @selector(fromUser));
    return BHTSafeBool(post, @selector(isPossiblySensitive)) ||
           BHTSafeBool(post, @selector(hasSensitiveMediaWarningsFlaggedByAuthor)) || MediaHasWarning(post) ||
           BHTIsSensitiveMediaInterstitialType(BHTSafeLongLong(author, @selector(profileInterstitialType)));
}

// The original post a model shows through a retweet (a TFNTwitterStatus),
// else nil: a retweet's original, or a post a retweet carries (X links such
// a post back to the retweet).
static id OriginalShownThroughRetweet(id model) {
    Class statusClass = StatusClass();
    for (NSUInteger depth = 0; model && statusClass && depth < 4; depth++) {
        if ([model isKindOfClass:statusClass]) {
            if (BHTSafeBool(model, @selector(isRetweet))) {
                id original = BHTSafeObject(model, @selector(retweetedStatus));
                return [original isKindOfClass:statusClass] && original != model ? original : nil;
            }
            return BHTSafeObject(model, @selector(retweetingStatus)) ? model : nil;
        }
        // A view model saying it's a retweet points to the original.
        if (BHTSafeBool(model, @selector(isRetweet))) {
            id original = StatusBehind(BHTSafeObject(model, @selector(representedStatus)));
            if (original) {
                return original;
            }
        }
        model = InnerModel(model);
    }
    return nil;
}

// Only judged with the original post in hand: anything else keeps X's answer.
// The highlight's way of finding a retweet's original first (it walks any
// object the model links to, a TFNTwitterStatus or not), then a post a
// retweet carries.
static BOOL IsRetweetOfUnmarkedPost(id model) {
    if (ReadingOwnMarks || !model || !JudgeRetweetsByOriginal()) {
        return NO;
    }
    ReadingOwnMarks = YES;
    BOOL clean = BHTViewModelShowsRetweetOfUnflaggedPost(model);
    if (!clean) {
        id original = OriginalShownThroughRetweet(model);
        clean = original && !PostHasSensitiveMark(original);
    }
    ReadingOwnMarks = NO;
    return clean;
}

__thread BOOL BHTReadingRawSensitivity;

BOOL BHTHidesSensitiveWarningFor(id model) {
    if (BHTReadingRawSensitivity) {
        return NO;
    }
    return BHTSensitiveWarningsSuppressed() || IsRetweetOfUnmarkedPost(model);
}

// A media overlay's post: the view model of the status view it's in (a
// cell's own, found through the cell; a quoted post's status view inside it
// is its own post and keeps its warnings).
static id OverlayStatusViewModel(UIView* overlay) {
    UIView* view = overlay.superview;
    for (NSUInteger depth = 0; view && depth < 24; depth++, view = view.superview) {
        id statusView = BHTSafeObject(view, @selector(statusView));
        if ([statusView isKindOfClass:UIView.class] && [overlay isDescendantOfView:statusView]) {
            return BHTSafeObject(statusView, @selector(viewModel));
        }
        if ([NSStringFromClass(view.class) hasSuffix:@"StatusView"]) {
            id viewModel = BHTSafeObject(view, @selector(viewModel));
            if (viewModel) {
                return viewModel;
            }
        }
    }
    return nil;
}

BOOL BHTOverlayShowsRetweetOfUnmarkedPost(UIView* overlay) {
    return JudgeRetweetsByOriginal() && IsRetweetOfUnmarkedPost(OverlayStatusViewModel(overlay));
}

%hook T1TwitterCoreStatusViewModelAdapter

- (BOOL)isPossiblySensitiveViewModelForAccount:(id)account {
    return BHTHidesSensitiveWarningFor(self) ? NO : %orig;
}

- (BOOL)displaySensitiveContentAppealForAccount:(id)account {
    return BHTSensitiveWarningsSuppressed() ? NO : %orig;
}

- (BOOL)hasImageInterstitial {
    return BHTHidesSensitiveWarningFor(self) ? NO : %orig;
}

- (id)imageInterstitial {
    return BHTHidesSensitiveWarningFor(self) ? nil : %orig;
}

- (id)innerImageInterstitial {
    return BHTHidesSensitiveWarningFor(self) ? nil : %orig;
}

%end

%hook T1TranslatedStatusViewModel

- (BOOL)isPossiblySensitiveViewModelForAccount:(id)account {
    return BHTHidesSensitiveWarningFor(self) ? NO : %orig;
}

- (BOOL)displaySensitiveContentAppealForAccount:(id)account {
    return BHTSensitiveWarningsSuppressed() ? NO : %orig;
}

- (BOOL)hasImageInterstitial {
    return BHTHidesSensitiveWarningFor(self) ? NO : %orig;
}

- (id)imageInterstitial {
    return BHTHidesSensitiveWarningFor(self) ? nil : %orig;
}

- (id)innerImageInterstitial {
    return BHTHidesSensitiveWarningFor(self) ? nil : %orig;
}

%end

// TwitterURT.URTTimelineStatusItemViewModel
%hook _TtC10TwitterURT30URTTimelineStatusItemViewModel

- (BOOL)isPossiblySensitiveViewModelForAccount:(id)account {
    return BHTHidesSensitiveWarningFor(self) ? NO : %orig;
}

- (BOOL)displaySensitiveContentAppealForAccount:(id)account {
    return BHTSensitiveWarningsSuppressed() ? NO : %orig;
}

- (BOOL)hasImageInterstitial {
    return BHTHidesSensitiveWarningFor(self) ? NO : %orig;
}

%end

// What the status view itself reads when choosing between media and the
// tombstone.
%hook TTAStatusViewCombinedViewModel

- (BOOL)isPossiblySensitive {
    return BHTHidesSensitiveWarningFor(self) ? NO : %orig;
}

%end

// The full-screen "This account may contain sensitive content" notice on a
// profile is its own content provider, shown in place of the profile's
// timelines. X steps it aside ("supersedes" it) when the viewer allows
// sensitive media; with warnings off the sensitive-media kinds go that way
// too. Other kinds (suspended, withheld, ...) are untouched.
static BOOL ProfileInterstitialIsSuppressedSensitive(id provider) {
    if (!BHTSensitiveWarningsSuppressed()) {
        return NO;
    }

    id viewModel = BHTSafeObject(provider, @selector(viewModel));
    long long type = BHTSafeLongLong(viewModel, @selector(interstitialType));
    SEL isSensitiveType = @selector(private_isSensitiveMediaInterstitialType:);
    if (!viewModel || ![provider respondsToSelector:isSensitiveType]) {
        return NO;
    }
    return ((BOOL (*)(id, SEL, long long))objc_msgSend)(provider, isSensitiveType, type);
}

%hook T1ProfileDisplayInterstitialedUserContentProvider

- (BOOL)private_shouldInterstitialBeSuperceded {
    return ProfileInterstitialIsSuppressedSensitive(self) ? YES : %orig;
}

- (BOOL)canBecomeCurrent {
    return ProfileInterstitialIsSuppressedSensitive(self) ? NO : %orig;
}

%end

// Whether warnings were off at the last change of place; -1 until known.
static int SensitiveWarningsWereSuppressed = -1;

// Overlays that have been on screen, so a change of place (BHTSensitiveZones)
// can blur or reveal the ones still showing.
static NSHashTable<HFSensitiveTweetBlurredInterstitialView*>* SensitiveMediaOverlays(void) {
    static NSHashTable* overlays;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overlays = [NSHashTable weakObjectsHashTable];
    });
    return overlays;
}


%hook HFSensitiveTweetBlurredInterstitialView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [SensitiveMediaOverlays() addObject:self];
        if (SensitiveWarningsWereSuppressed < 0) {
            SensitiveWarningsWereSuppressed = BHTSensitiveWarningsSuppressed() ? 1 : 0;
        }
    }
}

%end

// X remembers, for the session, every post whose sensitive media was shown
// (by its Show button, which the automatic reveal above also goes through),
// and opens those posts revealed wherever they appear again. One store per
// account; tracked so it can be emptied.
static NSHashTable* SensitiveRevealedContentStores(void) {
    static NSHashTable* stores;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stores = [NSHashTable weakObjectsHashTable];
    });
    return stores;
}

%hook T1StatusAttachmentSensitiveContentRevealedContentStore

- (instancetype)init {
    self = %orig;
    if (self) {
        [SensitiveRevealedContentStores() addObject:self];
    }
    return self;
}

%end

static void BHTForgetRevealedSensitiveContent(void) {
    for (id store in SensitiveRevealedContentStores().allObjects) {
        NSMutableSet* revealed = objectIvar(store, "_revealedSet");
        if ([revealed isKindOfClass:NSMutableSet.class]) {
            [revealed removeAllObjects];
        }
    }
}

// Blurs one overlay again through its own Hide action, so the media and X's
// bookkeeping follow; an overlay whose button was never built is set directly.
static void BHTConcealSensitiveMedia(HFSensitiveTweetBlurredInterstitialView* overlay) {
    if (![overlay respondsToSelector:@selector(blurViewIsHidden)] || !overlay.blurViewIsHidden) {
        return;
    }

    UIButton* button = BHTSensitiveMediaRevealButton(overlay);
    if (button && [overlay respondsToSelector:@selector(showOrHideMediaButtonPressed:)]) {
        [overlay showOrHideMediaButtonPressed:button];
    } else if ([overlay respondsToSelector:@selector(setBlurViewIsHidden:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(overlay, @selector(setBlurViewIsHidden:), NO);
    }
}

// Entering a registered place resets every sensitive image to hidden: the
// ones revealed automatically and the ones shown by hand, on screen or
// scrolled away, and X's memory of them, so they come back blurred too. A
// Show tapped after that is left alone. Leaving reveals them again. Tweets
// laid out while warnings were off have no overlay at all, so those only pick
// up a warning once they are shown again.
static void BHTApplySensitiveZoneChange(void) {
    BOOL suppressed = BHTSensitiveWarningsSuppressed();
    BOOL warningsCameBack = SensitiveWarningsWereSuppressed == 1 && !suppressed;
    SensitiveWarningsWereSuppressed = suppressed ? 1 : 0;

    if (warningsCameBack) {
        BHTForgetRevealedSensitiveContent();
    }

    for (HFSensitiveTweetBlurredInterstitialView* overlay in SensitiveMediaOverlays().allObjects) {
        if (![overlay respondsToSelector:@selector(blurViewIsHidden)]) {
            continue;
        }

        if (suppressed) {
            if (overlay.window) {
                BHTScheduleSensitiveMediaReveal(overlay);
            }
            continue;
        }

        if (warningsCameBack) {
            BHTConcealSensitiveMedia(overlay);
        }
        BHTUpdateSensitiveMediaRevealButton(overlay);
    }
}

%ctor {
    %init;

    [NSNotificationCenter.defaultCenter addObserverForName:BHTSensitiveZonesDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* notification) {
                                                    BHTApplySensitiveZoneChange();
                                                }];

    // Start watching registered places at launch, so the first timeline
    // already respects them.
    dispatch_async(dispatch_get_main_queue(), ^{
        (void)BHTSensitiveZones.shared;
    });
}

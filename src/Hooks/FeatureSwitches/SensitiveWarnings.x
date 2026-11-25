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

%hook T1TwitterCoreStatusViewModelAdapter

- (BOOL)isPossiblySensitiveViewModelForAccount:(id)account {
    return BHTSensitiveWarningsSuppressed() ? NO : %orig;
}

- (BOOL)displaySensitiveContentAppealForAccount:(id)account {
    return BHTSensitiveWarningsSuppressed() ? NO : %orig;
}

- (BOOL)hasImageInterstitial {
    return BHTSensitiveWarningsSuppressed() ? NO : %orig;
}

- (id)imageInterstitial {
    return BHTSensitiveWarningsSuppressed() ? nil : %orig;
}

- (id)innerImageInterstitial {
    return BHTSensitiveWarningsSuppressed() ? nil : %orig;
}

%end

%hook T1TranslatedStatusViewModel

- (BOOL)isPossiblySensitiveViewModelForAccount:(id)account {
    return BHTSensitiveWarningsSuppressed() ? NO : %orig;
}

- (BOOL)displaySensitiveContentAppealForAccount:(id)account {
    return BHTSensitiveWarningsSuppressed() ? NO : %orig;
}

- (BOOL)hasImageInterstitial {
    return BHTSensitiveWarningsSuppressed() ? NO : %orig;
}

- (id)imageInterstitial {
    return BHTSensitiveWarningsSuppressed() ? nil : %orig;
}

- (id)innerImageInterstitial {
    return BHTSensitiveWarningsSuppressed() ? nil : %orig;
}

%end

// TwitterURT.URTTimelineStatusItemViewModel
%hook _TtC10TwitterURT30URTTimelineStatusItemViewModel

- (BOOL)isPossiblySensitiveViewModelForAccount:(id)account {
    return BHTSensitiveWarningsSuppressed() ? NO : %orig;
}

- (BOOL)displaySensitiveContentAppealForAccount:(id)account {
    return BHTSensitiveWarningsSuppressed() ? NO : %orig;
}

- (BOOL)hasImageInterstitial {
    return BHTSensitiveWarningsSuppressed() ? NO : %orig;
}

%end

// What the status view itself reads when choosing between media and the
// tombstone.
%hook TTAStatusViewCombinedViewModel

- (BOOL)isPossiblySensitive {
    return BHTSensitiveWarningsSuppressed() ? NO : %orig;
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

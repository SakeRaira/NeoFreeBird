#import "../HookHelpers.h"

extern __thread BOOL DashPanelIDQuery;
extern __thread BOOL ReportGenuineSubscription;
extern __thread BOOL ReportGenuineTabGates;

// nil lets X handle the value, YES/NO overrides it
NSNumber* BHTFeatureSwitchOverrideValue(NSString* key, BOOL reportGenuineTabGates,
                                        BOOL (^isGenuinelyPremium)(void));
NSNumber* FeatureSwitchOverrideValueForKey(NSString* key);
BOOL panelIsGenuinelyAvailable(long long panelID);
NSArray* panelIDsForDashSnapshot(NSArray* panelIDs);
NSHashTable* DashContentControllers(void);
UIButton* BHTSensitiveMediaRevealButton(HFSensitiveTweetBlurredInterstitialView* overlay);
void BHTUpdateSensitiveMediaRevealButton(HFSensitiveTweetBlurredInterstitialView* overlay);
void BHTScheduleSensitiveMediaReveal(HFSensitiveTweetBlurredInterstitialView* overlay);
// Warnings off altogether, or `model` a retweet judged by its original
// post ("Judge retweets by the original post").
BOOL BHTHidesSensitiveWarningFor(id model);
// A media overlay showing a post through a retweet whose original has no
// sensitive mark ("Judge retweets by the original post").
BOOL BHTOverlayShowsRetweetOfUnmarkedPost(UIView* overlay);
NSString* BHTSensitiveOverlayDebugText(UIView* overlay, BOOL ageVerificationRequired, BOOL hasRevealButton);
// A label on the overlay saying why it was or wasn't opened (the highlight's
// debug option).
void BHTUpdateSensitiveOverlayDebug(HFSensitiveTweetBlurredInterstitialView* overlay);

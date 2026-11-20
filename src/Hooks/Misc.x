//
//  Misc.x
//  NeoFreeBird
//

#import <CoreText/CoreText.h>
#import <CydiaSubstrate.h>
#import "HookHelpers.h"

// MARK: - Always open in Safari

// In-app browser is used for two-factor authentication with security key,
// login will not complete successfully if it's redirected to Safari
static BOOL ShouldKeepBrowserURLInApp(NSURL* url) {
    NSString* urlStr = [url absoluteString];

    return [urlStr containsString:@"twitter.com/account/"] ||
           [urlStr containsString:@"twitter.com/i/flow/"] ||
           [urlStr containsString:@"x.com/account/"] || [urlStr containsString:@"x.com/i/flow/"];
}

// YouTube's app takes its https links as universal links, but a sideloaded
// (tweaked) YouTube usually isn't entitled to them, so those links land in
// Safari. It still claims the youtube:// scheme, so a YouTube link is handed
// to that instead, in the www.youtube.com form the app understands (youtu.be
// short links become watch?v=). YouTube Music has an app of its own and is
// left alone.
static NSURL* YouTubeAppURL(NSURL* url) {
    NSString* host = url.host.lowercaseString;
    NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (host.length == 0 || !components) {
        return nil;
    }

    if ([host isEqualToString:@"youtu.be"]) {
        NSString* videoID = [components.path
            stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if (videoID.length == 0 || [videoID containsString:@"/"]) {
            return nil;
        }
        NSMutableArray<NSURLQueryItem*>* items =
            [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"v" value:videoID]];
        for (NSURLQueryItem* item in components.queryItems) {
            if (![item.name isEqualToString:@"v"]) {
                [items addObject:item];
            }
        }
        components.path = @"/watch";
        components.queryItems = items;
    } else if (![host isEqualToString:@"youtube.com"] && ![host isEqualToString:@"www.youtube.com"] &&
               ![host isEqualToString:@"m.youtube.com"]) {
        return nil;
    }

    components.scheme = @"youtube";
    components.host = @"www.youtube.com";
    return components.URL;
}

// Opens a link outside the app: YouTube links in the YouTube app when one
// takes the scheme, falling back to the web link (Safari) otherwise, and
// everything else as is.
static void OpenURLOutsideApp(NSURL* url) {
    UIApplication* application = UIApplication.sharedApplication;
    NSURL* youTubeURL = YouTubeAppURL(url);
    if (!youTubeURL) {
        [application openURL:url options:@{} completionHandler:nil];
        return;
    }

    [application openURL:youTubeURL
                  options:@{}
        completionHandler:^(BOOL success) {
            if (!success) {
                [application openURL:url options:@{} completionHandler:nil];
            }
        }];
}

// Every tapped link that resolves to the in-app Safari goes through this single
// present funnel, so diverting here avoids presenting anything at all.
%hook T1SafariViewController

- (void)tfnPresentedCustomPresentFromViewController:(UIViewController*)fromViewController
                                           animated:(BOOL)animated
                                         completion:(void (^)(void))completion {
    if (![BHTSettings boolForKey:@"always_open_safari"]) {
        return %orig;
    }

    NSURL* url = [self rootURL] ?: [self initialURL];
    if (url == nil || ShouldKeepBrowserURLInApp(url)) {
        return %orig;
    }

    OpenURLOutsideApp(url);

    if (completion) {
        completion();
    }
}

%end

// Fallback for the plain SFSafariViewController surfaces (help pages, Grok,
// XLinkWebView), which don't go through the T1SafariViewController funnel.
%hook SFSafariViewController

- (void)viewWillAppear:(BOOL)animated {
    if (![BHTSettings boolForKey:@"always_open_safari"]) {
        return %orig;
    }

    NSURL* url = [self initialURL];
    if (url == nil || ShouldKeepBrowserURLInApp(url)) {
        return %orig;
    }

    OpenURLOutsideApp(url);
    [self dismissViewControllerAnimated:NO completion:nil];
}

%end

// MARK: - Strip tracking params from shared links

// Strips the ?s= baked into the share URL format strings; &t= is already disabled
// at the source (rehire_share_update_url_enabled in FeatureSwitches.x).
static NSString* CleanedShareURLString(NSString* urlString) {
    if (urlString == nil) {
        return urlString;
    }

    NSURLComponents* components = [NSURLComponents componentsWithString:urlString];
    if (components == nil) {
        return urlString;
    }

    NSMutableArray<NSURLQueryItem*>* safeParams = [NSMutableArray arrayWithCapacity:0];
    for (NSURLQueryItem* item in components.queryItems) {
        if (![item.name isEqualToString:@"s"] && ![item.name isEqualToString:@"t"] && ![item.name isEqualToString:@"a"]) {
            [safeParams addObject:item];
        }
    }
    components.queryItems = safeParams.count > 0 ? safeParams : nil;

    NSString* selectedHost = [[NSUserDefaults standardUserDefaults] objectForKey:@"sharing_domain"];
    if (selectedHost.length > 0) {
        components.host = selectedHost;
    }

    return components.URL.absoluteString ?: urlString;
}

%hook TFNTwitterStatus

- (NSString*)twitterURLForShareWithSParam:(unsigned long long)sParam {
    NSString* url = %orig;
    return CleanedShareURLString(url);
}

+ (NSString*)twitterURLForShareWithSParam:(unsigned long long)sParam
                                 username:(NSString*)username
                                 statusID:(long long)statusID {
    NSString* url = %orig;
    return CleanedShareURLString(url);
}

%end

static NSString* CleanedCopiedTweetURL(NSString* urlString) {
    if (![urlString isKindOfClass:[NSString class]]) {
        return urlString;
    }
    NSURLComponents* components = [NSURLComponents componentsWithString:urlString];
    NSString* host = components.host.lowercaseString;
    NSString* selectedHost = [[NSUserDefaults standardUserDefaults] objectForKey:@"sharing_domain"];
    BOOL isTwitterHost = [host isEqualToString:@"x.com"] || [host hasSuffix:@".x.com"] ||
                         [host isEqualToString:@"twitter.com"] ||
                         [host hasSuffix:@".twitter.com"] ||
                         (selectedHost.length > 0 && [host isEqualToString:selectedHost.lowercaseString]);
    if (!isTwitterHost || [components.path rangeOfString:@"/status/"].location == NSNotFound) {
        return urlString;
    }

    return CleanedShareURLString(urlString);
}

static void (*OriginalPasteboardSetString)(id, SEL, NSString*);

static void BHTPasteboardSetString(id pasteboard, SEL selector, NSString* string) {
    NSString* cleaned = CleanedCopiedTweetURL(string);
    OriginalPasteboardSetString(pasteboard, selector, cleaned);
}

// Profile links
%hook TFSTwitterUserReference

- (NSString*)twitterURLForShare {
    NSString* url = %orig;
    return CleanedShareURLString(url);
}

- (NSString*)twitterURLForCopy {
    NSString* url = %orig;
    return CleanedShareURLString(url);
}

%end

%hook T1AccountAutoplayPolicy

- (id)initWithCurrentSettings:(id)settings
    currentNetworkReachabilityStatus:(id)status
    notificationCenter:(id)center
    ignoreCurrentSettingsWhenAutoplayingGif:(_Bool)ignore {
    return %orig(settings, status, center, NO);
}

- (id)initWithIgnoreCurrentSettingsWhenAutoplayingGif:(_Bool)ignore {
    return %orig(NO);
}

%end

// MARK: - Disable screenshot and screen recording detection

%hook NSNotificationCenter

- (id)addObserverForName:(NSNotificationName)name
                  object:(id)obj
                   queue:(NSOperationQueue*)queue
              usingBlock:(void (^)(NSNotification* note))block {
    if ([name isEqualToString:UIApplicationUserDidTakeScreenshotNotification]) {
        return %orig(name, obj, queue,
                         ^(NSNotification* note){});
    }
    if ([name isEqualToString:UIScreenCapturedDidChangeNotification]) {
        return %orig(name, obj, queue,
                         ^(NSNotification* note){});
    }

    return %orig;
}

- (void)addObserver:(id)observer
           selector:(SEL)aSelector
               name:(NSNotificationName)aName
             object:(id)anObject {
    if ([aName isEqualToString:UIApplicationUserDidTakeScreenshotNotification]) {
        return;
    }
    if ([aName isEqualToString:UIScreenCapturedDidChangeNotification]) {
        return;
    }

    return %orig;
}

%end

%hook UIScreen
- (BOOL)isCaptured {
    return NO;
}
%end

%hook TUIFollowControlCustomScreenshot
- (void)didMoveToWindow {
    %orig;
    self.hidden = true;
    self.alpha = 0.0;
    self.userInteractionEnabled = false;
}
%end

// MARK: Hide the refresh pill at the top of the page that appears when new tweets are available
%hook TFNPillControl
- (void)didMoveToWindow {
    %orig;

    if ([BHTSettings boolForKey:@"hide_timeline_prompts"]) {
        self.userInteractionEnabled = NO;
        self.hidden = YES;
        self.alpha = 0.0;
    }
}

%end

%hook TFNFloatingActionButton
- (void)didMoveToWindow {
    %orig;

    if ([BHTSettings boolForKey:@"hide_tweet_button"]) {
        self.userInteractionEnabled = NO;
        self.hidden = YES;
        self.alpha = 0.0;
    }
}

%end

%ctor {
    %init;

    dispatch_async(dispatch_get_main_queue(), ^{
        Class pasteboardClass = object_getClass([UIPasteboard generalPasteboard]);
        if (pasteboardClass && class_getInstanceMethod(pasteboardClass, @selector(setString:))) {
            MSHookMessageEx(pasteboardClass, @selector(setString:),
                            (IMP)BHTPasteboardSetString,
                            (IMP*)&OriginalPasteboardSetString);
        }
    });
}

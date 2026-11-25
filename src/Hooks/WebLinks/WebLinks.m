#import "WebLinks.h"

static id WebLinksEntityForStatusURL(id status, NSURL* url) {
    if (![status respondsToSelector:@selector(entityForURL:)] ||
        ![url isKindOfClass:[NSURL class]]) {
        return nil;
    }

    id entity = ((id (*)(id, SEL, id))objc_msgSend)(status, @selector(entityForURL:),
                                                    url.absoluteString);
    if (entity != nil) {
        return entity;
    }

    id entitySet = ObjectForSelector(status, @selector(entities));
    id urlEntities = ObjectForSelector(entitySet, @selector(urls));
    if ([urlEntities isKindOfClass:[NSArray class]]) {
        for (id candidate in (NSArray*)urlEntities) {
            NSString* networkURL = ObjectForSelector(candidate, @selector(networkURL));
            NSURL* candidateURL = [NSURL URLWithString:networkURL];
            if (IsTalonURL(candidateURL) &&
                [TalonCacheKey(candidateURL) isEqualToString:TalonCacheKey(url)]) {
                return candidate;
            }
        }
    }
    return nil;
}

BOOL BlocksLinkTracking(void) {
    return [BHTSettings boolForKey:@"block_link_tracking"];
}

BOOL IsTalonURL(NSURL* url) {
    return [url isKindOfClass:[NSURL class]] && [url.host.lowercaseString isEqualToString:@"t.co"];
}

BOOL IsWebURL(NSURL* url) {
    NSString* scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"];
}

// t.co paths are case-sensitive, so only the scheme is normalised.
NSString* TalonCacheKey(NSURL* url) {
    return [@"t.co" stringByAppendingString:url.path ?: @""];
}

// Destinations of the t.co links seen so far, for the few places that open a
// link without passing its expansion along.
NSCache<NSString*, NSURL*>* KnownDestinations(void) {
    static NSCache* cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 2000;
    });
    return cache;
}

void RememberDestination(NSString* talonString, NSString* destinationString) {
    NSURL* talonURL = [NSURL URLWithString:talonString];
    NSURL* destination = [NSURL URLWithString:destinationString];
    if (IsTalonURL(talonURL) && IsWebURL(destination) && !IsTalonURL(destination)) {
        [KnownDestinations() setObject:destination forKey:TalonCacheKey(talonURL)];
    }
}

NSURL* WebLinksExpandedURLForStatus(id status, NSURL* url) {
    id entity = WebLinksEntityForStatusURL(status, url);

    NSString* expandedString = ObjectForSelector(entity, @selector(expandedURL));
    NSURL* expandedURL = [expandedString isKindOfClass:[NSString class]]
                             ? [NSURL URLWithString:expandedString]
                             : nil;
    if (IsWebURL(expandedURL) && !IsTalonURL(expandedURL)) {
        RememberDestination(url.absoluteString, expandedString);
        return expandedURL;
    }
    return nil;
}

NSURL* DestinationForLink(NSURL* url, NSURL* expandedURL) {
    NSURL* destination = url;

    if (BlocksLinkTracking() && IsTalonURL(url)) {
        if (IsWebURL(expandedURL) && !IsTalonURL(expandedURL)) {
            destination = expandedURL;
        } else {
            destination = [KnownDestinations() objectForKey:TalonCacheKey(url)] ?: url;
        }
    }

    if ([BHTSettings boolForKey:@"strip_tracking_params"]) {
        destination = URLByStrippingTrackingParameters(destination);
    }

    return destination;
}

BOOL IsTrackingParameter(NSString* name, NSString* host) {
    static NSSet<NSString*>* names;
    static NSSet<NSString*>* shareIDHosts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[
            @"fbclid", @"gclid", @"gclsrc", @"dclid", @"gbraid", @"wbraid", @"msclkid",
            @"twclid", @"ttclid", @"li_fat_id", @"igshid", @"igsh", @"mc_cid", @"mc_eid",
            @"_hsenc", @"_hsmi", @"mkt_tok", @"yclid", @"ref_src"
        ]];
        // si is a per-share tracking ID on these hosts but can mean anything
        // elsewhere.
        shareIDHosts = [NSSet setWithArray:@[
            @"youtube.com", @"m.youtube.com", @"music.youtube.com", @"youtu.be",
            @"open.spotify.com"
        ]];
    });

    NSString* lowercaseName = name.lowercaseString;
    if ([lowercaseName hasPrefix:@"utm_"] || [names containsObject:lowercaseName]) {
        return YES;
    }

    NSString* lowercaseHost = host.lowercaseString;
    if ([lowercaseHost hasPrefix:@"www."]) {
        lowercaseHost = [lowercaseHost substringFromIndex:4];
    }
    return [lowercaseName isEqualToString:@"si"] && [shareIDHosts containsObject:lowercaseHost];
}

NSURL* URLByStrippingTrackingParameters(NSURL* url) {
    if (!IsWebURL(url)) {
        return url;
    }

    NSURLComponents* components = [NSURLComponents componentsWithURL:url
                                             resolvingAgainstBaseURL:NO];
    // The percent-encoded accessors leave the remaining parameters byte-for-byte
    // as they were.
    NSArray<NSURLQueryItem*>* items = components.percentEncodedQueryItems;
    if (items.count == 0) {
        return url;
    }

    NSMutableArray<NSURLQueryItem*>* keptItems = [NSMutableArray arrayWithCapacity:items.count];
    for (NSURLQueryItem* item in items) {
        if (!IsTrackingParameter(item.name.stringByRemovingPercentEncoding ?: item.name,
                                 components.host)) {
            [keptItems addObject:item];
        }
    }
    if (keptItems.count == items.count) {
        return url;
    }

    components.percentEncodedQueryItems = keptItems.count > 0 ? keptItems : nil;
    return components.URL ?: url;
}

// In-app browser is used for two-factor authentication with security key,
// login will not complete successfully if it's redirected to Safari
BOOL ShouldKeepBrowserURLInApp(NSURL* url) {
    NSString* urlStr = [url absoluteString];

    return [urlStr containsString:@"twitter.com/account/"] ||
           [urlStr containsString:@"twitter.com/i/flow/"] ||
           [urlStr containsString:@"x.com/account/"] || [urlStr containsString:@"x.com/i/flow/"];
}

// Strips the ?s= baked into the share URL format strings; &t= is already disabled
// at the source (rehire_share_update_url_enabled in FeatureSwitches.x).
NSString* CleanedShareURLString(NSString* urlString) {
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

NSString* CleanedCopiedTweetURL(NSString* urlString) {
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

void BHTPasteboardSetString(id pasteboard, SEL selector, NSString* string) {
    NSString* cleaned = CleanedCopiedTweetURL(string);
    OriginalPasteboardSetString(pasteboard, selector, cleaned);
}

// YouTube's app takes its https links as universal links, but a sideloaded
// (tweaked) YouTube usually isn't entitled to them, so those links land in
// Safari. It still claims the youtube:// scheme, so a YouTube link is handed
// to that instead, in the www.youtube.com form the app understands (youtu.be
// short links become watch?v=). YouTube Music has an app of its own and is
// left alone.
NSURL* YouTubeAppURL(NSURL* url) {
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
void OpenURLOutsideApp(NSURL* url) {
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

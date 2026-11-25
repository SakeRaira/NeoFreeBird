#import "Timeline.h"

static BOOL StringSuggestsProfile(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return NO;
    }

    return [[(NSString*)value lowercaseString] containsString:@"profile"];
}

static NSString* ItemEntryID(id viewModel) {
    if (![viewModel respondsToSelector:@selector(entryID)]) {
        return nil;
    }

    NSString* entryID = [viewModel performSelector:@selector(entryID)];
    return [entryID isKindOfClass:[NSString class]] ? entryID : nil;
}

static NSString* ItemScribeComponent(id viewModel) {
    if (![viewModel respondsToSelector:@selector(scribeComponent)]) {
        return nil;
    }

    NSString* component = [viewModel performSelector:@selector(scribeComponent)];
    return [component isKindOfClass:[NSString class]] ? component : nil;
}

static BOOL ItemRespondsAndInvokesBOOL(id viewModel, SEL selector) {
    if (![viewModel respondsToSelector:selector]) {
        return NO;
    }

    return ((BOOL (*)(id, SEL))objc_msgSend)(viewModel, selector);
}

// Set when a reply is only on the feed because a followed account replied to
// someone else's tweet
static BOOL ItemIsReplyWithSocialContext(id viewModel) {
    return ItemRespondsAndInvokesBOOL(viewModel, @selector(isReplyAndShouldShowSocialContext));
}

static BOOL ItemIsConversationThreadReply(id viewModel) {
    return [ItemEntryID(viewModel) containsString:@"conversationthread"];
}

// The tweet's author and who it's directly replying to, for recognizing an
// exchange between the thread's own author and a verified user. Real user
// IDs are never 0, so that doubles as "unknown/unsupported".
static long long ItemRepresentedFromUserID(id viewModel) {
    SEL selector = @selector(representedFromUserID);
    if (![viewModel respondsToSelector:selector]) {
        return 0;
    }

    return ((long long (*)(id, SEL))objc_msgSend)(viewModel, selector);
}

static long long AdditionalItemRepresentedFromUserID(id viewModel) {
    SEL selector = @selector(fromUser);
    if (![viewModel respondsToSelector:selector]) {
        return 0;
    }

    // Get the userID NSInteger from the viewModel if the selector exists
    id fromUser = ((id (*)(id, SEL))objc_msgSend)(viewModel, selector);
    if (![fromUser respondsToSelector:@selector(userID)]) {
        return 0;
    }
    return ((long long (*)(id, SEL))objc_msgSend)(fromUser, @selector(userID));
}

static long long ItemInReplyToUserID(id viewModel) {
    SEL selector = @selector(inReplyToUserID);
    if (![viewModel respondsToSelector:selector]) {
        return 0;
    }

    return ((long long (*)(id, SEL))objc_msgSend)(viewModel, selector);
}

static long long CurrentAccountUserID(void) {
    Class hostClass = objc_getClass("T1HostViewController");
    if (!hostClass) {
        return 0;
    }

    id host = ((id (*)(id, SEL))objc_msgSend)(
        (id)hostClass, @selector(sharedHostViewController));
    if (![host respondsToSelector:@selector(currentAccount)]) {
        return 0;
    }

    id account = ((id (*)(id, SEL))objc_msgSend)(host, @selector(currentAccount));
    if (![account respondsToSelector:@selector(userID)]) {
        return 0;
    }

    return ((long long (*)(id, SEL))objc_msgSend)(account, @selector(userID));
}

static BOOL UserBlocksCurrentAccount(id user) {
    SEL relationshipSelector = @selector(relationship);
    if (![user respondsToSelector:relationshipSelector]) {
        return NO;
    }

    id relationship = ((id (*)(id, SEL))objc_msgSend)(user, relationshipSelector);
    SEL blockingSelector = @selector(blockingCurrentAccountState);
    if (![relationship respondsToSelector:blockingSelector]) {
        return NO;
    }

    NSInteger blockingState =
        ((NSInteger (*)(id, SEL))objc_msgSend)(relationship, blockingSelector);
    return blockingState == kBlockingCurrentAccountStateBlocking;
}

static BOOL ItemIsRetweetOfBlockingUser(id viewModel) {
    if (!ItemRespondsAndInvokesBOOL(viewModel, @selector(isRetweet))) {
        return NO;
    }

    SEL authorSelector = @selector(representedFromUser);
    if (![viewModel respondsToSelector:authorSelector]) {
        return NO;
    }

    return UserBlocksCurrentAccount(
        ((id (*)(id, SEL))objc_msgSend)(viewModel, authorSelector));
}

static BOOL ItemIsQuoteTweet(id viewModel) {
    if (!ItemRespondsAndInvokesBOOL(viewModel, @selector(isQuoteStatus))) {
        return NO;
    }

    long long currentAccountUserID = CurrentAccountUserID();
    long long representedFromUserID = AdditionalItemRepresentedFromUserID(viewModel);
    if (currentAccountUserID != 0 && representedFromUserID == currentAccountUserID) {
        return NO;
    }
    return YES;
}

static BOOL ItemIsRetweet(id viewModel) {
    if (!ItemRespondsAndInvokesBOOL(viewModel, @selector(isRetweet))) {
        return NO;
    }

    long long currentAccountUserID = CurrentAccountUserID();
    long long representedFromUserID = AdditionalItemRepresentedFromUserID(viewModel);
    if (currentAccountUserID != 0 && representedFromUserID == currentAccountUserID) {
        return NO;
    }

    return YES;
}

// MARK: - Replies in the home timeline

// A reply to someone else: the posts a followed account sends into other
// people's threads. Replies to oneself (threads), the account's own replies
// and retweets of a reply (shared on purpose) stay.
static BOOL ItemIsReplyToOthers(id viewModel) {
    if (!viewModel || ItemRespondsAndInvokesBOOL(viewModel, @selector(isRetweet))) {
        return NO;
    }

    BOOL isReply = BHTSafeBool(viewModel, @selector(isReply)) ||
                   BHTSafeLongLong(viewModel, @selector(inReplyToStatusID)) != 0;
    if (!isReply) {
        return NO;
    }

    long long authorID = ItemRepresentedFromUserID(viewModel);
    if (authorID == 0) {
        authorID = AdditionalItemRepresentedFromUserID(viewModel);
    }
    long long repliedToUserID = ItemInReplyToUserID(viewModel);
    if (authorID != 0 && repliedToUserID == authorID) {
        return NO;
    }

    long long currentAccountUserID = CurrentAccountUserID();
    return currentAccountUserID == 0 || authorID != currentAccountUserID;
}

// The home timeline shows a reply together with the posts it answers, as one
// conversation module whose items share an entry ID stem
// ("home-conversation-<n>-tweet-<id>"). The stem, or nil outside a module.
static NSString* ConversationModuleKey(id viewModel) {
    NSString* entryID = ItemEntryID(viewModel);
    if (![entryID containsString:@"conversation"]) {
        return nil;
    }

    static NSRegularExpression* stem;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stem = [NSRegularExpression regularExpressionWithPattern:@"^(.*?conversation[a-z]*-[0-9]+)"
                                                         options:0
                                                           error:nil];
    });
    NSTextCheckingResult* match = [stem firstMatchInString:entryID
                                                   options:0
                                                     range:NSMakeRange(0, entryID.length)];
    if (!match || [match rangeAtIndex:1].location == NSNotFound) {
        return nil;
    }
    return [entryID substringWithRange:[match rangeAtIndex:1]];
}

// The post an item shows: its own ID, or that of the status it wraps.
static long long ItemStatusID(id viewModel) {
    long long statusID = BHTSafeLongLong(viewModel, @selector(statusID));
    for (NSString* link in @[@"status", @"tweet", @"statusViewModel", @"representedStatus"]) {
        if (statusID != 0) {
            break;
        }
        statusID = BHTSafeLongLong(BHTSafeObject(viewModel, NSSelectorFromString(link)), @selector(statusID));
    }
    return statusID;
}

// The posts a hidden reply answers, and the ones those answer in turn: X
// shows them above the reply to give it context, and without the reply they
// are left on the timeline on their own.
static NSSet<NSNumber*>* PostsAnsweredByHiddenReplies(NSArray* sections) {
    NSMutableDictionary<NSNumber*, NSNumber*>* parentOfPost = [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber*>* pending = [NSMutableArray array];

    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            continue;
        }
        for (id item in (NSArray*)section) {
            id viewModel = unwrapDataViewItem(item);
            long long statusID = ItemStatusID(viewModel);
            long long parentID = BHTSafeLongLong(viewModel, @selector(inReplyToStatusID));
            if (statusID != 0) {
                parentOfPost[@(statusID)] = @(parentID);
            }
            if (parentID != 0 && ItemIsReplyToOthers(viewModel)) {
                [pending addObject:@(parentID)];
            }
        }
    }

    NSMutableSet<NSNumber*>* answered = [NSMutableSet set];
    while (pending.count > 0 && answered.count < 64) {
        NSNumber* postID = pending.lastObject;
        [pending removeLastObject];
        if ([answered containsObject:postID] || !parentOfPost[postID]) {
            continue;
        }
        [answered addObject:postID];
        if (parentOfPost[postID].longLongValue != 0) {
            [pending addObject:parentOfPost[postID]];
        }
    }
    return answered;
}

// Modules holding a hidden reply. The posts above it only came along to give
// the reply its context, so the whole module goes.
static NSSet<NSString*>* ConversationModulesWithHiddenReplies(NSArray* sections) {
    NSMutableSet<NSString*>* modules = [NSMutableSet set];
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            continue;
        }
        for (id item in (NSArray*)section) {
            id viewModel = unwrapDataViewItem(item);
            if (!ItemIsReplyToOthers(viewModel)) {
                continue;
            }
            NSString* module = ConversationModuleKey(viewModel);
            if (module) {
                [modules addObject:module];
            }
        }
    }
    return modules;
}


static BOOL ItemIsAITweet(id viewModel) {
    if (!ItemRespondsAndInvokesBOOL(viewModel, @selector(hasAIGeneratedDisclosure))) {
        return NO;
    }

    long long currentAccountUserID = CurrentAccountUserID();
    long long representedFromUserID = AdditionalItemRepresentedFromUserID(viewModel);
    if (currentAccountUserID != 0 && representedFromUserID == currentAccountUserID) {
        return NO;
    }

    return YES;
}

static BOOL ItemIsPaidTweet(id viewModel) {
    if (!ItemRespondsAndInvokesBOOL(viewModel, @selector(hasPaidPromotionDisclosure))) {
        return NO;
    }

    long long currentAccountUserID = CurrentAccountUserID();
    long long representedFromUserID = AdditionalItemRepresentedFromUserID(viewModel);
    if (currentAccountUserID != 0 && representedFromUserID == currentAccountUserID) {
        return NO;
    }

    return YES;
}

static BOOL BHShouldHideVerifiedItem(id viewModel, BHTimelineFilterContext* context) {
    SEL verifiedSelector = @selector(isFromUserVerified);
    if (![viewModel respondsToSelector:verifiedSelector]) {
        return NO;
    }

    BOOL verified = ((BOOL (*)(id, SEL))objc_msgSend)(viewModel, verifiedSelector);
    if (!verified) {
        return NO;
    }

    SEL bookmarkedSelector = @selector(displayAsBookmarked);
    if ([viewModel respondsToSelector:bookmarkedSelector]) {
        BOOL bookmarked = ((BOOL (*)(id, SEL))objc_msgSend)(viewModel, bookmarkedSelector);
        if (bookmarked) {
            return NO;
        }
    }

    if (context.inConversation) {
        if (!ItemIsConversationThreadReply(viewModel)) {
            return NO;
        }

        if (context.conversationRootUserID != 0) {
            long long repliedUserID = ItemRepresentedFromUserID(viewModel);

            BOOL isAuthorsOwnReply = repliedUserID == context.conversationRootUserID;
            BOOL authorRepliedToThisUser =
                [context.authorRepliedToUserIDs containsObject:@(repliedUserID)];
            if (isAuthorsOwnReply || authorRepliedToThisUser) {
                return NO;
            }
        }
    }

    if (!context.inConversation && ItemIsReplyWithSocialContext(viewModel)) {
        return NO;
    }

    SEL followStateSelector = @selector(representedFromUserFollowedByCurrentAccountState);
    if ([viewModel respondsToSelector:followStateSelector]) {
        NSInteger followState =
            ((NSInteger (*)(id, SEL))objc_msgSend)(viewModel, followStateSelector);
        if (followState == kFollowedByCurrentAccountStateFollowing) {
            return NO;
        }
    }

    return YES;
}

// MARK: - NG words

// The return type of a real (not forwarded) zero-argument method, or 0. The
// text lookup probes selectors like -status and -text across unrelated view
// model classes, and one returning a scalar must never be called as if it
// returned an object.
static char NGReturnType(id object, SEL selector) {
    if (!object) {
        return 0;
    }
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    const char* encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding ? encoding[0] : 0;
}

static id NGObjectForSelector(id object, SEL selector) {
    if (NGReturnType(object, selector) != '@') {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString* NGStringForSelector(id object, SEL selector) {
    id value = NGObjectForSelector(object, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

// Everything a timeline item says: its own text (with URLs expanded, and the
// full text of long posts), plus that of the retweeted original and of the
// quoted post. View models may be a TFNTwitterStatus or wrap one, sometimes
// two deep.
static NSString* ItemSearchableText(id viewModel) {
    static NSArray<NSString*>* links;
    static NSArray<NSString*>* textSelectors;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        links = @[@"statusViewModel", @"tweet", @"status", @"representedStatus",
                  @"retweetedStatus", @"quotedStatus", @"quotedStatusViewModel"];
        textSelectors = @[@"textWithExpandedURLs", @"fullText", @"text", @"displayText"];
    });

    NSHashTable* seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSMutableArray* queue = [NSMutableArray arrayWithObject:viewModel];
    [seen addObject:viewModel];
    NSMutableArray<NSString*>* texts = [NSMutableArray array];

    for (NSUInteger i = 0; i < queue.count && i < 16; i++) {
        id object = queue[i];

        for (NSString* name in textSelectors) {
            NSString* text = NGStringForSelector(object, NSSelectorFromString(name));
            if (text.length > 0) {
                [texts addObject:text];
                break;
            }
        }

        NSString* noteText = NGStringForSelector(NGObjectForSelector(object, @selector(noteTweet)),
                                                 @selector(text));
        if (noteText.length > 0) {
            [texts addObject:noteText];
        }

        for (NSString* name in links) {
            id linked = NGObjectForSelector(object, NSSelectorFromString(name));
            if (linked && ![seen containsObject:linked]) {
                [seen addObject:linked];
                [queue addObject:linked];
            }
        }
    }

    return [texts componentsJoinedByString:@"\n"];
}

static BOOL ItemMatchesNGWords(id viewModel, BHTimelineFilterContext* context) {
    // In a conversation only replies are filtered; the post that was opened
    // and the ones it replies to stay.
    if (context.inConversation && !ItemIsConversationThreadReply(viewModel)) {
        return NO;
    }

    // The account's own posts always stay.
    long long currentAccountUserID = CurrentAccountUserID();
    if (currentAccountUserID != 0 &&
        (ItemRepresentedFromUserID(viewModel) == currentAccountUserID ||
         AdditionalItemRepresentedFromUserID(viewModel) == currentAccountUserID)) {
        return NO;
    }

    NSString* text = ItemSearchableText(viewModel);
    return text.length > 0 && [BHTNGWords matchInText:text] != nil;
}


static BOOL ShouldHideTimelineItem(id item, BHTimelineFilterContext* context) {
    id viewModel = unwrapDataViewItem(item);
    NSString* className = NSStringFromClass([viewModel classForCoder]);

    if (context.hideVerified && BHShouldHideVerifiedItem(viewModel, context)) {
        return YES;
    }

    if (context.hideNGWords && viewModel && ItemMatchesNGWords(viewModel, context)) {
        return YES;
    }

    if (context.hideReplies && ItemIsReplyToOthers(viewModel)) {
        return YES;
    }

    if (context.inNotifications) {
        return NO;
    }

    if (context.hideBlockedRetweets && ItemIsRetweetOfBlockingUser(viewModel)) {
        return YES;
    }

    if (context.hidePrompts && [className isEqualToString:@"TwitterURT.URTTimelinePromptViewModel"]) {
        return YES;
    }

    if (context.hideWhoToFollow && [ItemScribeComponent(viewModel)
                                       isEqualToString:@"suggest_who_to_follow"]) {
        return YES;
    }

    if (context.hideWhoToFollow && context.inProfile &&
        [className isEqualToString:@"T1TwitterSwift.URTTimelineCarouselViewModel"]) {
        return YES;
    }

    if (!context.inProfile && context.hideQuoteTweets && ItemIsQuoteTweet(viewModel) &&
        !ItemIsReplyWithSocialContext(viewModel)) {
        return YES;
    }

    if (!context.inProfile && context.hideRetweets && ItemIsRetweet(viewModel)) {
        return YES;
    }

    if (!context.inProfile && context.hideAITweets && ItemIsAITweet(viewModel)) {
        return YES;
    }

    if (!context.inProfile && context.hidePaidTweets && ItemIsPaidTweet(viewModel)) {
        return YES;
    }

    NSString* entryID = ItemEntryID(viewModel);

    if (!entryID) {
        return NO;
    }

    if (context.inConversation && [entryID hasPrefix:@"tweetdetailrelatedtweets"]) {
        return YES;
    }

    if (context.hideWhoToFollow && [entryID containsString:@"who-to-follow"]) {
        return YES;
    }

    return NO;
}

// Calling ShouldHideTimelineItem() for every item on every section update slows
// the app down a LOT, so verdicts are memoized by entry ID. They only hold for
// the context that produced them; a different context drops the whole cache.
static NSCache<NSString*, NSNumber*>* TimelineVerdictCacheForContext(
    BHTimelineFilterContext* context) {
    static NSCache<NSString*, NSNumber*>* cache;
    static BHTimelineFilterContext* cachedContext;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 4000;
    });

    if (![context isEqualToContext:cachedContext]) {
        [cache removeAllObjects];
        cachedContext = context;
    }

    return cache;
}

static BOOL MemoizedShouldHideTimelineItem(id item, NSCache<NSString*, NSNumber*>* cache,
                                           BHTimelineFilterContext* context) {
    NSString* entryID = ItemEntryID(unwrapDataViewItem(item));
    if (!entryID) {
        return ShouldHideTimelineItem(item, context);
    }

    NSNumber* cached = [cache objectForKey:entryID];
    if (cached) {
        return cached.boolValue;
    }

    BOOL hide = ShouldHideTimelineItem(item, context);
    [cache setObject:@(hide) forKey:entryID];
    return hide;
}

// The server sends the carousel as one timeline entry, but the app expands it
// into separate header/content/footer view models. Drop the entry from the
// GraphQL response so the whole module never reaches that expansion.
BOOL IsGraphQLResponse(NSURL* url) {
    return [url.path.pathComponents containsObject:@"graphql"];
}

id RemoveVideoCarouselEntries(id node, BOOL* removed) {
    if ([node isKindOfClass:[NSArray class]]) {
        NSMutableArray* kept = [NSMutableArray array];
        for (id value in (NSArray*)node) {
            id entryID = [value isKindOfClass:[NSDictionary class]] ? value[@"entry_id"] : nil;
            if ([entryID isKindOfClass:[NSString class]] &&
                [entryID hasPrefix:@"video-carousel-"]) {
                *removed = YES;
                continue;
            }

            [kept addObject:RemoveVideoCarouselEntries(value, removed)];
        }
        return kept;
    }

    if ([node isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary* copy = [node mutableCopy];
        for (NSString* key in node) {
            copy[key] = RemoveVideoCarouselEntries(node[key], removed);
        }
        return copy;
    }

    return node;
}

// Resolves the class by name so mangled Swift names work; NSStringFromClass
// would only ever produce the demangled dotted form.
BOOL IsInHierarchyOfClass(UIViewController* viewController, NSString* className) {
    Class targetClass = NSClassFromString(className);
    if (!targetClass) {
        return NO;
    }

    UIViewController* currentVC = viewController;

    while (currentVC) {
        if ([currentVC isKindOfClass:targetClass]) {
            return YES;
        }

        if (currentVC.parentViewController) {
            currentVC = currentVC.parentViewController;
        } else if (currentVC.navigationController) {
            currentVC = currentVC.navigationController;
        } else if (currentVC.presentingViewController) {
            currentVC = currentVC.presentingViewController;
        } else {
            break;
        }
    }

    return NO;
}

// Need to tag edit history since it reuses a generic class

BOOL IsInEditHistory(UIViewController* viewController) {
    UIViewController* currentVC = viewController;

    while (currentVC) {
        if (objc_getAssociatedObject(currentVC, EditHistoryViewControllerKey)) {
            return YES;
        }

        currentVC = currentVC.parentViewController;
    }

    return NO;
}

BOOL NavigationMetadataIsFromProfile(id metadata) {
    if (!metadata) {
        return NO;
    }

    if ([metadata respondsToSelector:@selector(name)] &&
        StringSuggestsProfile(ObjectForSelector(metadata, @selector(name)))) {
        return YES;
    }

    id scribeContext = nil;
    if ([metadata respondsToSelector:@selector(sourceScribeContext)]) {
        scribeContext = ObjectForSelector(metadata, @selector(sourceScribeContext));
    }

    for (NSUInteger depth = 0; scribeContext && depth < 8; depth++) {
        NSArray<NSString*>* selectors = @[@"page", @"section", @"component", @"element"];
        for (NSString* selectorName in selectors) {
            SEL selector = NSSelectorFromString(selectorName);
            if ([scribeContext respondsToSelector:selector] &&
                StringSuggestsProfile(ObjectForSelector(scribeContext, selector))) {
                return YES;
            }
        }

        if (![scribeContext respondsToSelector:@selector(sourceContext)]) {
            break;
        }
        scribeContext = ObjectForSelector(scribeContext, @selector(sourceContext));
    }

    return NO;
}

BOOL IsInProfileOriginConversation(UIViewController* viewController) {
    UIViewController* currentVC = viewController;

    while (currentVC) {
        if (objc_getAssociatedObject(currentVC, ConversationOpenedFromProfileKey)) {
            return YES;
        }

        if (currentVC.parentViewController) {
            currentVC = currentVC.parentViewController;
        } else if (currentVC.navigationController) {
            currentVC = currentVC.navigationController;
        } else if (currentVC.presentingViewController) {
            currentVC = currentVC.presentingViewController;
        } else {
            break;
        }
    }

    return NO;
}

long long ConversationRootUserID(NSArray* sections) {
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            continue;
        }

        for (id item in (NSArray*)section) {
            id viewModel = unwrapDataViewItem(item);
            if (ItemIsConversationThreadReply(viewModel)) {
                continue;
            }

            long long userID = ItemRepresentedFromUserID(viewModel);
            if (userID != 0) {
                return userID;
            }
        }
    }

    return 0;
}

NSSet<NSNumber*>* ConversationAuthorRepliedToUserIDs(NSArray* sections,
                                                     long long rootUserID) {
    NSMutableSet<NSNumber*>* repliedToUserIDs = [NSMutableSet set];
    if (rootUserID == 0) {
        return repliedToUserIDs;
    }

    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            continue;
        }

        for (id item in (NSArray*)section) {
            id viewModel = unwrapDataViewItem(item);
            if (!ItemIsConversationThreadReply(viewModel)) {
                continue;
            }

            if (ItemRepresentedFromUserID(viewModel) != rootUserID) {
                continue;
            }

            long long repliedToUserID = ItemInReplyToUserID(viewModel);
            if (repliedToUserID != 0) {
                [repliedToUserIDs addObject:@(repliedToUserID)];
            }
        }
    }

    return repliedToUserIDs;
}

NSArray* FilteredTimelineSections(TFNItemsDataViewController* dataViewController,
                                  NSArray* sections) {
    BHTimelineFilterContext* context =
        [BHTimelineFilterContext contextForDataViewController:dataViewController];
    if (!context.shouldFilter) {
        return sections;
    }

    [context resolveConversationLookupsInSections:sections];
    NSCache<NSString*, NSNumber*>* verdicts = TimelineVerdictCacheForContext(context);
    // Depends on the other items in this update, so it isn't memoized.
    NSSet<NSString*>* hiddenModules =
        context.hideReplies ? ConversationModulesWithHiddenReplies(sections) : nil;
    NSSet<NSNumber*>* answeredPosts =
        context.hideReplies ? PostsAnsweredByHiddenReplies(sections) : nil;

    // Modules can share a section with unrelated items, so filtering is per item;
    // a purely filtered section (like the Discover More one) empties and is dropped.
    BOOL modified = NO;
    NSMutableArray* filteredSections = [NSMutableArray arrayWithCapacity:sections.count];

    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            [filteredSections addObject:section];
            continue;
        }

        NSArray* items = section;
        NSMutableIndexSet* removed = [NSMutableIndexSet indexSet];

        for (NSUInteger i = 0; i < items.count; i++) {
            if (hiddenModules.count > 0) {
                NSString* module = ConversationModuleKey(unwrapDataViewItem(items[i]));
                if (module && [hiddenModules containsObject:module]) {
                    [removed addIndex:i];
                    continue;
                }
            }
            if (answeredPosts.count > 0) {
                long long statusID = ItemStatusID(unwrapDataViewItem(items[i]));
                if (statusID != 0 && [answeredPosts containsObject:@(statusID)]) {
                    [removed addIndex:i];
                    continue;
                }
            }
            if (MemoizedShouldHideTimelineItem(items[i], verdicts, context)) {
                [removed addIndex:i];
            }
        }

        if (removed.count == 0) {
            [filteredSections addObject:section];
            continue;
        }

        MarkEmptiedModuleChrome(items, removed);

        modified = YES;
        NSMutableArray* keptItems = [items mutableCopy];
        [keptItems removeObjectsAtIndexes:removed];
        if (keptItems.count > 0) {
            [filteredSections addObject:keptItems];
        }
    }

    return modified ? [filteredSections copy] : sections;
}

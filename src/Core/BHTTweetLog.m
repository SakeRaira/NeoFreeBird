//
//  BHTTweetLog.m
//  NeoFreeBird
//

#import "Core/BHTTweetLog.h"
#import <UIKit/UIKit.h>

NSNotificationName const BHTTweetLogDidChangeNotification = @"BHTTweetLogDidChangeNotification";

NSString* const BHTTweetLogEnabledKey = @"tweet_log_enabled";
NSString* const BHTTweetLogAllScreensKey = @"tweet_log_all_screens";
NSString* const BHTTweetLogLimitKey = @"tweet_log_limit";

static const NSInteger kDefaultLimit = 500;
// Seen again within this long, a Tweet keeps its place in the log.
static const NSTimeInterval kResurfaceInterval = 10 * 60;
// Changes are written out this long after the first one, in one go.
static const NSTimeInterval kSaveDelay = 2;

static NSMutableArray<NSDictionary*>* sEntries;
static NSMutableDictionary<NSString*, NSDictionary*>* sEntriesByID;
static BOOL sSaveScheduled = NO;
static BOOL sChangePosted = NO;

@implementation BHTTweetLog

#pragma mark - Settings

+ (BOOL)enabled {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:BHTTweetLogEnabledKey];
    return value ? [value boolValue] : YES;
}

+ (NSInteger)limit {
    NSInteger limit = [NSUserDefaults.standardUserDefaults integerForKey:BHTTweetLogLimitKey];
    return limit > 0 ? limit : kDefaultLimit;
}

+ (void)setLimit:(NSInteger)limit {
    [NSUserDefaults.standardUserDefaults setInteger:limit forKey:BHTTweetLogLimitKey];
    [self loadIfNeeded];
    if ([self trim]) {
        [self didChange];
    }
}

+ (NSArray<NSNumber*>*)limitChoices {
    return @[@100, @300, @500, @1000, @2000, @5000];
}

#pragma mark - Storage

+ (NSString*)filePath {
    NSString* support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                            NSUserDomainMask, YES).firstObject;
    NSString* directory = [support stringByAppendingPathComponent:@"NeoFreeBird"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    return [directory stringByAppendingPathComponent:@"TweetLog.plist"];
}

static dispatch_queue_t SaveQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.neofreebird.tweetlog.save", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

+ (void)loadIfNeeded {
    if (sEntries) {
        return;
    }

    sEntries = [NSMutableArray array];
    sEntriesByID = [NSMutableDictionary dictionary];

    NSData* data = [NSData dataWithContentsOfFile:[self filePath]];
    id stored = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                 options:NSPropertyListImmutable
                                                                  format:NULL
                                                                   error:nil]
                     : nil;
    if ([stored isKindOfClass:NSArray.class]) {
        for (id entry in (NSArray*)stored) {
            NSString* statusID = [entry isKindOfClass:NSDictionary.class] ? entry[@"id"] : nil;
            if ([statusID isKindOfClass:NSString.class] && !sEntriesByID[statusID]) {
                [sEntries addObject:entry];
                sEntriesByID[statusID] = entry;
            }
        }
    }
    [self trim];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(saveNow)
                                               name:UIApplicationDidEnterBackgroundNotification
                                             object:nil];
}

// Drops the oldest entries past the limit; YES if any went.
+ (BOOL)trim {
    NSInteger limit = self.limit;
    BOOL trimmed = NO;
    while ((NSInteger)sEntries.count > limit) {
        NSDictionary* oldest = sEntries.lastObject;
        [sEntriesByID removeObjectForKey:oldest[@"id"]];
        [sEntries removeLastObject];
        trimmed = YES;
    }
    return trimmed;
}

+ (void)saveNow {
    if (!sEntries) {
        return;
    }
    sSaveScheduled = NO;

    NSArray* snapshot = [sEntries copy];
    NSString* path = [self filePath];
    dispatch_async(SaveQueue(), ^{
        NSData* data = [NSPropertyListSerialization dataWithPropertyList:snapshot
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0
                                                                   error:nil];
        [data writeToFile:path atomically:YES];
    });
}

+ (void)didChange {
    if (!sSaveScheduled) {
        sSaveScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSaveDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (sSaveScheduled) {
                               [self saveNow];
                           }
                       });
    }

    // Scrolling records many Tweets in a row; one notification per run loop
    // turn is enough for the history page.
    if (!sChangePosted) {
        sChangePosted = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            sChangePosted = NO;
            [NSNotificationCenter.defaultCenter postNotificationName:BHTTweetLogDidChangeNotification
                                                              object:nil];
        });
    }
}

#pragma mark - Entries

+ (NSArray<NSDictionary*>*)entries {
    [self loadIfNeeded];
    return [sEntries copy];
}

+ (void)recordEntry:(NSDictionary*)entry {
    NSString* statusID = entry[@"id"];
    if (![statusID isKindOfClass:NSString.class] || statusID.length == 0) {
        return;
    }
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self recordEntry:entry];
        });
        return;
    }

    [self loadIfNeeded];

    NSDictionary* existing = sEntriesByID[statusID];
    if (existing) {
        NSDate* seen = existing[@"seen"];
        if ([seen isKindOfClass:NSDate.class] && -seen.timeIntervalSinceNow < kResurfaceInterval) {
            return;
        }
        [sEntries removeObjectIdenticalTo:existing];
    }

    NSMutableDictionary* stamped = [entry mutableCopy];
    stamped[@"seen"] = [NSDate date];
    NSDictionary* stored = [stamped copy];
    [sEntries insertObject:stored atIndex:0];
    sEntriesByID[statusID] = stored;
    [self trim];
    [self didChange];
}

+ (void)removeEntryWithID:(NSString*)statusID {
    [self loadIfNeeded];
    NSDictionary* existing = sEntriesByID[statusID];
    if (!existing) {
        return;
    }
    [sEntries removeObjectIdenticalTo:existing];
    [sEntriesByID removeObjectForKey:statusID];
    [self didChange];
}

+ (void)clear {
    [self loadIfNeeded];
    [sEntries removeAllObjects];
    [sEntriesByID removeAllObjects];
    [self didChange];
}

@end

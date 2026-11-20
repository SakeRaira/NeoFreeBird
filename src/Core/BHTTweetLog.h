//
//  BHTTweetLog.h
//  NeoFreeBird
//
//  A log of the Tweets shown in the timeline, newest first, kept on the
//  device. TweetLog.x records them; TweetLogViewController shows them as a
//  tab of the sidebar's History.
//
//  Each entry is a property-list dictionary, so the log never depends on X's
//  own classes:
//    id       NSString   status ID
//    name     NSString   author's display name
//    handle   NSString   author's @username, without the @
//    avatar   NSString   avatar image URL
//    text     NSString
//    date     NSDate     when it was posted
//    media    NSArray    [{url: NSString, video: NSNumber(BOOL)}]
//    replies, retweets, likes   NSNumber, as they were when seen
//    rtBy     NSString   who retweeted it into the timeline, if anyone
//    seen     NSDate     when it was last shown
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main queue after the log changed.
extern NSNotificationName const BHTTweetLogDidChangeNotification;

extern NSString* const BHTTweetLogEnabledKey;     // BOOL, on by default
extern NSString* const BHTTweetLogAllScreensKey;  // BOOL, off: home timeline only
extern NSString* const BHTTweetLogLimitKey;       // NSInteger

@interface BHTTweetLog : NSObject

@property (class, nonatomic, readonly) BOOL enabled;
@property (class, nonatomic, readonly) NSInteger limit;
@property (class, nonatomic, readonly) NSArray<NSNumber*>* limitChoices;

+ (void)setLimit:(NSInteger)limit;

// Newest first. Main thread only, like everything below.
+ (NSArray<NSDictionary*>*)entries;

// Adds the entry at the top. A Tweet already in the log moves to the top
// again only when it was last seen a while ago, so scrolling back and forth
// doesn't keep reshuffling it.
+ (void)recordEntry:(NSDictionary*)entry;

+ (void)removeEntryWithID:(NSString*)statusID;
+ (void)clear;

@end

NS_ASSUME_NONNULL_END

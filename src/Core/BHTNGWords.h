//
//  BHTNGWords.h
//  NeoFreeBird
//
//  NG words: tweets containing one are left out of timelines (Timeline.x).
//
//  Matching is meant to be hard to slip past, unlike X's own muted words:
//  both the word and the tweet are compared after NFKC normalization (full-
//  and half-width forms, circled digits), lowercasing, katakana folded into
//  hiragana, and with whitespace, punctuation, symbols, emoji and invisible
//  characters removed, so "副 業", "ﾌｸｷﾞｮｳ" vs "ふくぎょう" or "副🔥業" still
//  count. A word written as /pattern/ is a case-insensitive regular
//  expression matched against the text as is.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString* const BHTNGWordsEnabledKey;  // BOOL, on by default
extern NSString* const BHTNGWordsListKey;     // [NSString]
extern NSString* const BHTNGWordsSummaryKey;  // subtitle for the settings row

typedef NS_ENUM(NSInteger, BHTNGWordValidity) {
    BHTNGWordValid,
    // Nothing would be left to match after normalization (only spaces or
    // symbols), which would hide every tweet.
    BHTNGWordEmpty,
    BHTNGWordInvalidRegex,
};

@interface BHTNGWords : NSObject

@property (class, nonatomic, readonly) BOOL enabled;
@property (class, nonatomic, readonly) NSArray<NSString*>* words;
// Enabled with at least one usable word.
@property (class, nonatomic, readonly) BOOL active;
// Changes whenever the words or the switch change, so cached verdicts can
// tell they are stale.
@property (class, nonatomic, readonly) NSUInteger generation;

+ (void)setEnabled:(BOOL)enabled;
+ (void)setWords:(NSArray<NSString*>*)words;

+ (BOOL)isRegexWord:(NSString*)word;
+ (BHTNGWordValidity)validityOfWord:(NSString*)word;

// The NG word found in the text, or nil.
+ (nullable NSString*)matchInText:(NSString*)text;

+ (NSString*)normalizedString:(NSString*)text;

@end

NS_ASSUME_NONNULL_END

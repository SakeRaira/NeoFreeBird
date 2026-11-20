//
//  BHTNGWords.m
//  NeoFreeBird
//

#import "Core/BHTNGWords.h"
#import "Core/BHTBundle.h"

NSString* const BHTNGWordsEnabledKey = @"ng_words_enabled";
NSString* const BHTNGWordsListKey = @"ng_words";
NSString* const BHTNGWordsSummaryKey = @"ng_words_summary";

// Bumped on every change; starts above zero so a context built before any
// change still differs from "never computed".
static NSUInteger sGeneration = 1;

// Compiled form of the current words, rebuilt when the generation moves on.
static NSUInteger sCompiledGeneration = 0;
static NSArray<NSArray*>* sCompiledPlain;   // [[original, normalized]]
static NSArray<NSArray*>* sCompiledRegex;   // [[original, NSRegularExpression]]

// Characters that carry no meaning for matching and are used to break words
// up: whitespace, punctuation, symbols (emoji included), controls, and the
// invisible formatting characters (zero-width spaces and joiners, bidi
// controls, variation selectors, tags, fillers).
static NSCharacterSet* IgnoredCharacters(void) {
    static NSCharacterSet* ignored;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet* set = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
        [set formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];
        [set formUnionWithCharacterSet:NSCharacterSet.punctuationCharacterSet];
        [set formUnionWithCharacterSet:NSCharacterSet.symbolCharacterSet];
        [set formUnionWithCharacterSet:NSCharacterSet.illegalCharacterSet];
        [set addCharactersInRange:NSMakeRange(0x00AD, 1)];     // soft hyphen
        [set addCharactersInRange:NSMakeRange(0x034F, 1)];     // combining grapheme joiner
        [set addCharactersInRange:NSMakeRange(0x115F, 2)];     // hangul fillers
        [set addCharactersInRange:NSMakeRange(0x180B, 5)];     // mongolian selectors, vowel separator
        [set addCharactersInRange:NSMakeRange(0x200B, 5)];     // zero-width space ... RLM
        [set addCharactersInRange:NSMakeRange(0x202A, 5)];     // bidi embeddings
        [set addCharactersInRange:NSMakeRange(0x2060, 16)];    // word joiner ... invisible operators
        [set addCharactersInRange:NSMakeRange(0x20D0, 0x21)];  // combining marks for symbols (keycaps)
        [set addCharactersInRange:NSMakeRange(0x3164, 1)];     // hangul filler
        [set addCharactersInRange:NSMakeRange(0xFE00, 16)];    // variation selectors
        [set addCharactersInRange:NSMakeRange(0xFEFF, 1)];     // zero-width no-break space
        [set addCharactersInRange:NSMakeRange(0xFFA0, 1)];     // halfwidth hangul filler
        [set addCharactersInRange:NSMakeRange(0x1F3FB, 5)];    // skin tone modifiers
        [set addCharactersInRange:NSMakeRange(0xE0000, 0x80)]; // tags
        [set addCharactersInRange:NSMakeRange(0xE0100, 0xF0)]; // variation selectors supplement
        ignored = [set copy];
    });
    return ignored;
}

@implementation BHTNGWords

#pragma mark - Settings

+ (BOOL)enabled {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:BHTNGWordsEnabledKey];
    return value ? [value boolValue] : YES;
}

+ (void)setEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:BHTNGWordsEnabledKey];
    [self didChange];
}

+ (NSArray<NSString*>*)words {
    NSArray* stored = [NSUserDefaults.standardUserDefaults arrayForKey:BHTNGWordsListKey];
    NSMutableArray* words = [NSMutableArray array];
    for (id word in stored) {
        if ([word isKindOfClass:NSString.class] && [word length] > 0) {
            [words addObject:word];
        }
    }
    return words;
}

+ (void)setWords:(NSArray<NSString*>*)words {
    [NSUserDefaults.standardUserDefaults setObject:words forKey:BHTNGWordsListKey];
    [self didChange];
}

+ (NSUInteger)generation {
    @synchronized(self) {
        return sGeneration;
    }
}

+ (void)didChange {
    @synchronized(self) {
        sGeneration++;
    }

    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSUInteger count = self.words.count;
    if (!self.enabled || count == 0) {
        [defaults removeObjectForKey:BHTNGWordsSummaryKey];
        return;
    }
    NSString* format = [[BHTBundle sharedBundle] localizedStringForKey:@"NG_WORDS_SUMMARY_FORMAT"];
    [defaults setObject:[NSString stringWithFormat:format, (long)count] forKey:BHTNGWordsSummaryKey];
}

+ (BOOL)active {
    if (!self.enabled) {
        return NO;
    }
    [self compileIfNeeded];
    @synchronized(self) {
        return sCompiledPlain.count + sCompiledRegex.count > 0;
    }
}

#pragma mark - Words

+ (BOOL)isRegexWord:(NSString*)word {
    return word.length >= 3 && [word hasPrefix:@"/"] && [word hasSuffix:@"/"];
}

+ (nullable NSRegularExpression*)regexForWord:(NSString*)word {
    NSString* pattern = [word substringWithRange:NSMakeRange(1, word.length - 2)];
    return [NSRegularExpression regularExpressionWithPattern:pattern
                                                     options:NSRegularExpressionCaseInsensitive
                                                       error:nil];
}

+ (BHTNGWordValidity)validityOfWord:(NSString*)word {
    if ([self isRegexWord:word]) {
        return [self regexForWord:word] ? BHTNGWordValid : BHTNGWordInvalidRegex;
    }
    return [self normalizedString:word].length > 0 ? BHTNGWordValid : BHTNGWordEmpty;
}

+ (void)compileIfNeeded {
    NSUInteger generation = self.generation;
    @synchronized(self) {
        if (sCompiledGeneration == generation) {
            return;
        }
    }

    NSMutableArray* plain = [NSMutableArray array];
    NSMutableArray* regex = [NSMutableArray array];
    for (NSString* word in self.words) {
        if ([self isRegexWord:word]) {
            NSRegularExpression* expression = [self regexForWord:word];
            if (expression) {
                [regex addObject:@[word, expression]];
            }
            continue;
        }

        NSString* normalized = [self normalizedString:word];
        if (normalized.length > 0) {
            [plain addObject:@[word, normalized]];
        }
    }

    @synchronized(self) {
        sCompiledPlain = [plain copy];
        sCompiledRegex = [regex copy];
        sCompiledGeneration = generation;
    }
}

+ (nullable NSString*)matchInText:(NSString*)text {
    if (text.length == 0 || !self.enabled) {
        return nil;
    }

    [self compileIfNeeded];
    NSArray* plain;
    NSArray* regex;
    @synchronized(self) {
        plain = sCompiledPlain;
        regex = sCompiledRegex;
    }

    if (plain.count > 0) {
        NSString* normalized = [self normalizedString:text];
        for (NSArray* entry in plain) {
            if ([normalized rangeOfString:entry[1]].location != NSNotFound) {
                return entry[0];
            }
        }
    }

    for (NSArray* entry in regex) {
        NSRegularExpression* expression = entry[1];
        if ([expression firstMatchInString:text options:0 range:NSMakeRange(0, text.length)]) {
            return entry[0];
        }
    }

    return nil;
}

#pragma mark - Normalization

+ (NSString*)normalizedString:(NSString*)text {
    if (text.length == 0) {
        return @"";
    }

    // NFKC first: full-width letters and digits, half-width kana, circled
    // and other compatibility forms all collapse to their plain form, and
    // kana with voicing marks become single characters.
    NSMutableString* folded = [[text precomposedStringWithCompatibilityMapping] mutableCopy];
    // Katakana into hiragana, so either spelling matches the other.
    CFStringTransform((__bridge CFMutableStringRef)folded, NULL, kCFStringTransformHiraganaKatakana, true);
    NSString* lowered = [folded lowercaseString];

    NSUInteger length = lowered.length;
    unichar* input = malloc(sizeof(unichar) * length);
    unichar* output = malloc(sizeof(unichar) * length);
    if (!input || !output) {
        free(input);
        free(output);
        return lowered;
    }
    [lowered getCharacters:input range:NSMakeRange(0, length)];

    NSCharacterSet* ignored = IgnoredCharacters();
    NSUInteger written = 0;
    for (NSUInteger i = 0; i < length;) {
        UTF32Char codePoint = input[i];
        NSUInteger units = 1;
        if (CFStringIsSurrogateHighCharacter(input[i]) && i + 1 < length &&
            CFStringIsSurrogateLowCharacter(input[i + 1])) {
            codePoint = CFStringGetLongCharacterForSurrogatePair(input[i], input[i + 1]);
            units = 2;
        }

        if (![ignored longCharacterIsMember:codePoint]) {
            for (NSUInteger unit = 0; unit < units; unit++) {
                output[written++] = input[i + unit];
            }
        }
        i += units;
    }

    NSString* normalized = [NSString stringWithCharacters:output length:written];
    free(input);
    free(output);
    return normalized;
}

@end

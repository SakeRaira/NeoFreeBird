//
//  GrokModifications.x
//  NeoFreeBird
//

#import "FeatureSwitches.h"

// MARK: - Grok modifications of posted media

// New attachments start with "Allow Grok modifications" off. Only the starting
// value changes: the composer's and the photo editor's content settings read
// it from the asset, so switching it back on there still sticks. Drafts come
// back through -initWithCoder: and keep what they were saved with.
@interface TTMAsset : NSObject
@property (nonatomic) BOOL blockGrokModifications;
@end

%hook TTMAsset

- (instancetype)init {
    self = %orig;
    if (self && [BHTSettings boolForKey:@"block_grok_modifications_by_default"]) {
        // TTMAsset's own setter rather than a subclass override:
        // TTMAssetXPhotoEditorImage forwards to an editor result it hasn't
        // set up yet while it is still in -[super init].
        SEL setter = @selector(setBlockGrokModifications:);
        IMP baseSetter = class_getMethodImplementation(objc_getClass("TTMAsset"), setter);
        if (baseSetter && [self respondsToSelector:setter]) {
            ((void (*)(id, SEL, BOOL))baseSetter)(self, setter, YES);
        }
    }
    return self;
}

%end

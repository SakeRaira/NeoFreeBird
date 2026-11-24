//
//  BHTWatermark.m
//  NeoFreeBird
//

#import "Core/BHTWatermark.h"
#import "Core/BHTBundle.h"
#import "Core/BHTSettings.h"

NSNotificationName const BHTWatermarkDidChangeNotification = @"BHTWatermarkDidChangeNotification";

static NSString* const kEnabledKey = @"background_watermark";
static NSString* const kOpacityKey = @"background_watermark_opacity";
static NSString* const kSummaryKey = @"background_watermark_image_summary";
static const NSInteger kDefaultOpacity = 15;

// Loaded once and shared by every screen; reset when the picture changes.
static UIImage* CachedImage;
static BOOL CachedImageLoaded;

@implementation BHTWatermark

+ (NSString*)filePath {
    NSString* support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                            NSUserDomainMask, YES).firstObject;
    NSString* directory = [support stringByAppendingPathComponent:@"NeoFreeBird"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    return [directory stringByAppendingPathComponent:@"Watermark.jpg"];
}

+ (UIImage*)image {
    if (!CachedImageLoaded) {
        CachedImageLoaded = YES;
        NSData* data = [NSData dataWithContentsOfFile:self.filePath];
        CachedImage = data ? [UIImage imageWithData:data scale:UIScreen.mainScreen.scale] : nil;
    }
    return CachedImage;
}

+ (BOOL)active {
    return [BHTSettings boolForKey:kEnabledKey] && self.image != nil;
}

+ (NSInteger)opacityPercent {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kOpacityKey];
    NSInteger percent = value ? [value integerValue] : kDefaultOpacity;
    return MIN(MAX(percent, 1), 100);
}

+ (void)setOpacityPercent:(NSInteger)percent {
    [NSUserDefaults.standardUserDefaults setInteger:MIN(MAX(percent, 1), 100) forKey:kOpacityKey];
    [self postChange];
}

+ (NSArray<NSNumber*>*)opacityChoices {
    return @[@5, @10, @15, @20, @25, @30, @40, @50, @70];
}

// No larger than the screen in pixels, so a camera photo doesn't sit in
// memory at full size behind every tab.
+ (UIImage*)scaledForScreen:(UIImage*)image {
    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGFloat longest = MAX(screen.width, screen.height);
    CGFloat imageLongest = MAX(image.size.width, image.size.height);
    if (imageLongest <= 0) {
        return nil;
    }

    CGFloat factor = MIN(1.0, longest / imageLongest);
    CGSize size = CGSizeMake(floor(image.size.width * factor), floor(image.size.height * factor));
    UIGraphicsImageRendererFormat* format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = UIScreen.mainScreen.scale;
    format.opaque = YES;
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
}

+ (BOOL)setImage:(UIImage*)image {
    UIImage* scaled = [self scaledForScreen:image];
    NSData* data = scaled ? UIImageJPEGRepresentation(scaled, 0.9) : nil;
    if (!data || ![data writeToFile:self.filePath atomically:YES]) {
        return NO;
    }

    CachedImage = [UIImage imageWithData:data scale:UIScreen.mainScreen.scale];
    CachedImageLoaded = YES;
    [NSUserDefaults.standardUserDefaults
        setObject:[[BHTBundle sharedBundle] localizedStringForKey:@"WATERMARK_IMAGE_SET"]
           forKey:kSummaryKey];
    [self postChange];
    return YES;
}

+ (void)removeImage {
    [NSFileManager.defaultManager removeItemAtPath:self.filePath error:nil];
    CachedImage = nil;
    CachedImageLoaded = YES;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kSummaryKey];
    [self postChange];
}

+ (void)postChange {
    [NSNotificationCenter.defaultCenter postNotificationName:BHTWatermarkDidChangeNotification object:nil];
}

@end

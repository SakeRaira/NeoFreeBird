//
//  BHTWatermark.h
//  NeoFreeBird
//
//  A picture of the user's choosing shown as the wallpaper behind the app's
//  tab screens (Watermark.x draws it). Stores the picture and how strongly it
//  shows through the theme's background color.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const BHTWatermarkDidChangeNotification;

@interface BHTWatermark : NSObject

// The option is on and a picture has been chosen.
@property (class, nonatomic, readonly) BOOL active;
@property (class, nonatomic, readonly, nullable) UIImage* image;

// How strongly the picture shows, in percent (opacity).
@property (class, nonatomic) NSInteger opacityPercent;
@property (class, nonatomic, readonly) NSArray<NSNumber*>* opacityChoices;

// Saves a copy scaled to the screen. NO if it couldn't be written.
+ (BOOL)setImage:(UIImage*)image;
+ (void)removeImage;

// Tells the screens to redraw it, after the option is switched.
+ (void)postChange;

@end

NS_ASSUME_NONNULL_END

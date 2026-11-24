//
//  Watermark.x
//  NeoFreeBird
//
//  Draws the chosen background picture (BHTWatermark) faintly over each tab's
//  screens. It sits in the tab's navigation controller view, above the
//  screens and below the navigation bar: the picture stays put while
//  timelines scroll underneath, and the bars stay clear. It takes no touches.
//

#import "HookHelpers.h"
#import "Core/BHTWatermark.h"

@interface BHTWatermarkView : UIImageView
@end

@implementation BHTWatermarkView

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    return nil;
}

@end

static const void* WatermarkViewKey = &WatermarkViewKey;

static NSHashTable<UINavigationController*>* WatermarkedNavigationControllers(void) {
    static NSHashTable* controllers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controllers = [NSHashTable weakObjectsHashTable];
    });
    return controllers;
}

// Moves the view only when it's out of place: this runs from layout, and
// re-inserting it every time would ask for layout again.
static void PlaceWatermark(UIView* watermark, UIView* container, UIView* navigationBar) {
    NSArray<UIView*>* subviews = container.subviews;
    if (navigationBar.superview == container) {
        NSUInteger barIndex = [subviews indexOfObjectIdenticalTo:navigationBar];
        NSUInteger index = [subviews indexOfObjectIdenticalTo:watermark];
        if (index == NSNotFound || index + 1 != barIndex) {
            [container insertSubview:watermark belowSubview:navigationBar];
        }
    } else if (subviews.lastObject != watermark) {
        [container addSubview:watermark];
    }

    if (!CGRectEqualToRect(watermark.frame, container.bounds)) {
        watermark.frame = container.bounds;
    }
}

static void UpdateWatermark(UINavigationController* navigationController) {
    UIView* container = navigationController.isViewLoaded ? navigationController.view : nil;
    BHTWatermarkView* watermark = objc_getAssociatedObject(navigationController, WatermarkViewKey);
    if (!container || !BHTWatermark.active) {
        [watermark removeFromSuperview];
        return;
    }

    if (!watermark) {
        watermark = [[BHTWatermarkView alloc] initWithFrame:container.bounds];
        watermark.contentMode = UIViewContentModeScaleAspectFill;
        watermark.clipsToBounds = YES;
        watermark.userInteractionEnabled = NO;
        watermark.isAccessibilityElement = NO;
        watermark.accessibilityElementsHidden = YES;
        watermark.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(navigationController, WatermarkViewKey, watermark,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIImage* image = BHTWatermark.image;
    if (watermark.image != image) {
        watermark.image = image;
    }
    CGFloat alpha = BHTWatermark.opacityPercent / 100.0;
    if (fabs(watermark.alpha - alpha) > 0.001) {
        watermark.alpha = alpha;
    }
    PlaceWatermark(watermark, container, navigationController.navigationBar);
}

%hook T1TabNavigationController

- (void)viewDidLayoutSubviews {
    %orig;
    [WatermarkedNavigationControllers() addObject:(UINavigationController*)self];
    UpdateWatermark((UINavigationController*)self);
}

%end

%ctor {
    %init;
    [NSNotificationCenter.defaultCenter addObserverForName:BHTWatermarkDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* notification) {
                                                    for (UINavigationController* controller in
                                                         WatermarkedNavigationControllers().allObjects) {
                                                        UpdateWatermark(controller);
                                                    }
                                                }];
}

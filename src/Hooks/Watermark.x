//
//  Watermark.x
//  NeoFreeBird
//
//  Wallpaper: the chosen picture (BHTWatermark) behind each tab's screens.
//  It sits at the bottom of the tab's navigation controller view, the theme's
//  background color over it at the chosen strength, so it stays put while
//  timelines scroll and never covers text or icons.
//
//  For it to show, what is painted in the theme's background color above it
//  is made clear: full-height screens, the timelines and lists, and their
//  cells. Short views such as the Home tab strip keep their color, so content
//  scrolling under them doesn't show through. Every color changed is
//  remembered and put back when the wallpaper is turned off.
//

#import <QuartzCore/QuartzCore.h>
#import "HookHelpers.h"
#import "Core/BHTWatermark.h"

@interface BHTWallpaperView : UIView
@property (nonatomic, strong) UIImageView* imageView;
@end

@implementation BHTWallpaperView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.isAccessibilityElement = NO;
        self.accessibilityElementsHidden = YES;
        self.clipsToBounds = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _imageView = [[UIImageView alloc] initWithFrame:self.bounds];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_imageView];
    }
    return self;
}

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    return nil;
}

@end

static const void* WallpaperViewKey = &WallpaperViewKey;
static const void* OriginalBackgroundKey = &OriginalBackgroundKey;
static const void* WallpaperListKey = &WallpaperListKey;
static const void* WallpaperCellKey = &WallpaperCellKey;
static const void* WallpaperPassKey = &WallpaperPassKey;

// Read on every cell layout, so kept here instead of asking the settings.
static BOOL WallpaperOn;
// Bumped on every change; list and cell marks from an older one are stale.
static NSUInteger WallpaperGeneration = 1;

static NSHashTable<UINavigationController*>* WallpaperedNavigationControllers(void) {
    static NSHashTable* controllers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controllers = [NSHashTable weakObjectsHashTable];
    });
    return controllers;
}

static NSHashTable<UIView*>* ClearedViews(void) {
    static NSHashTable* views;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        views = [NSHashTable weakObjectsHashTable];
    });
    return views;
}

// MARK: - Theme background

// The palette is read at most once a second; it only changes with the theme.
static UIColor* ThemeBackgroundColor(void) {
    static UIColor* cached;
    static CFTimeInterval readAt;
    CFTimeInterval now = CACurrentMediaTime();
    if (!cached || now - readAt > 1.0) {
        cached = [Palette currentBackgroundColor];
        readAt = now;
    }
    return cached;
}

static BOOL ColorIsThemeBackground(UIColor* color, UIView* view) {
    if (!color) {
        return NO;
    }
    UITraitCollection* traits = view.traitCollection;
    CGFloat r1, g1, b1, a1, r2, g2, b2, a2;
    if (![[color resolvedColorWithTraitCollection:traits] getRed:&r1 green:&g1 blue:&b1 alpha:&a1] ||
        ![[ThemeBackgroundColor() resolvedColorWithTraitCollection:traits] getRed:&r2
                                                                            green:&g2
                                                                             blue:&b2
                                                                            alpha:&a2]) {
        return NO;
    }
    return a1 > 0.98 && fabs(r1 - r2) < 0.02 && fabs(g1 - g2) < 0.02 && fabs(b1 - b2) < 0.02;
}

static void ClearThemeBackground(UIView* view) {
    if (!view || [view isKindOfClass:BHTWallpaperView.class] ||
        !ColorIsThemeBackground(view.backgroundColor, view)) {
        return;
    }
    objc_setAssociatedObject(view, OriginalBackgroundKey, view.backgroundColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [ClearedViews() addObject:view];
    view.backgroundColor = UIColor.clearColor;
}

static void RestoreClearedBackgrounds(void) {
    for (UIView* view in ClearedViews().allObjects) {
        UIColor* original = objc_getAssociatedObject(view, OriginalBackgroundKey);
        if (original && [view.backgroundColor isEqual:UIColor.clearColor]) {
            view.backgroundColor = original;
        }
        objc_setAssociatedObject(view, OriginalBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [ClearedViews() removeAllObjects];
}

// MARK: - Screens and lists

static BOOL IsList(UIView* view) {
    return [view isKindOfClass:UITableView.class] || [view isKindOfClass:UICollectionView.class];
}

// Screens and lists that fill most of the tab, as opposed to bars and headers.
static BOOL IsFullHeight(UIView* view, UIView* container) {
    return view.bounds.size.height >= container.bounds.size.height * 0.5;
}

static void ClearList(UIView* list, UIView* container) {
    if (!IsFullHeight(list, container)) {
        return;
    }
    ClearThemeBackground(list);
    if ([list isKindOfClass:UITableView.class]) {
        ClearThemeBackground(((UITableView*)list).backgroundView);
    } else if ([list isKindOfClass:UICollectionView.class]) {
        ClearThemeBackground(((UICollectionView*)list).backgroundView);
    }
    objc_setAssociatedObject(list, WallpaperListKey, @(WallpaperGeneration), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Walks the tab's view tree down to its lists, whose cells are handled as
// they lay out.
static void ClearScreens(UIView* container, UIView* navigationBar) {
    NSMutableArray<UIView*>* queue = [NSMutableArray array];
    for (UIView* subview in container.subviews) {
        if (subview != navigationBar && ![subview isKindOfClass:BHTWallpaperView.class]) {
            [queue addObject:subview];
        }
    }

    for (NSUInteger i = 0; i < queue.count && i < 400; i++) {
        UIView* view = queue[i];
        if (view.hidden || !IsFullHeight(view, container)) {
            continue;
        }
        if (IsList(view)) {
            ClearList(view, container);
            continue;
        }
        ClearThemeBackground(view);
        [queue addObjectsFromArray:view.subviews];
    }
}

// MARK: - The wallpaper

// The tree walk runs again only for a new screen on top or a new setting:
// layout can come often (bars collapsing while scrolling).
static BOOL NeedsScreenPass(UINavigationController* navigationController) {
    NSString* pass = [NSString stringWithFormat:@"%lu-%p-%lu", (unsigned long)WallpaperGeneration,
                                                (__bridge void*)navigationController.topViewController,
                                                (unsigned long)navigationController.viewControllers.count];
    if ([objc_getAssociatedObject(navigationController, WallpaperPassKey) isEqualToString:pass]) {
        return NO;
    }
    objc_setAssociatedObject(navigationController, WallpaperPassKey, pass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static void UpdateWallpaper(UINavigationController* navigationController, BOOL force) {
    UIView* container = navigationController.isViewLoaded ? navigationController.view : nil;
    BHTWallpaperView* wallpaper = objc_getAssociatedObject(navigationController, WallpaperViewKey);
    if (!container || !WallpaperOn) {
        [wallpaper removeFromSuperview];
        return;
    }

    if (!wallpaper) {
        wallpaper = [[BHTWallpaperView alloc] initWithFrame:container.bounds];
        objc_setAssociatedObject(navigationController, WallpaperViewKey, wallpaper,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Moved only when out of place: this runs from layout.
    if (wallpaper.superview != container || container.subviews.firstObject != wallpaper) {
        [container insertSubview:wallpaper atIndex:0];
    }
    if (!CGRectEqualToRect(wallpaper.frame, container.bounds)) {
        wallpaper.frame = container.bounds;
    }

    UIColor* theme = ThemeBackgroundColor();
    if (![wallpaper.backgroundColor isEqual:theme]) {
        wallpaper.backgroundColor = theme;
    }
    UIImage* image = BHTWatermark.image;
    if (wallpaper.imageView.image != image) {
        wallpaper.imageView.image = image;
    }
    CGFloat alpha = BHTWatermark.opacityPercent / 100.0;
    if (fabs(wallpaper.imageView.alpha - alpha) > 0.001) {
        wallpaper.imageView.alpha = alpha;
    }

    if (force || NeedsScreenPass(navigationController)) {
        ClearScreens(container, navigationController.navigationBar);
    }
}

static void ApplyWallpaperChange(void) {
    WallpaperOn = BHTWatermark.active;
    WallpaperGeneration++;
    if (!WallpaperOn) {
        RestoreClearedBackgrounds();
    }
    for (UINavigationController* controller in WallpaperedNavigationControllers().allObjects) {
        UpdateWallpaper(controller, YES);
    }
}

%hook T1TabNavigationController

- (void)viewDidLayoutSubviews {
    %orig;
    [WallpaperedNavigationControllers() addObject:(UINavigationController*)self];
    UpdateWallpaper((UINavigationController*)self, NO);
}

%end

// MARK: - Timelines shown later

// A timeline that appears after the tab last laid out (a Home tab switched
// to, a page loaded late) clears itself and the screens holding it.
static void ClearDataViewController(UIViewController* controller) {
    if (!WallpaperOn || !controller.isViewLoaded) {
        return;
    }

    UINavigationController* navigationController = controller.navigationController;
    if (![WallpaperedNavigationControllers() containsObject:navigationController]) {
        return;
    }
    UIView* container = navigationController.view;
    ClearScreens(container, navigationController.navigationBar);

    for (NSString* name in @[@"tableView", @"collectionView"]) {
        id list = BHTSafeObject(controller, NSSelectorFromString(name));
        if ([list isKindOfClass:UIView.class] && IsList(list)) {
            ClearList(list, container);
        }
    }
    for (UIView* view = controller.view; view && view != container; view = view.superview) {
        if (IsList(view)) {
            ClearList(view, container);
        } else if (IsFullHeight(view, container)) {
            ClearThemeBackground(view);
        }
    }
}

%hook TFNItemsDataViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ClearDataViewController((UIViewController*)self);
}

%end

// MARK: - Cells

static BOOL CellIsInWallpaperedList(UIView* cell) {
    UIView* list = cell.superview;
    for (NSUInteger depth = 0; list && depth < 2; depth++, list = list.superview) {
        NSNumber* generation = objc_getAssociatedObject(list, WallpaperListKey);
        if (generation.unsignedIntegerValue == WallpaperGeneration) {
            return YES;
        }
    }
    return NO;
}

// The cell and its content view every time (X recolors them on reuse), and
// once per change a few levels below, where a status view may paint the
// row's background itself.
static void ClearCell(UIView* cell, UIView* contentView, UIView* backgroundView) {
    if (!WallpaperOn || !CellIsInWallpaperedList(cell)) {
        return;
    }

    ClearThemeBackground(cell);
    ClearThemeBackground(contentView);
    ClearThemeBackground(backgroundView);

    NSNumber* done = objc_getAssociatedObject(cell, WallpaperCellKey);
    UIView* statusView = BHTSafeObject(cell, @selector(statusView));
    if ([statusView isKindOfClass:UIView.class]) {
        for (UIView* view = statusView; view && view != cell; view = view.superview) {
            ClearThemeBackground(view);
        }
    }
    if (done.unsignedIntegerValue == WallpaperGeneration) {
        return;
    }
    objc_setAssociatedObject(cell, WallpaperCellKey, @(WallpaperGeneration), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSMutableArray<UIView*>* queue = [contentView.subviews mutableCopy] ?: [NSMutableArray array];
    for (NSUInteger i = 0; i < queue.count && i < 40; i++) {
        UIView* view = queue[i];
        ClearThemeBackground(view);
        if (!IsList(view) && ![view isKindOfClass:UIImageView.class]) {
            [queue addObjectsFromArray:view.subviews];
        }
    }
}

%hook UITableViewCell

- (void)layoutSubviews {
    %orig;
    if (WallpaperOn) {
        ClearCell(self, self.contentView, self.backgroundView);
    }
}

%end

%hook UICollectionViewCell

- (void)layoutSubviews {
    %orig;
    if (WallpaperOn) {
        ClearCell(self, self.contentView, self.backgroundView);
    }
}

%end

%ctor {
    %init;
    WallpaperOn = BHTWatermark.active;
    [NSNotificationCenter.defaultCenter addObserverForName:BHTWatermarkDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* notification) {
                                                    ApplyWallpaperChange();
                                                }];
}

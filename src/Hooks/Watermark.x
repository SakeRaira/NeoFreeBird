//
//  Watermark.x
//  NeoFreeBird
//
//  Wallpaper: the chosen picture (BHTWatermark) behind the timelines.
//
//  Each timeline list (the table or collection view of a
//  TFNItemsDataViewController inside a tab) gets it as its backgroundView,
//  which UIKit draws behind the cells, sized to the list and fixed while it
//  scrolls. Its theme-colored tint sets how strongly the picture shows.
//
//  X's cells paint their own background through a private view of
//  TFNTableViewCell, not their background color; the cell's
//  hostProvidesBackground switch, made for lists that draw the background
//  themselves, turns that off. It's set as each cell is about to show, along
//  with clearing the few views in it painted in the theme's background color.
//  Every change is remembered and undone when the wallpaper is turned off.
//
//  Nothing is added to UIKit's own container views: an earlier version kept
//  the picture at the bottom of the navigation view, where it fought UIKit
//  for the first place on every layout.
//
//  "Every screen" mode paints, instead of the theme's background color, the
//  matching part of the picture: each screen whose own view is painted in
//  that color gets a layer at the bottom of it holding its part of the
//  picture over the color. The screen stays opaque, so whatever is behind it
//  (the previous screen during a transition, a screen under a sheet) stays
//  hidden. Every part is laid out against the window, so they line up as one
//  picture.
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

        _imageView = [[UIImageView alloc] initWithFrame:self.bounds];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        [self addSubview:_imageView];
    }
    return self;
}

// The picture is laid out against the whole window, not this view, so the
// lists and the bars each show their own part of one picture.
- (void)layoutSubviews {
    [super layoutSubviews];
    UIWindow* window = self.window;
    CGRect frame = window ? [self convertRect:window.bounds fromView:window] : self.bounds;
    if (!CGRectEqualToRect(self.imageView.frame, frame)) {
        self.imageView.frame = frame;
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self setNeedsLayout];
}

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    return nil;
}

@end

static const void* ListWallpaperKey = &ListWallpaperKey;
static const void* ListOriginalBackgroundViewKey = &ListOriginalBackgroundViewKey;
static const void* OriginalBackgroundKey = &OriginalBackgroundKey;

// Read for every cell shown, so kept here instead of asking the settings.
static BOOL WallpaperOn;
// The option to also show it behind the header and the tab bar.
static BOOL BarsOn;
// The option to show it on every screen (bars included).
static BOOL FullOn;

static NSHashTable* WeakSet(NSHashTable* __strong* storage) {
    if (!*storage) {
        *storage = [NSHashTable weakObjectsHashTable];
    }
    return *storage;
}

static NSHashTable* SeenControllersStorage;
static NSHashTable* WallpaperedListsStorage;
static NSHashTable* HostChangedCellsStorage;
static NSHashTable* ClearedViewsStorage;
static NSHashTable* BarBackgroundsStorage;
static NSHashTable* SeenTabBarControllersStorage;
static NSHashTable* PaintedScreensStorage;

// MARK: - Theme background

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
    // X mostly hands out the palette's own color object.
    if (color == ThemeBackgroundColor()) {
        return YES;
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

// Some views color their layer directly, leaving the view's color unset.
static const void* LayerBackgroundKey = &LayerBackgroundKey;

static NSHashTable* BarClearedViewsStorage;

// Remembered in `storage`, so the bars' changes can be undone on their own.
static void ClearThemeBackgroundInto(UIView* view, NSHashTable* __strong* storage) {
    if (![view isKindOfClass:UIView.class]) {
        return;
    }
    UIColor* color = view.backgroundColor;
    BOOL layerOnly = NO;
    if (!color && view.layer.backgroundColor) {
        color = [UIColor colorWithCGColor:view.layer.backgroundColor];
        layerOnly = YES;
    }
    if (!ColorIsThemeBackground(color, view)) {
        return;
    }
    objc_setAssociatedObject(view, OriginalBackgroundKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, LayerBackgroundKey, layerOnly ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [WeakSet(storage) addObject:view];
    if (layerOnly) {
        view.layer.backgroundColor = UIColor.clearColor.CGColor;
    } else {
        view.backgroundColor = UIColor.clearColor;
    }
}

static void ClearThemeBackground(UIView* view) {
    ClearThemeBackgroundInto(view, &ClearedViewsStorage);
}

static void RestoreClearedViews(NSHashTable* __strong* storage) {
    for (UIView* view in WeakSet(storage).allObjects) {
        UIColor* original = objc_getAssociatedObject(view, OriginalBackgroundKey);
        if (objc_getAssociatedObject(view, LayerBackgroundKey)) {
            CGColorRef current = view.layer.backgroundColor;
            if (original && (!current || CGColorGetAlpha(current) < 0.01)) {
                view.layer.backgroundColor = [original resolvedColorWithTraitCollection:view.traitCollection].CGColor;
            }
        } else if (original && [view.backgroundColor isEqual:UIColor.clearColor]) {
            view.backgroundColor = original;
        }
        objc_setAssociatedObject(view, OriginalBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, LayerBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [WeakSet(storage) removeAllObjects];
}

// Views inside a post painted in the theme's background color: the quoted
// post's card, the box behind the ••• button and the like. Runs once per cell
// shown, never while scrolling, and stops early: pictures, text and inner
// lists (media carousels) are never opened, and at most 150 views are looked
// at.
static void ClearThemeBackgroundsInside(UIView* root) {
    NSMutableArray<UIView*>* queue = [root.subviews mutableCopy] ?: [NSMutableArray array];
    for (NSUInteger i = 0; i < queue.count && i < 150; i++) {
        UIView* view = queue[i];
        if (view.hidden) {
            continue;
        }
        ClearThemeBackground(view);
        if ([view isKindOfClass:UIImageView.class] || [view isKindOfClass:UILabel.class] ||
            [view isKindOfClass:UIScrollView.class] || [view isKindOfClass:UITextView.class]) {
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
}

// MARK: - Lists

static UIScrollView* ListOfController(UIViewController* controller) {
    for (NSString* name in @[@"tableView", @"collectionView"]) {
        id list = BHTSafeObject(controller, NSSelectorFromString(name));
        if ([list isKindOfClass:UITableView.class] || [list isKindOfClass:UICollectionView.class]) {
            return list;
        }
    }
    return nil;
}

static UIView* ListBackgroundView(UIScrollView* list) {
    return [list respondsToSelector:@selector(backgroundView)] ? [(id)list backgroundView] : nil;
}

static void SetListBackgroundView(UIScrollView* list, UIView* view) {
    if ([list respondsToSelector:@selector(setBackgroundView:)] && ListBackgroundView(list) != view) {
        [(id)list setBackgroundView:view];
    }
}

// Full timelines inside a tab (anywhere in "every screen" mode), not small
// embedded lists such as carousels.
static BOOL ControllerWantsWallpaper(UIViewController* controller, UIScrollView* list) {
    if (!WallpaperOn || !list) {
        return NO;
    }
    if (FullOn) {
        UIWindow* window = list.window;
        return window && list.bounds.size.height >= window.bounds.size.height * 0.5;
    }
    Class tabNavigationClass = objc_getClass("T1TabNavigationController");
    UINavigationController* navigationController = controller.navigationController;
    if (!tabNavigationClass || ![navigationController isKindOfClass:tabNavigationClass]) {
        return NO;
    }
    return list.bounds.size.height >= navigationController.view.bounds.size.height * 0.5;
}

static void UpdateWallpaperView(BHTWallpaperView* wallpaper) {
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
}

static void RemoveListWallpaper(UIScrollView* list) {
    BHTWallpaperView* wallpaper = objc_getAssociatedObject(list, ListWallpaperKey);
    if (!wallpaper) {
        return;
    }
    if (ListBackgroundView(list) == wallpaper) {
        id original = objc_getAssociatedObject(list, ListOriginalBackgroundViewKey);
        SetListBackgroundView(list, [original isKindOfClass:UIView.class] ? original : nil);
    }
    objc_setAssociatedObject(list, ListWallpaperKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(list, ListOriginalBackgroundViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ListHasWallpaper(UIScrollView* list) {
    BHTWallpaperView* wallpaper = objc_getAssociatedObject(list, ListWallpaperKey);
    return wallpaper && ListBackgroundView(list) == wallpaper;
}

// MARK: - Cells

static void PrepareCell(UIView* cell, UIScrollView* list) {
    if (!WallpaperOn || !ListHasWallpaper(list) || ![cell isKindOfClass:UIView.class]) {
        return;
    }

    SEL hostGetter = @selector(hostProvidesBackground);
    SEL hostSetter = @selector(setHostProvidesBackground:);
    if ([cell respondsToSelector:hostSetter] && !BHTSafeBool(cell, hostGetter)) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(cell, hostSetter, YES);
        [WeakSet(&HostChangedCellsStorage) addObject:cell];
    }

    ClearThemeBackground(cell);
    UIView* contentView = [cell respondsToSelector:@selector(contentView)] ? [(id)cell contentView] : nil;
    ClearThemeBackground(contentView);
    ClearThemeBackground(nfb_objectIvar(cell, "_backgroundView"));

    UIView* statusView = BHTSafeObject(cell, @selector(statusView));
    if ([statusView isKindOfClass:UIView.class] && [statusView isDescendantOfView:cell]) {
        ClearThemeBackgroundsInside(statusView);
        for (UIView* view = statusView; view && view != cell; view = view.superview) {
            ClearThemeBackground(view);
        }
    }
}

static void PrepareVisibleCells(UIScrollView* list) {
    if (![list respondsToSelector:@selector(visibleCells)]) {
        return;
    }
    for (UIView* cell in [(id)list visibleCells]) {
        PrepareCell(cell, list);
    }
}

// MARK: - Header and tab bar

// Each bar gets its own part of the picture inside its background view: above
// the background's color, below the bar's buttons and tabs, which are drawn
// over the background view. UIKit's own views are never reordered.

static NSString* const kBarsKey = @"background_watermark_bars";
static const void* BarWallpaperKey = &BarWallpaperKey;

static BOOL IsUIKitBarBackground(UIView* view) {
    return [NSStringFromClass(view.class) containsString:@"BarBackground"];
}

// X's header draws its color in its own background view; UIKit's bar
// background is the fallback.
static UIView* HeaderBackground(UINavigationBar* bar) {
    UIView* background = BHTSafeObject(bar, @selector(backgroundView));
    if ([background isKindOfClass:UIView.class] && !background.hidden && [background isDescendantOfView:bar]) {
        return background;
    }
    for (UIView* subview in bar.subviews) {
        if (IsUIKitBarBackground(subview)) {
            return subview;
        }
    }
    return nil;
}

static UIView* TabBarBackground(UIViewController* tabBarController) {
    UIView* background = BHTSafeObject(tabBarController, @selector(tabBarBackgroundView));
    return [background isKindOfClass:UIView.class] ? background : nil;
}

static void AttachBarWallpaper(UIView* background) {
    if (!background) {
        return;
    }
    BHTWallpaperView* slice = objc_getAssociatedObject(background, BarWallpaperKey);
    if (!BarsOn) {
        [slice removeFromSuperview];
        return;
    }
    if (!slice) {
        slice = [[BHTWallpaperView alloc] initWithFrame:background.bounds];
        slice.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(background, BarWallpaperKey, slice, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UpdateWallpaperView(slice);
    if (slice.superview != background || background.subviews.lastObject != slice) {
        [background addSubview:slice];
    }
    if (!CGRectEqualToRect(slice.frame, background.bounds)) {
        slice.frame = background.bounds;
    }
    // The bar may have moved (collapsing while scrolling); keep the picture
    // lined up with the window.
    [slice setNeedsLayout];
    [WeakSet(&BarBackgroundsStorage) addObject:background];
}

static void RemoveBarWallpapers(void) {
    for (UIView* background in WeakSet(&BarBackgroundsStorage).allObjects) {
        [objc_getAssociatedObject(background, BarWallpaperKey) removeFromSuperview];
    }
    [WeakSet(&BarBackgroundsStorage) removeAllObjects];
    RestoreClearedViews(&BarClearedViewsStorage);
}

// Views in the header painted in the theme's color over its background, such
// as the Home tab strip's container. Once per screen shown, at most 120 views;
// the backgrounds themselves are left alone (the picture covers them).
static void ClearHeaderThemeBackgrounds(UINavigationBar* bar) {
    UIView* background = HeaderBackground(bar);
    NSMutableArray<UIView*>* queue = [bar.subviews mutableCopy] ?: [NSMutableArray array];
    for (NSUInteger i = 0; i < queue.count && i < 120; i++) {
        UIView* view = queue[i];
        if (view.hidden || view == background || IsUIKitBarBackground(view) ||
            [view isKindOfClass:BHTWallpaperView.class]) {
            continue;
        }
        ClearThemeBackgroundInto(view, &BarClearedViewsStorage);
        if ([view isKindOfClass:UIImageView.class] || [view isKindOfClass:UILabel.class]) {
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
}

// Headers of the tabs, or every header in "every screen" mode.
static BOOL NavigationBarWantsWallpaper(UINavigationBar* bar) {
    if (!BarsOn || !bar) {
        return NO;
    }
    if (FullOn) {
        return YES;
    }
    Class tabNavigationClass = objc_getClass("T1TabNavigationController");
    id delegate = bar.delegate;
    return tabNavigationClass && [delegate isKindOfClass:tabNavigationClass];
}

static void ApplyBarWallpaperForController(UIViewController* controller) {
    if (!BarsOn || !controller.isViewLoaded) {
        return;
    }
    UINavigationBar* bar = controller.navigationController.navigationBar;
    if (NavigationBarWantsWallpaper(bar)) {
        AttachBarWallpaper(HeaderBackground(bar));
        ClearHeaderThemeBackgrounds(bar);
    }
}

%hook TFNNavigationBar

- (void)layoutSubviews {
    %orig;
    if (NavigationBarWantsWallpaper((UINavigationBar*)self)) {
        AttachBarWallpaper(HeaderBackground((UINavigationBar*)self));
    }
}

%end

%hook T1TabBarViewController

- (void)viewDidLayoutSubviews {
    %orig;
    [WeakSet(&SeenTabBarControllersStorage) addObject:(UIViewController*)self];
    if (BarsOn) {
        AttachBarWallpaper(TabBarBackground((UIViewController*)self));
    }
}

%end

// MARK: - Applying

// Gives a list the picture as its backgroundView (kept fixed while it scrolls).
static void ApplyListWallpaper(UIScrollView* list) {
    BHTWallpaperView* wallpaper = objc_getAssociatedObject(list, ListWallpaperKey);
    if (!wallpaper) {
        wallpaper = [[BHTWallpaperView alloc] initWithFrame:list.bounds];
        objc_setAssociatedObject(list, ListWallpaperKey, wallpaper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(list, ListOriginalBackgroundViewKey, ListBackgroundView(list) ?: NSNull.null,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UpdateWallpaperView(wallpaper);
    SetListBackgroundView(list, wallpaper);
    [WeakSet(&WallpaperedListsStorage) addObject:list];
}

static void ApplyWallpaperToController(UIViewController* controller) {
    if (!controller.isViewLoaded) {
        return;
    }
    UIScrollView* list = ListOfController(controller);
    if (!list) {
        return;
    }
    if (!ControllerWantsWallpaper(controller, list)) {
        RemoveListWallpaper(list);
        return;
    }
    ApplyListWallpaper(list);
    PrepareVisibleCells(list);
}

// MARK: - Every screen

static const void* ScreenWallpaperKey = &ScreenWallpaperKey;

// Keyboards and other system windows are left alone.
static BOOL IsAppWindow(UIWindow* window) {
    if (!window) {
        return NO;
    }
    NSString* name = NSStringFromClass(window.class);
    return ![name containsString:@"Keyboard"] && ![name containsString:@"TextEffects"] &&
           ![name containsString:@"Remote"];
}

static NSDictionary* NoLayerAnimations(void) {
    static NSDictionary* actions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        actions = @{
            @"bounds": NSNull.null, @"position": NSNull.null, @"frame": NSNull.null,
            @"contents": NSNull.null, @"opacity": NSNull.null, @"backgroundColor": NSNull.null,
            @"cornerRadius": NSNull.null, @"sublayers": NSNull.null,
            @"onOrderIn": NSNull.null, @"onOrderOut": NSNull.null,
        };
    });
    return actions;
}

// The screen's part of the picture: a clipping layer over the theme color,
// holding the picture laid out against the window.
static CALayer* ScreenWallpaperLayer(UIView* view, BOOL create) {
    CALayer* container = objc_getAssociatedObject(view, ScreenWallpaperKey);
    if (container || !create) {
        return container;
    }
    container = [CALayer layer];
    container.name = @"BHTScreenWallpaper";
    container.masksToBounds = YES;
    container.actions = NoLayerAnimations();
    CALayer* picture = [CALayer layer];
    picture.contentsGravity = kCAGravityResizeAspectFill;
    picture.actions = NoLayerAnimations();
    [container addSublayer:picture];
    objc_setAssociatedObject(view, ScreenWallpaperKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return container;
}

static void RemoveScreenWallpaper(UIView* view) {
    [ScreenWallpaperLayer(view, NO) removeFromSuperlayer];
}

// Runs from layout, so it only moves things that are out of place. A layer is
// added to the screen's own view; UIKit's views are never reordered.
static void PaintScreen(UIView* view) {
    UIWindow* window = view.window;
    BOOL wanted = FullOn && IsAppWindow(window) && ColorIsThemeBackground(view.backgroundColor, view);
    if (!wanted) {
        RemoveScreenWallpaper(view);
        return;
    }

    UIImage* image = BHTWatermark.image;
    CALayer* container = ScreenWallpaperLayer(view, YES);
    CALayer* picture = container.sublayers.firstObject;
    CALayer* layer = view.layer;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (container.superlayer != layer || layer.sublayers.firstObject != container) {
        [layer insertSublayer:container atIndex:0];
    }
    if (!CGRectEqualToRect(container.frame, layer.bounds)) {
        container.frame = layer.bounds;
    }
    container.cornerRadius = layer.cornerRadius;
    container.maskedCorners = layer.maskedCorners;
    CGColorRef theme = [ThemeBackgroundColor() resolvedColorWithTraitCollection:view.traitCollection].CGColor;
    if (!CGColorEqualToColor(container.backgroundColor, theme)) {
        container.backgroundColor = theme;
    }
    id contents = (__bridge id)image.CGImage;
    if (picture.contents != contents) {
        picture.contents = contents;
        picture.contentsScale = image.scale;
    }
    float opacity = BHTWatermark.opacityPercent / 100.0f;
    if (fabsf(picture.opacity - opacity) > 0.001f) {
        picture.opacity = opacity;
    }
    CGRect frame = [view convertRect:window.bounds fromView:window];
    if (!CGRectEqualToRect(picture.frame, frame)) {
        picture.frame = frame;
    }
    [CATransaction commit];

    [WeakSet(&PaintedScreensStorage) addObject:view];
}

// A screen's own view: a list gets the list wallpaper, anything else its part
// of the picture painted in.
static void PaintController(UIViewController* controller) {
    UIView* view = controller.viewIfLoaded;
    if (!view) {
        return;
    }
    if ([view isKindOfClass:UITableView.class] || [view isKindOfClass:UICollectionView.class]) {
        UIScrollView* list = (UIScrollView*)view;
        if (ListHasWallpaper(list)) {
            return;
        }
        if (FullOn && IsAppWindow(list.window) && ColorIsThemeBackground(list.backgroundColor, list)) {
            ApplyListWallpaper(list);
        }
        return;
    }
    if (![view isKindOfClass:UIScrollView.class]) {
        PaintScreen(view);
    }
}

// Paints what's on screen right away when the mode is switched on.
static void PaintControllerTree(UIViewController* controller, NSUInteger depth) {
    if (!controller || depth > 16) {
        return;
    }
    PaintController(controller);
    for (UIViewController* child in controller.childViewControllers) {
        PaintControllerTree(child, depth + 1);
    }
    if (controller.presentedViewController.presentingViewController == controller) {
        PaintControllerTree(controller.presentedViewController, depth + 1);
    }
}

static void PaintAllScreens(void) {
    for (UIWindow* window in UIApplication.sharedApplication.windows) {
        if (IsAppWindow(window)) {
            PaintControllerTree(window.rootViewController, 0);
        }
    }
}

static void RemoveScreenWallpapers(void) {
    for (UIView* view in WeakSet(&PaintedScreensStorage).allObjects) {
        RemoveScreenWallpaper(view);
    }
    [WeakSet(&PaintedScreensStorage) removeAllObjects];
}

%hook UIViewController

- (void)viewDidLayoutSubviews {
    %orig;
    if (FullOn) {
        PaintController(self);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (FullOn) {
        PaintController(self);
    }
}

%end

static void RestoreEverything(void) {
    for (UIScrollView* list in WeakSet(&WallpaperedListsStorage).allObjects) {
        RemoveListWallpaper(list);
    }
    [WeakSet(&WallpaperedListsStorage) removeAllObjects];

    for (UIView* cell in WeakSet(&HostChangedCellsStorage).allObjects) {
        if ([cell respondsToSelector:@selector(setHostProvidesBackground:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(cell, @selector(setHostProvidesBackground:), NO);
        }
    }
    [WeakSet(&HostChangedCellsStorage) removeAllObjects];

    RestoreClearedViews(&ClearedViewsStorage);
    RemoveBarWallpapers();
    RemoveScreenWallpapers();
}

static NSString* const kFullKey = @"background_watermark_full";

static void ReadWallpaperOptions(void) {
    WallpaperOn = BHTWatermark.active;
    FullOn = WallpaperOn && [BHTSettings boolForKey:kFullKey];
    BarsOn = WallpaperOn && (FullOn || [BHTSettings boolForKey:kBarsKey]);
}

static void ApplyWallpaperChange(void) {
    ReadWallpaperOptions();
    if (!WallpaperOn) {
        RestoreEverything();
        return;
    }
    if (!BarsOn) {
        RemoveBarWallpapers();
    }
    if (!FullOn) {
        // Lists outside the tabs only had it for "every screen"; the tab
        // timelines get it back just below.
        RemoveScreenWallpapers();
        for (UIScrollView* list in WeakSet(&WallpaperedListsStorage).allObjects) {
            RemoveListWallpaper(list);
        }
        [WeakSet(&WallpaperedListsStorage) removeAllObjects];
    } else {
        PaintAllScreens();
    }
    for (UIViewController* controller in WeakSet(&SeenControllersStorage).allObjects) {
        ApplyWallpaperToController(controller);
        ApplyBarWallpaperForController(controller);
    }
    for (UIViewController* tabBarController in WeakSet(&SeenTabBarControllersStorage).allObjects) {
        AttachBarWallpaper(TabBarBackground(tabBarController));
    }
}

%hook TFNItemsDataViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [WeakSet(&SeenControllersStorage) addObject:(UIViewController*)self];
    if (WallpaperOn) {
        ApplyWallpaperToController((UIViewController*)self);
        ApplyBarWallpaperForController((UIViewController*)self);
    }
}

- (void)tableView:(UITableView*)tableView
      willDisplayCell:(UITableViewCell*)cell
    forRowAtIndexPath:(NSIndexPath*)indexPath {
    %orig;
    if (WallpaperOn) {
        PrepareCell(cell, tableView);
    }
}

- (void)collectionView:(UICollectionView*)collectionView
       willDisplayCell:(UICollectionViewCell*)cell
    forItemAtIndexPath:(NSIndexPath*)indexPath {
    %orig;
    if (WallpaperOn) {
        PrepareCell(cell, collectionView);
    }
}

%end

%ctor {
    %init;
    ReadWallpaperOptions();
    [NSNotificationCenter.defaultCenter addObserverForName:BHTWatermarkDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* notification) {
                                                    ApplyWallpaperChange();
                                                }];
}

//
//  Watermark.x
//  NeoFreeBird
//
//  Wallpaper: the chosen picture (BHTWatermark) behind the timelines, and
//  optionally the bars and every screen. Every part of it is laid out against
//  the window, so all the parts line up as one picture.
//
//  Timelines: each timeline list gets the picture as its backgroundView
//  (drawn behind the cells, fixed while scrolling), and its cells are made
//  clear. X's cells paint their own background through a private view of
//  TFNTableViewCell; its hostProvidesBackground switch, made for lists that
//  draw the background themselves, turns that off.
//
//  Painting: instead of making a view transparent, the picture is painted in
//  place of its theme background color, as a layer at the bottom of the view
//  (the theme color, the picture over it at the chosen strength). The view
//  stays opaque, so whatever is behind it stays hidden. Painted views that
//  move (inside a scrolling list, a collapsing header) are lined up again as
//  their list or bar lays out. Views that draw their own content are never
//  painted, since a layer would cover it. UIKit's views are never reordered.
//
//  Bars: the header is painted through all its layers; the tab bar gets a
//  part of the picture at the bottom of its background view, below its icons.
//
//  Every screen: each screen is painted down through its views, and every
//  large list in it gets the list treatment.
//
//  Every change is remembered and undone when switched off.
//

#import <QuartzCore/QuartzCore.h>
#import "HookHelpers.h"
#import "Core/BHTWatermark.h"

// MARK: - Alignment

// What the picture is laid out against: the app's main content (the tab bar
// controller's view), which slides as one piece when the sidebar opens, so
// the picture slides with it. Outside it (the sidebar, sheets) the nearest
// view directly under the root view or the window. The picture is the size of
// the window, anchored at that view's top left.
static UIView* AlignmentReference(UIView* view) {
    UIWindow* window = view.window;
    if (!window) {
        return nil;
    }
    static Class tabBarControllerClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tabBarControllerClass = objc_getClass("T1TabBarViewController");
    });
    UIView* rootView = window.rootViewController.viewIfLoaded;
    UIView* fallback = nil;
    for (UIView* ancestor = view; ancestor && ancestor != window; ancestor = ancestor.superview) {
        if (tabBarControllerClass && [ancestor.nextResponder isKindOfClass:tabBarControllerClass]) {
            return ancestor;
        }
        if (!fallback && (ancestor.superview == rootView || ancestor.superview == window)) {
            fallback = ancestor;
        }
    }
    return fallback ?: window;
}

// Where the picture goes in `view`'s coordinates, measured where things are
// on screen right now: mid-animation (a swipe back, a screen being pushed,
// the sidebar sliding) the presentation layers have the moving positions the
// views' own frames don't. `reference` overrides the lookup (the tab bar,
// which isn't inside the main content but moves with it).
static CGRect PictureFrameFor(UIView* view, UIView* reference) {
    UIWindow* window = view.window;
    if (!reference || reference.window != window) {
        reference = AlignmentReference(view);
    }
    if (!window || !reference) {
        return view.bounds;
    }
    CGRect picture = CGRectMake(0, 0, window.bounds.size.width, window.bounds.size.height);
    CALayer* from = reference.layer.presentationLayer ?: reference.layer;
    CALayer* to = view.layer.presentationLayer ?: view.layer;
    return [from convertRect:picture toLayer:to];
}

@interface BHTWallpaperView : UIView
@property (nonatomic, strong) UIImageView* imageView;
@property (nonatomic, weak) UIView* bht_reference;
- (void)bht_align;
@end

static NSHashTable* WallpaperViewsStorage;

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

        if (!WallpaperViewsStorage) {
            WallpaperViewsStorage = [NSHashTable weakObjectsHashTable];
        }
        [WallpaperViewsStorage addObject:self];
    }
    return self;
}

- (void)bht_align {
    if (!self.window) {
        return;
    }
    CGRect frame = PictureFrameFor(self, self.bht_reference);
    CGPoint origin = self.layer.bounds.origin;
    frame = CGRectOffset(frame, -origin.x, -origin.y);
    if (!CGRectEqualToRect(self.imageView.frame, frame)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.imageView.frame = frame;
        [CATransaction commit];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self bht_align];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self setNeedsLayout];
}

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    return nil;
}

@end

static NSString* const kBarsKey = @"background_watermark_bars";
static NSString* const kFullKey = @"background_watermark_full";

static const void* ListWallpaperKey = &ListWallpaperKey;
static const void* ListOriginalBackgroundViewKey = &ListOriginalBackgroundViewKey;
static const void* OriginalBackgroundKey = &OriginalBackgroundKey;
static const void* LayerBackgroundKey = &LayerBackgroundKey;
static const void* ScreenWallpaperKey = &ScreenWallpaperKey;
static const void* ScreenPassKey = &ScreenPassKey;
static const void* HostListKey = &HostListKey;
static const void* ListExtrasPassKey = &ListExtrasPassKey;
static const void* CellPassKey = &CellPassKey;
static const void* ListCheckKey = &ListCheckKey;
static const void* BarPassKey = &BarPassKey;
static const void* TabBarWallpaperKey = &TabBarWallpaperKey;

// Read on hot paths, so kept here instead of asking the settings.
static BOOL WallpaperOn;
static BOOL BarsOn;
static BOOL FullOn;
// Bumped on every change; marks from an older one are stale.
static NSUInteger PaintGeneration = 1;

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
static NSHashTable* TabBarBackgroundsStorage;
static NSHashTable* SeenTabBarControllersStorage;
static NSHashTable* PaintedViewsStorage;

static BOOL IsList(UIView* view) {
    return [view isKindOfClass:UITableView.class] || [view isKindOfClass:UICollectionView.class];
}

// Keyboards and other system windows are left alone.
static BOOL IsAppWindow(UIWindow* window) {
    if (!window) {
        return NO;
    }
    NSString* name = NSStringFromClass(window.class);
    return ![name containsString:@"Keyboard"] && ![name containsString:@"TextEffects"] &&
           ![name containsString:@"Remote"];
}

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

// The theme's background color, at least `minAlpha` opaque. Bars are often a
// little translucent, so they're matched with a lower bar than screens.
static BOOL ColorMatchesTheme(UIColor* color, UIView* view, CGFloat minAlpha) {
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
    return a1 >= minAlpha && fabs(r1 - r2) < 0.03 && fabs(g1 - g2) < 0.03 && fabs(b1 - b2) < 0.03;
}

// Strips, empty states and other chrome often use the theme color slightly
// translucent.
static BOOL ColorIsThemeBackground(UIColor* color, UIView* view) {
    return ColorMatchesTheme(color, view, 0.85);
}

// The view's color, or its layer's when it colors the layer directly.
static UIColor* EffectiveBackgroundColor(UIView* view) {
    UIColor* color = view.backgroundColor;
    if (!color && view.layer.backgroundColor) {
        color = [UIColor colorWithCGColor:view.layer.backgroundColor];
    }
    return color;
}

// MARK: - Making views clear (cells)

static void ClearThemeBackground(UIView* view) {
    if (![view isKindOfClass:UIView.class]) {
        return;
    }
    UIColor* color = view.backgroundColor;
    BOOL layerOnly = NO;
    // Some views color their layer directly, leaving the view's color unset.
    if (!color && view.layer.backgroundColor) {
        color = [UIColor colorWithCGColor:view.layer.backgroundColor];
        layerOnly = YES;
    }
    if (!ColorIsThemeBackground(color, view)) {
        return;
    }
    objc_setAssociatedObject(view, OriginalBackgroundKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, LayerBackgroundKey, layerOnly ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [WeakSet(&ClearedViewsStorage) addObject:view];
    if (layerOnly) {
        view.layer.backgroundColor = UIColor.clearColor.CGColor;
    } else {
        view.backgroundColor = UIColor.clearColor;
    }
}

static void RestoreClearedViews(void) {
    for (UIView* view in WeakSet(&ClearedViewsStorage).allObjects) {
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
    [WeakSet(&ClearedViewsStorage) removeAllObjects];
}

// Views inside a cell painted in the theme's background color: the quoted
// post's card, the box behind the ••• button, an empty-state box. Stops
// early: pictures, text and inner lists are never opened, and at most 150
// views are looked at.
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

// MARK: - Painting

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

// A view that draws its own content (icons, text) would have it covered by a
// layer put under its subviews.
static BOOL ViewDrawsItself(UIView* view) {
    if (view.layer.contents) {
        return YES;
    }
    static IMP baseDrawRect;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        baseDrawRect = [UIView instanceMethodForSelector:@selector(drawRect:)];
    });
    return [view.class instanceMethodForSelector:@selector(drawRect:)] != baseDrawRect;
}

static BOOL CanPaint(UIView* view, CGFloat minAlpha) {
    if ([view isKindOfClass:UIScrollView.class] || [view isKindOfClass:UILabel.class] ||
        [view isKindOfClass:UITextView.class] || [view isKindOfClass:UIVisualEffectView.class] ||
        [view isKindOfClass:BHTWallpaperView.class]) {
        return NO;
    }
    if ([view isKindOfClass:UIImageView.class] && ((UIImageView*)view).image) {
        return NO;
    }
    if (![view isKindOfClass:UIImageView.class] && ViewDrawsItself(view)) {
        return NO;
    }
    return ColorMatchesTheme(EffectiveBackgroundColor(view), view, minAlpha);
}

// The view's part of the picture: a clipping layer in the theme color,
// holding the picture laid out against the window.
static CALayer* PaintLayer(UIView* view, BOOL create) {
    CALayer* container = objc_getAssociatedObject(view, ScreenWallpaperKey);
    if (container || !create) {
        return container;
    }
    container = [CALayer layer];
    container.name = @"BHTWallpaper";
    container.masksToBounds = YES;
    container.actions = NoLayerAnimations();
    CALayer* picture = [CALayer layer];
    picture.contentsGravity = kCAGravityResizeAspectFill;
    picture.actions = NoLayerAnimations();
    [container addSublayer:picture];
    objc_setAssociatedObject(view, ScreenWallpaperKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return container;
}

// Puts a painted view's layer back in place and lines its picture up with the
// window. Only touches what changed.
static void AlignPaintedView(UIView* view) {
    CALayer* container = PaintLayer(view, NO);
    UIWindow* window = view.window;
    CALayer* layer = view.layer;
    if (!container || !window || container.superlayer != layer) {
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (layer.sublayers.firstObject != container) {
        [layer insertSublayer:container atIndex:0];
    }
    if (!CGRectEqualToRect(container.frame, layer.bounds)) {
        container.frame = layer.bounds;
    }
    CALayer* picture = container.sublayers.firstObject;
    // In the container's coordinates, which start at the layer's bounds origin.
    CGRect frame = PictureFrameFor(view, nil);
    frame = CGRectOffset(frame, -container.frame.origin.x, -container.frame.origin.y);
    if (!CGRectEqualToRect(picture.frame, frame)) {
        picture.frame = frame;
    }
    [CATransaction commit];
}

static void PaintView(UIView* view) {
    UIImage* image = BHTWatermark.image;
    if (!view.window || !image) {
        return;
    }
    CALayer* container = PaintLayer(view, YES);
    CALayer* picture = container.sublayers.firstObject;
    CALayer* layer = view.layer;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (container.superlayer != layer) {
        [layer insertSublayer:container atIndex:0];
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
    [CATransaction commit];

    [WeakSet(&PaintedViewsStorage) addObject:view];
    AlignPaintedView(view);
}

// Lines up every painted view and wallpaper view in a window again; called as
// lists scroll and bars and screens lay out. Parts that move with the content
// (the sidebar sliding it) don't change, since they're laid out against it.
static void RealignPaintedViews(UIWindow* window) {
    if (!window) {
        return;
    }
    for (UIView* view in WeakSet(&PaintedViewsStorage).allObjects) {
        if (view.window == window) {
            AlignPaintedView(view);
        }
    }
    for (BHTWallpaperView* wallpaper in WallpaperViewsStorage.allObjects) {
        if (wallpaper.window == window) {
            [wallpaper bht_align];
        }
    }
}

static void RemovePaintedViews(void) {
    for (UIView* view in WeakSet(&PaintedViewsStorage).allObjects) {
        [PaintLayer(view, NO) removeFromSuperlayer];
    }
    [WeakSet(&PaintedViewsStorage) removeAllObjects];
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

// A list taken over in "every screen" mode, in the current generation.
static BOOL IsHostList(UIScrollView* list) {
    NSNumber* generation = objc_getAssociatedObject(list, HostListKey);
    return generation && generation.unsignedIntegerValue == PaintGeneration;
}

// MARK: - Cells

// The cell's own background: cheap enough to check on every layout, since X
// can restyle a visible cell (coming back from an opened post) without
// reusing it.
static void PrepareCellSurface(UIView* cell) {
    SEL hostGetter = @selector(hostProvidesBackground);
    SEL hostSetter = @selector(setHostProvidesBackground:);
    if ([cell respondsToSelector:hostSetter] && !BHTSafeBool(cell, hostGetter)) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(cell, hostSetter, YES);
        [WeakSet(&HostChangedCellsStorage) addObject:cell];
    }

    ClearThemeBackground(cell);
    ClearThemeBackground([cell respondsToSelector:@selector(contentView)] ? [(id)cell contentView] : nil);
    ClearThemeBackground([cell respondsToSelector:@selector(backgroundView)] ? [(id)cell backgroundView] : nil);
    ClearThemeBackground(nfb_objectIvar(cell, "_backgroundView"));
}

static void PrepareCellContents(UIView* cell) {
    PrepareCellSurface(cell);
    UIView* contentView = [cell respondsToSelector:@selector(contentView)] ? [(id)cell contentView] : nil;

    UIView* statusView = BHTSafeObject(cell, @selector(statusView));
    if ([statusView isKindOfClass:UIView.class] && [statusView isDescendantOfView:cell]) {
        ClearThemeBackgroundsInside(statusView);
        for (UIView* view = statusView; view && view != cell; view = view.superview) {
            ClearThemeBackground(view);
        }
    } else if (contentView) {
        ClearThemeBackgroundsInside(contentView);
    }
}

// From the timeline's willDisplayCell: every time, since X restyles cells.
static void PrepareCell(UIView* cell, UIScrollView* list) {
    if (!WallpaperOn || ![cell isKindOfClass:UIView.class] || !(ListHasWallpaper(list) || IsHostList(list))) {
        return;
    }
    PrepareCellContents(cell);
    objc_setAssociatedObject(cell, CellPassKey, @(PaintGeneration), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// From a host list's layout: the surface every time, the inside once per cell
// until it's reused.
static void PrepareCellOnce(UIView* cell) {
    NSNumber* pass = objc_getAssociatedObject(cell, CellPassKey);
    if (pass && pass.unsignedIntegerValue == PaintGeneration) {
        PrepareCellSurface(cell);
        return;
    }
    objc_setAssociatedObject(cell, CellPassKey, @(PaintGeneration), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PrepareCellContents(cell);
}

static void PrepareVisibleCells(UIScrollView* list) {
    if (![list respondsToSelector:@selector(visibleCells)]) {
        return;
    }
    for (UIView* cell in [(id)list visibleCells]) {
        PrepareCell(cell, list);
    }
}

// MARK: - Trees

static void HostList(UIScrollView* list);

// Paints the views under `root` painted in the theme's color. Lists get the
// list treatment instead of being opened; pictures and text are not opened.
static void PaintTree(UIView* root, NSUInteger limit, CGFloat minAlpha) {
    if (!root) {
        return;
    }
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i = 0; i < queue.count && i < limit; i++) {
        UIView* view = queue[i];
        if ([view isKindOfClass:BHTWallpaperView.class]) {
            continue;
        }
        if (IsList(view)) {
            UIScrollView* list = (UIScrollView*)view;
            HostList(list);
            // Small lists (a tab strip's row of tabs) are made clear instead,
            // showing the painted view they sit on.
            if (FullOn && !IsHostList(list)) {
                ClearThemeBackground(list);
                for (UIView* cell in [(id)list visibleCells]) {
                    ClearThemeBackground(cell);
                    ClearThemeBackground([(id)cell contentView]);
                }
            }
            continue;
        }
        if ([view isKindOfClass:UIVisualEffectView.class]) {
            [queue addObject:((UIVisualEffectView*)view).contentView];
            continue;
        }
        if (CanPaint(view, minAlpha)) {
            PaintView(view);
        }
        if ([view isKindOfClass:UIImageView.class] || [view isKindOfClass:UILabel.class] ||
            [view isKindOfClass:UITextView.class]) {
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
}

// Headers, sticky tab strips and empty states that live in a list beside its
// cells.
static NSUInteger ListExtrasCount(UIScrollView* list) {
    NSUInteger count = 0;
    for (UIView* subview in list.subviews) {
        if (![subview isKindOfClass:UITableViewCell.class] && ![subview isKindOfClass:UICollectionViewCell.class]) {
            count++;
        }
    }
    return count;
}

static void PaintListExtras(UIScrollView* list) {
    UIView* background = ListBackgroundView(list);
    for (UIView* subview in [list.subviews copy]) {
        if ([subview isKindOfClass:UITableViewCell.class] || [subview isKindOfClass:UICollectionViewCell.class] ||
            subview == background || [subview isKindOfClass:BHTWallpaperView.class]) {
            continue;
        }
        PaintTree(subview, 80, 0.5);
    }
}

// Runs as a host list lays out, which is every frame while it scrolls: new
// cells are made clear once, the extras painted when they change, and painted
// views lined up again.
static void ServiceHostList(UIScrollView* list, BOOL force) {
    if ([list respondsToSelector:@selector(visibleCells)]) {
        for (UIView* cell in [(id)list visibleCells]) {
            PrepareCellOnce(cell);
        }
    }
    NSUInteger extras = ListExtrasCount(list);
    NSNumber* last = objc_getAssociatedObject(list, ListExtrasPassKey);
    if (force || !last || last.unsignedIntegerValue != extras) {
        objc_setAssociatedObject(list, ListExtrasPassKey, @(extras), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        PaintListExtras(list);
    }
    RealignPaintedViews(list.window);
}

// Large lists in the theme's color (or clear, over a painted screen) in
// "every screen" mode. Small embedded lists such as carousels are left alone.
static void HostList(UIScrollView* list) {
    if (!FullOn || IsHostList(list)) {
        return;
    }
    UIWindow* window = list.window;
    if (!IsAppWindow(window) || list.bounds.size.height < window.bounds.size.height * 0.4) {
        return;
    }
    UIColor* color = list.backgroundColor;
    BOOL clear = !color || CGColorGetAlpha(color.CGColor) < 0.01;
    if (!clear && !ColorMatchesTheme(color, list, 0.5)) {
        return;
    }
    if (!clear) {
        ApplyListWallpaper(list);
    }
    objc_setAssociatedObject(list, HostListKey, @(PaintGeneration), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ServiceHostList(list, YES);
}

// MARK: - Header and tab bar

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

// Every layer of the header painted in the theme's color, its own background
// and UIKit's included; bars may be a little translucent.
static void PaintNavigationBar(UINavigationBar* bar, BOOL force) {
    NSUInteger signature = (PaintGeneration << 16) ^ bar.subviews.count;
    NSNumber* last = objc_getAssociatedObject(bar, BarPassKey);
    if (force || !last || last.unsignedIntegerValue != signature) {
        objc_setAssociatedObject(bar, BarPassKey, @(signature), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        PaintTree(bar, 150, 0.5);
    }
    RealignPaintedViews(bar.window);
}

static UIView* TabBarBackground(UIViewController* tabBarController) {
    UIView* background = BHTSafeObject(tabBarController, @selector(tabBarBackgroundView));
    return [background isKindOfClass:UIView.class] ? background : nil;
}

// A part of the picture at the bottom of the tab bar's background view, below
// anything in it (the icons may be), unless the view draws itself. It's laid
// out against the tab bar controller's view: the tab bar isn't inside the main
// content, and against itself it would show the top of the picture.
static void AttachTabBarWallpaper(UIViewController* tabBarController) {
    UIView* background = TabBarBackground(tabBarController);
    if (!background) {
        return;
    }
    BHTWallpaperView* slice = objc_getAssociatedObject(background, TabBarWallpaperKey);
    if (!BarsOn || ViewDrawsItself(background)) {
        [slice removeFromSuperview];
        return;
    }
    UIView* host = [background isKindOfClass:UIVisualEffectView.class]
                       ? ((UIVisualEffectView*)background).contentView
                       : background;
    if (!slice) {
        slice = [[BHTWallpaperView alloc] initWithFrame:host.bounds];
        slice.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(background, TabBarWallpaperKey, slice, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    slice.bht_reference = tabBarController.viewIfLoaded;
    UpdateWallpaperView(slice);
    if (slice.superview != host || host.subviews.firstObject != slice) {
        [host insertSubview:slice atIndex:0];
    }
    if (!CGRectEqualToRect(slice.frame, host.bounds)) {
        slice.frame = host.bounds;
    }
    [slice setNeedsLayout];
    [WeakSet(&TabBarBackgroundsStorage) addObject:background];
}

static void RemoveTabBarWallpapers(void) {
    for (UIView* background in WeakSet(&TabBarBackgroundsStorage).allObjects) {
        [objc_getAssociatedObject(background, TabBarWallpaperKey) removeFromSuperview];
    }
    [WeakSet(&TabBarBackgroundsStorage) removeAllObjects];
}

%hook TFNNavigationBar

- (void)layoutSubviews {
    %orig;
    if (NavigationBarWantsWallpaper((UINavigationBar*)self)) {
        PaintNavigationBar((UINavigationBar*)self, NO);
    }
}

%end

%hook T1TabBarViewController

- (void)viewDidLayoutSubviews {
    %orig;
    [WeakSet(&SeenTabBarControllersStorage) addObject:(UIViewController*)self];
    if (BarsOn) {
        AttachTabBarWallpaper((UIViewController*)self);
    }
}

%end

// MARK: - Screens

// Timelines in a tab, the default (not "every screen") treatment.
static BOOL ControllerWantsWallpaper(UIViewController* controller, UIScrollView* list) {
    if (!WallpaperOn || !list) {
        return NO;
    }
    Class tabNavigationClass = objc_getClass("T1TabNavigationController");
    UINavigationController* navigationController = controller.navigationController;
    if (!tabNavigationClass || ![navigationController isKindOfClass:tabNavigationClass]) {
        return NO;
    }
    return list.bounds.size.height >= navigationController.view.bounds.size.height * 0.5;
}

static void ApplyWallpaperToController(UIViewController* controller) {
    if (!controller.isViewLoaded) {
        return;
    }
    UIScrollView* list = ListOfController(controller);
    if (!list) {
        return;
    }
    if (ControllerWantsWallpaper(controller, list)) {
        ApplyListWallpaper(list);
        PrepareVisibleCells(list);
    } else if (!FullOn) {
        RemoveListWallpaper(list);
    }
}

static void ApplyBarWallpaperForController(UIViewController* controller) {
    if (!BarsOn || !controller.isViewLoaded) {
        return;
    }
    UINavigationBar* bar = controller.navigationController.navigationBar;
    if (NavigationBarWantsWallpaper(bar)) {
        PaintNavigationBar(bar, YES);
    }
}

// "Every screen": the screen's views painted, once per appearance and again
// when its view gains or loses subviews; otherwise only lined up again.
static void PaintController(UIViewController* controller, BOOL force) {
    UIView* root = controller.viewIfLoaded;
    UIWindow* window = root.window;
    if (!root || !IsAppWindow(window)) {
        return;
    }
    NSUInteger signature = (PaintGeneration << 16) ^ root.subviews.count;
    NSNumber* last = objc_getAssociatedObject(root, ScreenPassKey);
    if (force || !last || last.unsignedIntegerValue != signature) {
        objc_setAssociatedObject(root, ScreenPassKey, @(signature), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        PaintTree(root, 200, 0.5);
    }
    RealignPaintedViews(window);
}

// Paints what's on screen right away when the mode is switched on.
static void PaintControllerTree(UIViewController* controller, NSUInteger depth) {
    if (!controller || depth > 16) {
        return;
    }
    PaintController(controller, YES);
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

%hook UIViewController

- (void)viewDidLayoutSubviews {
    %orig;
    if (FullOn) {
        PaintController(self, NO);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (FullOn) {
        PaintController(self, YES);
    }
}

%end

// A list not taken over yet is looked at again whenever its height changes:
// one seen before it was laid out (zero-sized, as search results can be on
// their first pass) gets its turn once it has a size.
static void ConsiderList(UIScrollView* list) {
    NSUInteger signature = (PaintGeneration << 16) ^ (NSUInteger)list.bounds.size.height;
    NSNumber* last = objc_getAssociatedObject(list, ListCheckKey);
    if (last && last.unsignedIntegerValue == signature) {
        return;
    }
    objc_setAssociatedObject(list, ListCheckKey, @(signature), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    HostList(list);
}

static void ListDidLayout(UIScrollView* list) {
    if (IsHostList(list)) {
        ServiceHostList(list, NO);
    } else {
        ConsiderList(list);
    }
}

%hook UITableView

- (void)layoutSubviews {
    %orig;
    if (FullOn) {
        ListDidLayout(self);
    }
}

%end

%hook UICollectionView

- (void)layoutSubviews {
    %orig;
    if (FullOn) {
        ListDidLayout(self);
    }
}

%end

// A reused cell is restyled by X, so it's made clear again.
%hook UITableViewCell

- (void)prepareForReuse {
    %orig;
    if (FullOn) {
        objc_setAssociatedObject(self, CellPassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%end

%hook UICollectionViewCell

- (void)prepareForReuse {
    %orig;
    if (FullOn) {
        objc_setAssociatedObject(self, CellPassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%end

// MARK: - Switching

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

    RestoreClearedViews();
    RemovePaintedViews();
    RemoveTabBarWallpapers();
}

// MARK: - Every frame

// Keeps every part of the picture lined up while things move without laying
// out: a swipe back, a screen being pushed, the sidebar sliding, a tab
// switch. Runs only with the bars or "every screen" option on, measures from
// where things are on screen, and only touches parts that moved.
@interface BHTWallpaperTicker : NSObject
@end

static CADisplayLink* WallpaperDisplayLink;

static void RealignEverything(void) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIView* view in WeakSet(&PaintedViewsStorage).allObjects) {
        if (view.window) {
            AlignPaintedView(view);
        }
    }
    for (BHTWallpaperView* wallpaper in WallpaperViewsStorage.allObjects) {
        if (wallpaper.window) {
            [wallpaper bht_align];
        }
    }
    // Coming back to a screen, X can drop a list's background view; the
    // picture goes back in. One X replaced with its own view is left alone.
    for (UIScrollView* list in WeakSet(&WallpaperedListsStorage).allObjects) {
        BHTWallpaperView* wallpaper = objc_getAssociatedObject(list, ListWallpaperKey);
        if (list.window && wallpaper && !ListBackgroundView(list)) {
            SetListBackgroundView(list, wallpaper);
        }
    }
    [CATransaction commit];
}

@implementation BHTWallpaperTicker

- (void)tick:(CADisplayLink*)link {
    RealignEverything();
}

@end

static void UpdateTicker(void) {
    BOOL wanted = WallpaperOn && (FullOn || BarsOn);
    if (wanted && !WallpaperDisplayLink) {
        static BHTWallpaperTicker* ticker;
        if (!ticker) {
            ticker = [BHTWallpaperTicker new];
        }
        WallpaperDisplayLink = [CADisplayLink displayLinkWithTarget:ticker selector:@selector(tick:)];
        [WallpaperDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else if (!wanted && WallpaperDisplayLink) {
        [WallpaperDisplayLink invalidate];
        WallpaperDisplayLink = nil;
    }
}

static void ReadWallpaperOptions(void) {
    WallpaperOn = BHTWatermark.active;
    FullOn = WallpaperOn && [BHTSettings boolForKey:kFullKey];
    BarsOn = WallpaperOn && (FullOn || [BHTSettings boolForKey:kBarsKey]);
}

static void ApplyWallpaperChange(void) {
    ReadWallpaperOptions();
    UpdateTicker();
    PaintGeneration++;
    if (!WallpaperOn) {
        RestoreEverything();
        return;
    }

    // Start over from the timelines in tabs, then add what the options ask for.
    RemovePaintedViews();
    RemoveTabBarWallpapers();
    if (!FullOn) {
        for (UIScrollView* list in WeakSet(&WallpaperedListsStorage).allObjects) {
            RemoveListWallpaper(list);
        }
        [WeakSet(&WallpaperedListsStorage) removeAllObjects];
        // Colors cleared for "every screen"; the tab timelines' cells are
        // made clear again just below and as they show.
        RestoreClearedViews();
    }
    for (UIViewController* controller in WeakSet(&SeenControllersStorage).allObjects) {
        ApplyWallpaperToController(controller);
        ApplyBarWallpaperForController(controller);
    }
    for (UIViewController* tabBarController in WeakSet(&SeenTabBarControllersStorage).allObjects) {
        AttachTabBarWallpaper(tabBarController);
    }
    if (FullOn) {
        PaintAllScreens();
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
    dispatch_async(dispatch_get_main_queue(), ^{
        UpdateTicker();
    });
    [NSNotificationCenter.defaultCenter addObserverForName:BHTWatermarkDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* notification) {
                                                    ApplyWallpaperChange();
                                                }];
}

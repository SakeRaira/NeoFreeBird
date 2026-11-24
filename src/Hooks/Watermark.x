//
//  Watermark.x
//  NeoFreeBird
//
//  Wallpaper: the chosen picture (BHTWatermark).
//
//  Timelines (the base option): each timeline list in a tab gets the picture
//  as its backgroundView (drawn behind the cells, fixed while scrolling), and
//  its cells are made clear. X's cells paint their own background through a
//  private view of TFNTableViewCell; its hostProvidesBackground switch, made
//  for lists that draw the background themselves, turns that off.
//
//  "Every screen": one picture at the back, and everything above it painted
//  in the theme's background color made clear, so the picture shows through
//  and nothing has to follow anything: scrolling, paging between tabs and
//  screens moving all happen over a picture that doesn't move.
//   - The backs: the main content (the tab bar controller's view, which the
//     sidebar slides as one piece, so the picture goes with it), the sidebar,
//     and each sheet or modal (it carries its own as it slides up).
//   - Only what content passes under can't be clear: the header, the tab
//     strips (Following, All/Mentions, Top/Latest...) and the tab bar. They
//     get their own part of the picture instead, laid out against the same
//     back so it lines up. They hardly move; one inside a scrolling list (a
//     profile's sticky strip) is lined up as the list scrolls.
//   - Opening or closing a screen slides the new one over the old; with both
//     clear the old one would show through, so it fades out alongside the
//     slide (UIKit runs the fade with the slide, swipes back included).
//
//  "Header and tab bar": just those parts, over the normal app.
//
//  Theme colors are cleared on views' backgrounds only (X also uses the color
//  for text and outlines). Every change is remembered and undone when
//  switched off. UIKit's views are never reordered; parts are layers.
//

#import <QuartzCore/QuartzCore.h>
#import "HookHelpers.h"
#import "Core/BHTWatermark.h"

static NSString* const kBarsKey = @"background_watermark_bars";
static NSString* const kFullKey = @"background_watermark_full";

static const void* ListWallpaperKey = &ListWallpaperKey;
static const void* ListOriginalBackgroundViewKey = &ListOriginalBackgroundViewKey;
static const void* OriginalBackgroundKey = &OriginalBackgroundKey;
static const void* LayerBackgroundKey = &LayerBackgroundKey;
static const void* PieceKey = &PieceKey;
static const void* ScreenPassKey = &ScreenPassKey;
static const void* HostListKey = &HostListKey;
static const void* ListExtrasPassKey = &ListExtrasPassKey;
static const void* CellPassKey = &CellPassKey;
static const void* ListCheckKey = &ListCheckKey;
static const void* BarPassKey = &BarPassKey;
static const void* TabBarWallpaperKey = &TabBarWallpaperKey;
static const void* ScrollHoldsPieceKey = &ScrollHoldsPieceKey;

// Read on hot paths, so kept here instead of asking the settings.
static BOOL WallpaperOn;
static BOOL BarsOn;
static BOOL FullOn;
// Bumped on every change; marks from an older one are stale.
static NSUInteger Generation = 1;

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
static NSHashTable* PiecesStorage;
static NSHashTable* WallpaperViewsStorage;

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

// The theme's background color, at least `minAlpha` opaque.
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

// MARK: - Making views clear

// YES when the view was in the theme color and is now clear.
static BOOL ClearThemeBackground(UIView* view) {
    if (![view isKindOfClass:UIView.class]) {
        return NO;
    }
    UIColor* color = view.backgroundColor;
    BOOL layerOnly = NO;
    if (!color && view.layer.backgroundColor) {
        color = [UIColor colorWithCGColor:view.layer.backgroundColor];
        layerOnly = YES;
    }
    if (!ColorIsThemeBackground(color, view)) {
        return NO;
    }
    objc_setAssociatedObject(view, OriginalBackgroundKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, LayerBackgroundKey, layerOnly ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [WeakSet(&ClearedViewsStorage) addObject:view];
    if (layerOnly) {
        view.layer.backgroundColor = UIColor.clearColor.CGColor;
    } else {
        view.backgroundColor = UIColor.clearColor;
    }
    return YES;
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
        ClearThemeBackground(view);
        if ([view isKindOfClass:UIImageView.class] || [view isKindOfClass:UILabel.class] ||
            [view isKindOfClass:UIScrollView.class] || [view isKindOfClass:UITextView.class]) {
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
}

// MARK: - Alignment

// What the picture is laid out against, the size of the window and anchored
// at its top left: a sheet or modal's own view (it slides as one piece), the
// main content (the tab bar controller's view, which the sidebar slides as
// one piece), otherwise the nearest view directly under the root view or the
// window (the sidebar).
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
        UIResponder* responder = ancestor.nextResponder;
        if ([responder isKindOfClass:UIViewController.class]) {
            UIViewController* controller = (UIViewController*)responder;
            if (controller.viewIfLoaded == ancestor) {
                if (tabBarControllerClass && [controller isKindOfClass:tabBarControllerClass]) {
                    return ancestor;
                }
                if (controller.presentingViewController && !controller.parentViewController) {
                    return ancestor;
                }
            }
        }
        if (!fallback && (ancestor.superview == rootView || ancestor.superview == window)) {
            fallback = ancestor;
        }
    }
    return fallback ?: window;
}

// Where the picture goes in `view`'s coordinates. `reference` overrides the
// lookup (the tab bar, which isn't inside the main content but moves with it).
static CGRect PictureFrameFor(UIView* view, UIView* reference) {
    UIWindow* window = view.window;
    if (!reference || reference.window != window) {
        reference = AlignmentReference(view);
    }
    if (!window || !reference) {
        return view.bounds;
    }
    CGRect picture = CGRectMake(0, 0, window.bounds.size.width, window.bounds.size.height);
    return [view convertRect:picture fromView:reference];
}

// MARK: - Wallpaper views (timeline lists, the tab bar)

@interface BHTWallpaperView : UIView
@property (nonatomic, strong) UIImageView* imageView;
@property (nonatomic, weak) UIView* bht_reference;
- (void)bht_align;
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
        [WeakSet(&WallpaperViewsStorage) addObject:self];
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

// MARK: - Picture parts (layers)

static void MarkScrollAncestors(UIView* view);

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

// A view's part of the picture: a clipping layer in the theme color at the
// bottom of the view, holding the picture laid out against the view's back.
static CALayer* PieceLayer(UIView* view, BOOL create) {
    CALayer* container = objc_getAssociatedObject(view, PieceKey);
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
    objc_setAssociatedObject(view, PieceKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return container;
}

// Puts a piece back at the bottom and lines its picture up. Only touches what
// changed.
static void AlignPiece(UIView* view) {
    CALayer* container = PieceLayer(view, NO);
    CALayer* layer = view.layer;
    if (!container || !view.window || container.superlayer != layer) {
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
    container.cornerRadius = layer.cornerRadius;
    container.maskedCorners = layer.maskedCorners;
    CALayer* picture = container.sublayers.firstObject;
    // In the container's coordinates, which start at the layer's bounds origin.
    CGRect frame = PictureFrameFor(view, nil);
    frame = CGRectOffset(frame, -container.frame.origin.x, -container.frame.origin.y);
    if (!CGRectEqualToRect(picture.frame, frame)) {
        picture.frame = frame;
    }
    [CATransaction commit];
}

static void PaintPiece(UIView* view) {
    UIImage* image = BHTWatermark.image;
    if (!view.window || !image) {
        return;
    }
    CALayer* container = PieceLayer(view, YES);
    CALayer* picture = container.sublayers.firstObject;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (container.superlayer != view.layer) {
        [view.layer insertSublayer:container atIndex:0];
    }
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

    [WeakSet(&PiecesStorage) addObject:view];
    MarkScrollAncestors(view);
    AlignPiece(view);
}

// Lines every part in a window up again; parts only move with layout (a
// collapsing header, a sticky strip in a scrolling list).
static void RealignPieces(UIWindow* window) {
    if (!window) {
        return;
    }
    for (UIView* view in WeakSet(&PiecesStorage).allObjects) {
        if (view.window == window) {
            AlignPiece(view);
        }
    }
    for (BHTWallpaperView* wallpaper in WeakSet(&WallpaperViewsStorage).allObjects) {
        if (wallpaper.window == window) {
            [wallpaper bht_align];
        }
    }
}

static void RemovePieces(void) {
    for (UIView* view in WeakSet(&PiecesStorage).allObjects) {
        [PieceLayer(view, NO) removeFromSuperlayer];
    }
    [WeakSet(&PiecesStorage) removeAllObjects];
}

// A part inside a scroll view is lined up again as it scrolls, in the same
// pass, so it keeps still without lag.
static void MarkScrollAncestors(UIView* view) {
    for (UIView* ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UIScrollView.class] && !objc_getAssociatedObject(ancestor, ScrollHoldsPieceKey)) {
            objc_setAssociatedObject(ancestor, ScrollHoldsPieceKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void ScrollViewMoved(UIScrollView* scrollView) {
    if (BarsOn && objc_getAssociatedObject(scrollView, ScrollHoldsPieceKey)) {
        RealignPieces(scrollView.window);
    }
}

%hook UIScrollView

- (void)setContentOffset:(CGPoint)offset {
    %orig;
    ScrollViewMoved(self);
}

- (void)layoutSubviews {
    %orig;
    ScrollViewMoved(self);
}

%end

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

// The timeline option: the picture as the list's backgroundView.
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

// A list made clear in "every screen" mode, in the current generation.
static BOOL IsHostList(UIScrollView* list) {
    NSNumber* generation = objc_getAssociatedObject(list, HostListKey);
    return generation && generation.unsignedIntegerValue == Generation;
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
    objc_setAssociatedObject(cell, CellPassKey, @(Generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// From a clear list's layout: the surface every time, the inside once per
// cell until it's reused.
static void PrepareCellOnce(UIView* cell) {
    NSNumber* pass = objc_getAssociatedObject(cell, CellPassKey);
    if (pass && pass.unsignedIntegerValue == Generation) {
        PrepareCellSurface(cell);
        return;
    }
    objc_setAssociatedObject(cell, CellPassKey, @(Generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// MARK: - Every screen: clear views over a back

// The back a view shows through to: a part of the picture painted at the
// bottom of its alignment reference.
static void EnsureBack(UIView* view) {
    UIView* back = AlignmentReference(view);
    if (back && back != view.window && ![back isKindOfClass:UIScrollView.class]) {
        PaintPiece(back);
    }
}

static Class TabStripClass(void) {
    static Class stripClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stripClass = objc_getClass("_TtC10TFNUISwift25LegacySegmentedTabBarView");
    });
    return stripClass;
}

// The tab bar's own views keep their look; it gets its part separately.
static NSSet* TabBarViews(void) {
    NSMutableSet* views = [NSMutableSet set];
    for (UIViewController* controller in WeakSet(&SeenTabBarControllersStorage).allObjects) {
        UIView* background = BHTSafeObject(controller, @selector(tabBarBackgroundView));
        if ([background isKindOfClass:UIView.class] && background.superview) {
            [views addObject:background.superview];
        }
    }
    return views;
}

static BOOL MakeListClear(UIScrollView* list);

// Makes the theme-colored views under `root` clear, except the tab strips,
// which content passes under: those (and their short theme-colored
// containers) get a part of the picture. Headers are left to the header code.
// YES when anything was made clear.
static BOOL ClearSubtree(UIView* root, NSUInteger limit) {
    UIWindow* window = root.window;
    if (!window) {
        return NO;
    }
    Class stripClass = TabStripClass();
    NSSet* tabBarViews = TabBarViews();

    NSMutableArray<UIView*>* visited = [NSMutableArray array];
    NSMutableArray<UIView*>* strips = [NSMutableArray array];
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i = 0; i < queue.count && i < limit; i++) {
        UIView* view = queue[i];
        if ([view isKindOfClass:BHTWallpaperView.class] || [view isKindOfClass:UINavigationBar.class] ||
            [tabBarViews containsObject:view]) {
            continue;
        }
        [visited addObject:view];
        if (stripClass && [view isKindOfClass:stripClass]) {
            [strips addObject:view];
        }
        if (IsList(view) || [view isKindOfClass:UIImageView.class] || [view isKindOfClass:UILabel.class] ||
            [view isKindOfClass:UITextView.class]) {
            continue;
        }
        if ([view isKindOfClass:UIVisualEffectView.class]) {
            [queue addObject:((UIVisualEffectView*)view).contentView];
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }

    // A strip and its short containers.
    NSHashTable* pieces = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    CGFloat shortHeight = window.bounds.size.height * 0.25;
    for (UIView* strip in strips) {
        for (UIView* view = strip; view && view.bounds.size.height <= shortHeight; view = view.superview) {
            [pieces addObject:view];
            if (view == root) {
                break;
            }
        }
    }

    BOOL cleared = NO;
    for (UIView* view in visited) {
        if ([pieces containsObject:view]) {
            if (CanPaint(view, 0.5)) {
                PaintPiece(view);
            }
            continue;
        }
        if (IsList(view)) {
            cleared = MakeListClear((UIScrollView*)view) || cleared;
            continue;
        }
        cleared = ClearThemeBackground(view) || cleared;
    }
    return cleared;
}

// Headers, sticky strips and empty states living in a list beside its cells.
static NSUInteger ListExtrasCount(UIScrollView* list) {
    NSUInteger count = 0;
    for (UIView* subview in list.subviews) {
        if (![subview isKindOfClass:UITableViewCell.class] && ![subview isKindOfClass:UICollectionViewCell.class]) {
            count++;
        }
    }
    return count;
}

static void ClearListExtras(UIScrollView* list) {
    BOOL cleared = NO;
    for (UIView* subview in [list.subviews copy]) {
        if ([subview isKindOfClass:UITableViewCell.class] || [subview isKindOfClass:UICollectionViewCell.class] ||
            [subview isKindOfClass:BHTWallpaperView.class]) {
            continue;
        }
        cleared = ClearSubtree(subview, 80) || cleared;
    }
    if (cleared) {
        EnsureBack(list);
    }
}

// Runs as a clear list lays out (every frame while it scrolls): new cells are
// made clear, the extras when they change.
static void ServiceClearList(UIScrollView* list, BOOL force) {
    if ([list respondsToSelector:@selector(visibleCells)]) {
        for (UIView* cell in [(id)list visibleCells]) {
            PrepareCellOnce(cell);
        }
    }
    NSUInteger extras = ListExtrasCount(list);
    NSNumber* last = objc_getAssociatedObject(list, ListExtrasPassKey);
    if (force || !last || last.unsignedIntegerValue != extras) {
        objc_setAssociatedObject(list, ListExtrasPassKey, @(extras), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ClearListExtras(list);
    }
}

// A list in the theme color (or already clear) is made clear with its cells.
// YES when its own color was cleared.
static BOOL MakeListClear(UIScrollView* list) {
    if (!FullOn || !IsAppWindow(list.window)) {
        return NO;
    }
    if (IsHostList(list)) {
        return NO;
    }
    UIColor* color = list.backgroundColor;
    BOOL alreadyClear = !color || CGColorGetAlpha(color.CGColor) < 0.01;
    BOOL cleared = NO;
    if (!alreadyClear) {
        if (!ColorMatchesTheme(color, list, 0.5)) {
            return NO;
        }
        cleared = ClearThemeBackground(list);
        if (!cleared) {
            // Slightly translucent theme colors under the clearing bar.
            objc_setAssociatedObject(list, OriginalBackgroundKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [WeakSet(&ClearedViewsStorage) addObject:list];
            list.backgroundColor = UIColor.clearColor;
            cleared = YES;
        }
    }
    ClearThemeBackground(ListBackgroundView(list));
    objc_setAssociatedObject(list, HostListKey, @(Generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (cleared) {
        EnsureBack(list);
    }
    ServiceClearList(list, YES);
    return cleared;
}

// A list not made clear yet is looked at again whenever its height changes:
// one seen before it was laid out gets its turn once it has a size.
static void ConsiderList(UIScrollView* list) {
    NSUInteger signature = (Generation << 16) ^ (NSUInteger)list.bounds.size.height;
    NSNumber* last = objc_getAssociatedObject(list, ListCheckKey);
    if (last && last.unsignedIntegerValue == signature) {
        return;
    }
    objc_setAssociatedObject(list, ListCheckKey, @(signature), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (list.bounds.size.height > 0) {
        MakeListClear(list);
    }
}

// A screen: once per appearance and again when its view gains or loses
// subviews; otherwise only its parts are lined up again.
static void ClearController(UIViewController* controller, BOOL force) {
    UIView* root = controller.viewIfLoaded;
    UIWindow* window = root.window;
    if (!root || !IsAppWindow(window)) {
        return;
    }
    NSUInteger signature = (Generation << 16) ^ root.subviews.count;
    NSNumber* last = objc_getAssociatedObject(root, ScreenPassKey);
    if (force || !last || last.unsignedIntegerValue != signature) {
        objc_setAssociatedObject(root, ScreenPassKey, @(signature), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (ClearSubtree(root, 300)) {
            EnsureBack(root);
        }
    }
    RealignPieces(window);
}

static void ClearControllerTree(UIViewController* controller, NSUInteger depth) {
    if (!controller || depth > 16) {
        return;
    }
    ClearController(controller, YES);
    for (UIViewController* child in controller.childViewControllers) {
        ClearControllerTree(child, depth + 1);
    }
    if (controller.presentedViewController.presentingViewController == controller) {
        ClearControllerTree(controller.presentedViewController, depth + 1);
    }
}

static void ClearAllScreens(void) {
    for (UIWindow* window in UIApplication.sharedApplication.windows) {
        if (IsAppWindow(window)) {
            ClearControllerTree(window.rootViewController, 0);
        }
    }
}

%hook UIViewController

- (void)viewDidLayoutSubviews {
    %orig;
    if (FullOn) {
        ClearController(self, NO);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (FullOn) {
        ClearController(self, YES);
    }
}

%end

%hook UITableView

- (void)layoutSubviews {
    %orig;
    if (FullOn) {
        if (IsHostList(self)) {
            ServiceClearList(self, NO);
        } else {
            ConsiderList(self);
        }
    }
}

%end

%hook UICollectionView

- (void)layoutSubviews {
    %orig;
    if (FullOn) {
        if (IsHostList(self)) {
            ServiceClearList(self, NO);
        } else {
            ConsiderList(self);
        }
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

// MARK: - Opening and closing screens

// A new screen slides in over the old one (or the old one slides off over
// the one below). With clear screens the one underneath would show through,
// so it fades out alongside the slide; UIKit runs the fade with the slide,
// interactive swipes back (and cancelled ones) included.
static void FadeOutgoingScreen(UINavigationController* navigationController) {
    if (!FullOn) {
        return;
    }
    id<UIViewControllerTransitionCoordinator> coordinator = navigationController.transitionCoordinator;
    if (!coordinator || !coordinator.isAnimated) {
        return;
    }
    UIViewController* from = [coordinator viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIView* fromView = from.viewIfLoaded;
    if (!fromView || !IsAppWindow(fromView.window)) {
        return;
    }
    CGFloat originalAlpha = fromView.alpha;
    [coordinator
        animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            fromView.alpha = 0;
        }
        completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            fromView.alpha = originalAlpha;
        }];
}

%hook UINavigationController

- (void)pushViewController:(UIViewController*)viewController animated:(BOOL)animated {
    %orig;
    if (animated) {
        FadeOutgoingScreen(self);
    }
}

- (UIViewController*)popViewControllerAnimated:(BOOL)animated {
    UIViewController* popped = %orig;
    if (animated) {
        FadeOutgoingScreen(self);
    }
    return popped;
}

- (NSArray*)popToViewController:(UIViewController*)viewController animated:(BOOL)animated {
    NSArray* popped = %orig;
    if (animated) {
        FadeOutgoingScreen(self);
    }
    return popped;
}

- (NSArray*)popToRootViewControllerAnimated:(BOOL)animated {
    NSArray* popped = %orig;
    if (animated) {
        FadeOutgoingScreen(self);
    }
    return popped;
}

%end

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

// Every layer of the header painted in the theme color gets its part (content
// passes under it), UIKit's bar background included; bars may be a little
// translucent. Lists in it (a tab strip's row of tabs) are made clear.
static void PaintNavigationBar(UINavigationBar* bar, BOOL force) {
    NSUInteger signature = (Generation << 16) ^ bar.subviews.count;
    NSNumber* last = objc_getAssociatedObject(bar, BarPassKey);
    if (force || !last || last.unsignedIntegerValue != signature) {
        objc_setAssociatedObject(bar, BarPassKey, @(signature), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:bar];
        for (NSUInteger i = 0; i < queue.count && i < 150; i++) {
            UIView* view = queue[i];
            if ([view isKindOfClass:BHTWallpaperView.class]) {
                continue;
            }
            if (IsList(view)) {
                ClearThemeBackground(view);
                continue;
            }
            if ([view isKindOfClass:UIVisualEffectView.class]) {
                [queue addObject:((UIVisualEffectView*)view).contentView];
                continue;
            }
            if (CanPaint(view, 0.5)) {
                PaintPiece(view);
            }
            if ([view isKindOfClass:UIImageView.class] || [view isKindOfClass:UILabel.class] ||
                [view isKindOfClass:UITextView.class]) {
                continue;
            }
            [queue addObjectsFromArray:view.subviews];
        }
    }
    RealignPieces(bar.window);
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
    // The main content's back, kept at the bottom.
    if (FullOn && PieceLayer(((UIViewController*)self).view, NO)) {
        AlignPiece(((UIViewController*)self).view);
    }
}

%end

// MARK: - Timelines

// Timelines in a tab, the base option.
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
    if (FullOn) {
        // The back shows through instead.
        RemoveListWallpaper(list);
        MakeListClear(list);
        PrepareVisibleCells(list);
    } else if (ControllerWantsWallpaper(controller, list)) {
        ApplyListWallpaper(list);
        PrepareVisibleCells(list);
    } else {
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
    RemovePieces();
    RemoveTabBarWallpapers();
}

static void ReadWallpaperOptions(void) {
    WallpaperOn = BHTWatermark.active;
    FullOn = WallpaperOn && [BHTSettings boolForKey:kFullKey];
    BarsOn = WallpaperOn && (FullOn || [BHTSettings boolForKey:kBarsKey]);
}

static void ApplyWallpaperChange(void) {
    ReadWallpaperOptions();
    Generation++;
    // Start over, then add what the options ask for.
    RestoreEverything();
    if (!WallpaperOn) {
        return;
    }
    for (UIViewController* controller in WeakSet(&SeenControllersStorage).allObjects) {
        ApplyWallpaperToController(controller);
        ApplyBarWallpaperForController(controller);
    }
    for (UIViewController* tabBarController in WeakSet(&SeenTabBarControllersStorage).allObjects) {
        AttachTabBarWallpaper(tabBarController);
    }
    if (FullOn) {
        ClearAllScreens();
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

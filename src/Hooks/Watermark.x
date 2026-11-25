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
//   - The backs: each sheet or modal (it carries its own as it slides up),
//     otherwise the view under the root, behind the sidebar, the main
//     content and the tab bar.
//   - The sidebar waits behind the main content; with the content clear it
//     would show through, so it's faded out and fades in with how far it's
//     open (and back out as it closes).
//   - Only what content passes under can't be clear: the header, the tab
//     strips (Following, All/Mentions, Top/Latest...) and the tab bar. They
//     get their own part of the picture instead, laid out against the same
//     back so it lines up. They hardly move; one inside a scrolling list (a
//     profile's sticky strip) is lined up as the list scrolls.
//   - Opening or closing a screen slides the new one over the old; with both
//     clear they'd show at once. In X's own navigation the overlay its
//     animator dims the screen underneath with becomes the wallpaper, so that
//     screen is covered as the new one slides in and uncovered as a swipe
//     back goes on, without touching the screens. Elsewhere the screens
//     cross-fade alongside UIKit's slide, without its dark veil.
//   - X paints its theme colors through setters it calls again whenever the
//     look changes. A view made clear stays clear in that same call; any
//     other view given the theme's background color is handled right before
//     the frame is drawn, and X reloading its colors gets a full pass then
//     too, so nothing shows in the theme color first.
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
static const void* StripPassKey = &StripPassKey;
static const void* FadeAlphaKey = &FadeAlphaKey;
static const void* FadeTransitionKey = &FadeTransitionKey;
static const void* FadeNavigationKey = &FadeNavigationKey;
static const void* PlateKey = &PlateKey;
static const void* OverlayOriginalColorKey = &OverlayOriginalColorKey;
static const void* TintAlphaKey = &TintAlphaKey;
static const void* OverlayBackgroundKey = &OverlayBackgroundKey;
static const void* AddedOverlaysKey = &AddedOverlaysKey;
static const void* AddedFadesKey = &AddedFadesKey;
static const void* TransitionWindowKey = &TransitionWindowKey;
static const void* ScreenNormalAlphaKey = &ScreenNormalAlphaKey;
static const void* KeepClearKey = &KeepClearKey;

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

// X's own blurs (XDSBlur: the profile banner's as it scrolls, and others)
// blur what's behind them through a filter and tint it with their own
// views. Changing those views breaks the blur into blocks, so nothing inside
// one is ever touched. (UIKit's effect views are handled through their
// content view instead.)
static BOOL IsCustomBlur(UIView* view) {
    return ![view isKindOfClass:UIVisualEffectView.class] && [NSStringFromClass(view.class) containsString:@"Blur"];
}

static BOOL IsInsideCustomBlur(UIView* view) {
    for (UIView* ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (IsCustomBlur(ancestor)) {
            return YES;
        }
        if ([ancestor isKindOfClass:UIVisualEffectView.class] && view != ancestor &&
            ![view isDescendantOfView:((UIVisualEffectView*)ancestor).contentView]) {
            // An effect view's own layers (its tint), not its content.
            return YES;
        }
    }
    return NO;
}

// MARK: - Theme background

// X's palette (TAEColorSettings → the current TAEColorPalette) hands out its
// colors as objects that follow the theme, and TFNDynamicColorManager records
// every setter they're passed to (setBackgroundColor: and the like). When the
// look changes (a new theme, light/dark, iOS flipping the look for its
// snapshots while the app is in the background), it calls those setters again
// with the new colors. So X paints the theme color back on views at those
// moments, and everything here goes through setBackgroundColor:.
static UIColor* ThemeColorCache;
static CFTimeInterval ThemeColorReadAt;

static UIColor* ThemeBackgroundColor(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (!ThemeColorCache || now - ThemeColorReadAt > 1.0) {
        ThemeColorCache = [Palette currentBackgroundColor];
        ThemeColorReadAt = now;
    }
    return ThemeColorCache;
}

// The palette changed: read it again on the next use.
static void ForgetThemeColor(void) {
    ThemeColorCache = nil;
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

// How far a color is from the theme's background (the largest difference in
// red, green or blue), with its alpha. 1 when it can't be compared.
static CGFloat ThemeDistance(UIColor* color, UIView* view, CGFloat* alphaOut) {
    *alphaOut = 0;
    if (!color) {
        return 1;
    }
    UITraitCollection* traits = view.traitCollection;
    CGFloat r1, g1, b1, a1, r2, g2, b2, a2;
    if (![[color resolvedColorWithTraitCollection:traits] getRed:&r1 green:&g1 blue:&b1 alpha:&a1]) {
        return 1;
    }
    *alphaOut = a1;
    UIColor* theme = ThemeBackgroundColor();
    if (color == theme) {
        return 0;
    }
    if (![[theme resolvedColorWithTraitCollection:traits] getRed:&r2 green:&g2 blue:&b2 alpha:&a2]) {
        return 1;
    }
    return MAX(fabs(r1 - r2), MAX(fabs(g1 - g2), fabs(b1 - b2)));
}

static id CurrentPalette(void) {
    id settings = BHTSafeObject(objc_getClass("TAEColorSettings"), @selector(sharedSettings));
    id info = BHTSafeObject(settings, @selector(currentColorPalette));
    return BHTSafeObject(info, @selector(colorPalette));
}

// X's colors for a pressed or selected post, card or row, read from the
// palette (again when the theme changes).
static NSArray<UIColor*>* HighlightColors(void) {
    static NSArray<UIColor*>* cached;
    static UIColor* readForTheme;
    UIColor* theme = ThemeBackgroundColor();
    if (cached && readForTheme == theme) {
        return cached;
    }
    NSMutableArray<UIColor*>* colors = [NSMutableArray array];
    id palette = CurrentPalette();
    for (NSString* name in @[@"highlightedStatusBackgroundColor", @"statusCellOverlayHighlightedColor",
                             @"highlightDarkBackgroundColor", @"dmInboxCellSelectionBackgroundColor"]) {
        UIColor* color = BHTSafeObject(palette, NSSelectorFromString(name));
        if ([color isKindOfClass:UIColor.class]) {
            [colors addObject:color];
        }
    }
    cached = colors;
    readForTheme = theme;
    return cached;
}

static BOOL SameColor(UIColor* a, UIColor* b, UITraitCollection* traits) {
    if (a == b) {
        return YES;
    }
    CGFloat r1, g1, b1, a1, r2, g2, b2, a2;
    if (![[a resolvedColorWithTraitCollection:traits] getRed:&r1 green:&g1 blue:&b1 alpha:&a1] ||
        ![[b resolvedColorWithTraitCollection:traits] getRed:&r2 green:&g2 blue:&b2 alpha:&a2]) {
        return NO;
    }
    return fabs(r1 - r2) < 0.01 && fabs(g1 - g2) < 0.01 && fabs(b1 - b2) < 0.01 && fabs(a1 - a2) < 0.05;
}

static BOOL IsInsideSidebar(UIView* view);
static UIView* SidebarViewForLayers(void);

static BOOL IsInsideCell(UIView* view) {
    for (UIView* ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UITableViewCell.class] || [ancestor isKindOfClass:UICollectionViewCell.class]) {
            return YES;
        }
    }
    return NO;
}

// A pressed or selected highlight: one of X's highlight colors, or (in a
// row or the sidebar) an opaque color just off the theme's background.
// Over the wallpaper those would show as patches of the theme color.
static BOOL IsHighlightColor(UIColor* color, UIView* view, CGFloat distance, CGFloat alpha) {
    if (alpha < 0.05) {
        return NO;
    }
    UITraitCollection* traits = view.traitCollection;
    for (UIColor* highlight in HighlightColors()) {
        if (SameColor(color, highlight, traits)) {
            return YES;
        }
    }
    return distance >= 0.03 && distance <= 0.10 && alpha >= 0.85 && (IsInsideCell(view) || IsInsideSidebar(view));
}

// What a highlight looks like over the wallpaper: the theme color, half
// see-through. (Under 0.5 alpha, so nothing here takes it for a theme
// background to make clear.)
static UIColor* HighlightTint(void) {
    static UIColor* tint;
    static UIColor* forTheme;
    UIColor* theme = ThemeBackgroundColor();
    if (!tint || forTheme != theme) {
        tint = [theme colorWithAlphaComponent:0.45];
        forTheme = theme;
    }
    return tint;
}

// The sidebar is SwiftUI: a pressed row is drawn straight on a layer in the
// theme color (or just off it), never through a view. A short layer inside
// the sidebar given that color gets the highlight tint instead.
static CGColorRef SidebarHighlightReplacement(CALayer* layer, CGColorRef color) {
    UIView* sidebar = SidebarViewForLayers();
    if (!sidebar || CGColorGetAlpha(color) < 0.5 || [layer.name isEqualToString:@"BHTWallpaper"]) {
        return NULL;
    }
    CGFloat alpha = 0;
    if (ThemeDistance([UIColor colorWithCGColor:color], sidebar, &alpha) > 0.10) {
        return NULL;
    }
    if (layer.bounds.size.height > sidebar.bounds.size.height * 0.25) {
        return NULL;
    }
    CALayer* sidebarLayer = sidebar.layer;
    for (CALayer* ancestor = layer.superlayer; ancestor; ancestor = ancestor.superlayer) {
        if (ancestor == sidebarLayer) {
            return [HighlightTint() resolvedColorWithTraitCollection:sidebar.traitCollection].CGColor;
        }
    }
    return NULL;
}

%hook CALayer

- (void)setBackgroundColor:(CGColorRef)color {
    if (FullOn && color) {
        CGColorRef replacement = SidebarHighlightReplacement(self, color);
        if (replacement) {
            %orig(replacement);
            return;
        }
    }
    %orig;
}

%end

// The color the view actually draws: its layer's. X answers `backgroundColor`
// with the color it recorded for the view, which isn't what's drawn once the
// view was made clear.
static UIColor* EffectiveBackgroundColor(UIView* view) {
    CGColorRef drawn = view.layer.backgroundColor;
    return drawn ? [UIColor colorWithCGColor:drawn] : nil;
}

// MARK: - Making views clear

// YES when the view was in the theme color, at least `minAlpha` opaque, and
// is now clear.
static BOOL ClearThemeColor(UIView* view, CGFloat minAlpha) {
    if (![view isKindOfClass:UIView.class]) {
        return NO;
    }
    UIColor* drawn = EffectiveBackgroundColor(view);
    if (!ColorMatchesTheme(drawn, view, minAlpha)) {
        return NO;
    }
    // What X set (a color that follows the theme), to put back; or the layer's
    // own color when X colors the layer directly.
    UIColor* color = view.backgroundColor;
    BOOL layerOnly = !color;
    if (layerOnly) {
        color = drawn;
    }
    objc_setAssociatedObject(view, OriginalBackgroundKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, LayerBackgroundKey, layerOnly ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, KeepClearKey, @(Generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [WeakSet(&ClearedViewsStorage) addObject:view];
    if (layerOnly) {
        view.layer.backgroundColor = UIColor.clearColor.CGColor;
    } else {
        view.backgroundColor = UIColor.clearColor;
    }
    return YES;
}

static BOOL ClearThemeBackground(UIView* view) {
    return ClearThemeColor(view, 0.85);
}

// A view made clear in the current generation.
static BOOL KeepsClear(UIView* view) {
    NSNumber* generation = objc_getAssociatedObject(view, KeepClearKey);
    return generation && generation.unsignedIntegerValue == Generation;
}

// Views X painted in the theme color since the last pass, handled before
// the frame is drawn (see ProcessThemedViews); and those painted while not
// on screen, handled as they come on screen.
static NSHashTable* ThemedViewsStorage;
static BOOL ThemedViewsPending;
static NSHashTable* OffscreenThemedViewsStorage;
static BOOL OffscreenThemedViewsPending;
static BOOL BlurTintsExist;

static void ApplyToThemedView(UIView* view);
static void ApplyTintPiece(UIView* tint);
static void ProcessThemedViews(BOOL beforeDrawing);

// The tint X lays over one of its blurs (the profile header's, collapsed):
// its own view inside the blur.
static BOOL IsBlurTint(UIView* view) {
    UIView* parent = view.superview;
    for (int i = 0; i < 3 && parent; i++, parent = parent.superview) {
        if (IsCustomBlur(parent)) {
            id tint = objectIvar(parent, "tintView");
            if ([tint isKindOfClass:UIView.class]) {
                return tint == view;
            }
            return view.subviews.count == 0;
        }
    }
    return NO;
}

// The tint shows the wallpaper at its strength instead of the theme color;
// the blur itself is left alone.
static void ShowWallpaperAsTint(UIView* tint, UIColor* color, CGFloat alpha) {
    objc_setAssociatedObject(tint, PlateKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tint, TintAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tint, OriginalBackgroundKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tint, LayerBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [WeakSet(&ClearedViewsStorage) addObject:tint];
    BlurTintsExist = YES;
    ApplyTintPiece(tint);
}

// Every time X (or anything) gives a view a background color:
// - a view made clear stays clear, in the same call, so it never flashes
//   back (X calls the setter again whenever the look changes);
// - a blur's tint in the theme color shows the wallpaper instead;
// - a pressed or selected highlight becomes a dark tint;
// - any other view given the theme's background color is noted, and gets
//   made clear or its part of the picture before the frame is drawn.
%hook UIView

- (void)setBackgroundColor:(UIColor*)color {
    if (WallpaperOn && color) {
        BOOL keepsClear = KeepsClear(self);
        if (keepsClear || BarsOn) {
            CGFloat alpha = 0;
            CGFloat distance = ThemeDistance(color, self, &alpha);
            BOOL themeColored = distance < 0.03;
            if (FullOn && themeColored && IsBlurTint(self)) {
                ShowWallpaperAsTint(self, color, alpha);
                %orig(UIColor.clearColor);
                return;
            }
            if (themeColored && alpha >= 0.5) {
                if (keepsClear) {
                    objc_setAssociatedObject(self, OriginalBackgroundKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    %orig(UIColor.clearColor);
                    return;
                }
                [WeakSet(&ThemedViewsStorage) addObject:self];
                ThemedViewsPending = YES;
            } else if (FullOn && !themeColored && IsHighlightColor(color, self, distance, alpha)) {
                %orig(HighlightTint());
                return;
            }
        }
    }
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    UIView* view = (UIView*)self;
    if (!view.window) {
        return;
    }
    if (OffscreenThemedViewsPending) {
        NSHashTable* offscreen = WeakSet(&OffscreenThemedViewsStorage);
        if ([offscreen containsObject:view]) {
            [offscreen removeObject:view];
            ApplyToThemedView(view);
        }
    }
    if (BlurTintsExist && FullOn && objc_getAssociatedObject(view, TintAlphaKey)) {
        ApplyTintPiece(view);
    }
}

%end

static void RestoreClearedViews(void) {
    for (UIView* view in WeakSet(&ClearedViewsStorage).allObjects) {
        objc_setAssociatedObject(view, KeepClearKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIColor* original = objc_getAssociatedObject(view, OriginalBackgroundKey);
        // Judged by what's drawn: X may answer `backgroundColor` with the
        // color it recorded.
        CGColorRef current = view.layer.backgroundColor;
        BOOL drawnClear = !current || CGColorGetAlpha(current) < 0.01;
        if (original && drawnClear) {
            if (objc_getAssociatedObject(view, LayerBackgroundKey)) {
                view.layer.backgroundColor = [original resolvedColorWithTraitCollection:view.traitCollection].CGColor;
            } else {
                view.backgroundColor = original;
            }
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
        if (IsCustomBlur(view)) {
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

// MARK: - Alignment

static BOOL HoldsMainApp(UIView* view);

// The modal `view` is in: a view controller opened over another, not inside
// one (the main app itself never counts).
static UIViewController* PresentedRootOf(UIView* view) {
    for (UIView* ancestor = view; ancestor; ancestor = ancestor.superview) {
        UIResponder* responder = ancestor.nextResponder;
        if ([responder isKindOfClass:UIViewController.class]) {
            UIViewController* controller = (UIViewController*)responder;
            if (controller.viewIfLoaded == ancestor && controller.presentingViewController &&
                !controller.parentViewController) {
                return HoldsMainApp(ancestor) ? nil : controller;
            }
        }
    }
    return nil;
}

// A modal that keeps the screen it was opened from on screen behind it (the
// media viewer, whose background fades to show that screen as the picture is
// dragged away). It gets no back and nothing in it is made clear, so it
// shows the screen behind it the way X means it to.
static BOOL IsInsideSeeThroughPresentation(UIView* view) {
    UIViewController* presented = PresentedRootOf(view);
    if (!presented) {
        return NO;
    }
    UIModalPresentationStyle style = presented.modalPresentationStyle;
    if (style == UIModalPresentationOverFullScreen || style == UIModalPresentationOverCurrentContext) {
        return YES;
    }
    if (style == UIModalPresentationCustom) {
        UIPresentationController* presentation = presented.presentationController;
        return presentation && !presentation.shouldRemovePresentersView;
    }
    return NO;
}

// What the picture is laid out against, the size of the window and anchored
// at its top left: a sheet or modal's own view (it slides as one piece),
// otherwise the nearest view directly under the root view or the window: one
// back behind the sidebar, the main content and the tab bar.
static UIView* AlignmentReference(UIView* view) {
    UIWindow* window = view.window;
    if (!window) {
        return nil;
    }
    UIView* rootView = window.rootViewController.viewIfLoaded;
    UIView* fallback = nil;
    for (UIView* ancestor = view; ancestor && ancestor != window; ancestor = ancestor.superview) {
        UIResponder* responder = ancestor.nextResponder;
        if ([responder isKindOfClass:UIViewController.class]) {
            UIViewController* controller = (UIViewController*)responder;
            if (controller.viewIfLoaded == ancestor && controller.presentingViewController &&
                !controller.parentViewController) {
                return ancestor;
            }
        }
        if (!fallback && (ancestor.superview == rootView || ancestor.superview == window)) {
            fallback = ancestor;
        }
    }
    return fallback ?: window;
}

// Where the picture goes in `view`'s coordinates. `reference`, when given,
// overrides the lookup.
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
        [view isKindOfClass:BHTWallpaperView.class] || IsCustomBlur(view)) {
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

// Only the header's own layers get parts: its background reaches up under
// the status bar, but nothing reaching far below the bar (an overlay X puts
// there during transitions) does, or it would become a plate over the screen.
static BOOL FitsInBar(UIView* view, UINavigationBar* bar) {
    CGRect frame = [view convertRect:view.bounds toView:bar];
    CGFloat barHeight = bar.bounds.size.height;
    return CGRectGetMaxY(frame) <= barHeight + 80 && frame.size.height <= barHeight + 200;
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
    // A large view's part stays only while the view is painted in the theme
    // color: one left on an overlay X made clear or recolored (done with it)
    // would turn it into a plate covering what's under it. Short chrome (the
    // tab strips, header parts) keeps its part through X's passing recolors,
    // so it never flashes in the theme color; the backs and transition
    // overlays keep theirs whatever their color.
    if (!objc_getAssociatedObject(view, PlateKey) &&
        view.bounds.size.height > view.window.bounds.size.height * 0.25 &&
        !ColorMatchesTheme(EffectiveBackgroundColor(view), view, 0.5)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [container removeFromSuperlayer];
        [CATransaction commit];
        [WeakSet(&PiecesStorage) removeObject:view];
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

// A blur tint's part: the wallpaper at the tint's strength.
static void ApplyTintPiece(UIView* tint) {
    NSNumber* alpha = objc_getAssociatedObject(tint, TintAlphaKey);
    if (!alpha || !tint.window) {
        return;
    }
    PaintPiece(tint);
    CALayer* container = PieceLayer(tint, NO);
    if (container && fabsf(container.opacity - alpha.floatValue) > 0.001f) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        container.opacity = alpha.floatValue;
        [CATransaction commit];
    }
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
    ClearThemeBackground(objectIvar(cell, "_backgroundView"));
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
    if (back && back != view.window && ![back isKindOfClass:UIScrollView.class] &&
        !IsInsideSeeThroughPresentation(back)) {
        objc_setAssociatedObject(back, PlateKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// A row of tabs (Following, All/Mentions, Top/Latest...): X's segmented tab
// bar, or another segmented bar by its name.
static BOOL IsTabStrip(UIView* view) {
    Class stripClass = TabStripClass();
    if (stripClass && [view isKindOfClass:stripClass]) {
        return YES;
    }
    NSString* name = NSStringFromClass(view.class);
    return [name containsString:@"Segmented"] && ([name containsString:@"TabBar"] || [name containsString:@"TabsBar"]);
}

static BOOL NavigationBarWantsWallpaper(UINavigationBar* bar);

// A strip and its short containers get a part of the picture: content passes
// under them. What's inside (the row of tabs, the views X paints with the
// strip) is made clear over that part, or gets its own part when nothing
// under it has one. X colors a strip in steps, some after the screen has
// appeared (coming back to a tab), so this runs as the strip lays out, comes
// on screen or is restyled, and again once a screen has settled.
static void PaintStrip(UIView* strip, BOOL inside) {
    UIWindow* window = strip.window;
    if (!BarsOn || !IsAppWindow(window)) {
        return;
    }
    CGFloat shortHeight = window.bounds.size.height * 0.25;
    // The row of tabs itself is a plate of the picture, like the header:
    // content scrolling under it is hidden, whatever color X gives it.
    if (!objc_getAssociatedObject(strip, PlateKey)) {
        objc_setAssociatedObject(strip, PlateKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    PaintPiece(strip);
    BOOL backed = NO;
    for (UIView* view = strip; view && view.bounds.size.height <= shortHeight; view = view.superview) {
        if ([view isKindOfClass:UINavigationBar.class]) {
            // The header's own parts are under it.
            backed = backed || NavigationBarWantsWallpaper((UINavigationBar*)view);
            break;
        }
        if (CanPaint(view, 0.5)) {
            PaintPiece(view);
        } else if (PieceLayer(view, NO)) {
            AlignPiece(view);
        }
        if (PieceLayer(view, NO).superlayer == view.layer) {
            backed = YES;
        }
    }
    if (!inside) {
        return;
    }
    NSMutableArray<UIView*>* queue = [strip.subviews mutableCopy];
    for (NSUInteger i = 0; i < queue.count && i < 80; i++) {
        UIView* view = queue[i];
        if ([view isKindOfClass:BHTWallpaperView.class] || IsCustomBlur(view)) {
            continue;
        }
        if (backed) {
            ClearThemeColor(view, 0.5);
        } else if (CanPaint(view, 0.5)) {
            PaintPiece(view);
        }
        if ([view isKindOfClass:UIImageView.class] || [view isKindOfClass:UILabel.class] ||
            [view isKindOfClass:UITextView.class]) {
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
}

// Changes when the strip's parts are replaced or it changes width.
static NSUInteger StripSignature(UIView* strip) {
    NSUInteger signature = (Generation << 20) ^ ((NSUInteger)strip.bounds.size.width << 8) ^ strip.subviews.count;
    for (UIView* subview in strip.subviews) {
        signature ^= (NSUInteger)(__bridge void*)subview;
        if ([subview isKindOfClass:UICollectionView.class]) {
            signature ^= ((UICollectionView*)subview).visibleCells.count << 4;
        }
    }
    return signature;
}

static NSHashTable* PendingStripsStorage;

// Once X is done with this pass (restyling, reloading the tabs).
static void SchedulePaintStrip(UIView* strip) {
    if (!BarsOn || !strip) {
        return;
    }
    NSHashTable* pending = WeakSet(&PendingStripsStorage);
    BOOL scheduled = pending.allObjects.count > 0;
    [pending addObject:strip];
    if (scheduled) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<UIView*>* strips = WeakSet(&PendingStripsStorage).allObjects;
        [WeakSet(&PendingStripsStorage) removeAllObjects];
        for (UIView* view in strips) {
            PaintStrip(view, YES);
        }
    });
}

static NSArray<UIView*>* StripsIn(UIView* root, NSUInteger limit) {
    NSMutableArray<UIView*>* strips = [NSMutableArray array];
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i = 0; i < queue.count && i < limit; i++) {
        UIView* view = queue[i];
        if (IsTabStrip(view)) {
            [strips addObject:view];
            continue;
        }
        if (IsList(view) || [view isKindOfClass:UIImageView.class] || [view isKindOfClass:UILabel.class] ||
            [view isKindOfClass:UITextView.class] || [view isKindOfClass:BHTWallpaperView.class] ||
            IsCustomBlur(view)) {
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return strips;
}

%hook _TtC10TFNUISwift25LegacySegmentedTabBarView

- (void)layoutSubviews {
    %orig;
    if (BarsOn) {
        UIView* strip = (UIView*)self;
        NSUInteger signature = StripSignature(strip);
        NSNumber* last = objc_getAssociatedObject(strip, StripPassKey);
        BOOL changed = !last || last.unsignedIntegerValue != signature;
        if (changed) {
            objc_setAssociatedObject(strip, StripPassKey, @(signature), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        PaintStrip(strip, changed);
        ProcessThemedViews(NO);
    }
}

- (void)didMoveToWindow {
    %orig;
    if (BarsOn && ((UIView*)self).window) {
        PaintStrip((UIView*)self, YES);
        SchedulePaintStrip((UIView*)self);
    }
}

- (void)setBackgroundColor:(UIColor*)color {
    %orig;
    SchedulePaintStrip((UIView*)self);
}

- (void)traitCollectionDidChange:(UITraitCollection*)previousTraitCollection {
    %orig;
    SchedulePaintStrip((UIView*)self);
}

- (void)reloadData {
    %orig;
    SchedulePaintStrip((UIView*)self);
}

- (void)reloadVisibleTabs {
    %orig;
    SchedulePaintStrip((UIView*)self);
}

%end

// The bar holding a screen's strip, when X recolors it.
%group StripContainer
%hook _TtC10TFNUISwift29SegmentedTabsBarContainerView

- (void)setBackgroundColor:(UIColor*)color {
    %orig;
    if (BarsOn) {
        for (UIView* strip in StripsIn((UIView*)self, 30)) {
            SchedulePaintStrip(strip);
        }
    }
}

%end
%end

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
    NSSet* tabBarViews = TabBarViews();

    NSMutableArray<UIView*>* visited = [NSMutableArray array];
    NSMutableArray<UIView*>* strips = [NSMutableArray array];
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i = 0; i < queue.count && i < limit; i++) {
        UIView* view = queue[i];
        if ([view isKindOfClass:BHTWallpaperView.class] || [view isKindOfClass:UINavigationBar.class] ||
            [tabBarViews containsObject:view] || IsCustomBlur(view)) {
            continue;
        }
        [visited addObject:view];
        if (IsTabStrip(view)) {
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
        // A short bar in a slightly translucent theme color is chrome content
        // passes under (a strip of a kind not recognized above): it gets a
        // part of the picture rather than being made clear.
        UIColor* color = EffectiveBackgroundColor(view);
        if (view.bounds.size.height <= shortHeight && !ColorIsThemeBackground(color, view) &&
            ColorMatchesTheme(color, view, 0.5)) {
            if (CanPaint(view, 0.5)) {
                PaintPiece(view);
            }
            continue;
        }
        cleared = ClearThemeBackground(view) || cleared;
    }
    for (UIView* strip in strips) {
        PaintStrip(strip, YES);
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
    if (IsHostList(list) || IsInsideSeeThroughPresentation(list)) {
        return NO;
    }
    UIColor* color = EffectiveBackgroundColor(list);
    BOOL alreadyClear = !color || CGColorGetAlpha(color.CGColor) < 0.01;
    BOOL cleared = NO;
    if (!alreadyClear) {
        if (!ColorMatchesTheme(color, list, 0.5)) {
            return NO;
        }
        cleared = ClearThemeBackground(list);
        if (!cleared) {
            // Slightly translucent theme colors under the clearing bar.
            objc_setAssociatedObject(list, OriginalBackgroundKey, list.backgroundColor ?: color,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(list, KeepClearKey, @(Generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    if (!root || !IsAppWindow(window) || IsInsideSeeThroughPresentation(root)) {
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

static void ScheduleSettlePass(UIViewController* controller);
static void ProcessThemedViews(BOOL beforeDrawing);
static void EndFadesOf(UIViewController* controller, BOOL appearing);

%hook UIViewController

- (void)viewDidLayoutSubviews {
    %orig;
    if (FullOn) {
        ClearController(self, NO);
    }
    // What X painted while laying this screen out, in the same frame.
    ProcessThemedViews(NO);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    EndFadesOf(self, YES);
    if (FullOn) {
        ClearController(self, YES);
        ScheduleSettlePass(self);
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    EndFadesOf(self, NO);
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
// the one below). With clear screens both would show at once, so they
// cross-fade alongside the slide: the one leaving fades out, the one coming
// in fades in. UIKit runs the fades with the slide, so an interactive swipe
// back fades with the finger, and a cancelled one fades back.

// Views fading and the navigation controllers moving them; whatever the
// transitions report, every fade is undone once none of them is moving
// (checked before each frame).
static NSHashTable* FadingViewsStorage;
static NSHashTable* FadingNavigationsStorage;
// UIKit's shade views hidden during transitions.
static NSHashTable* HiddenShadesStorage;
// Screens that were ever faded (see ShowScreenAtNormalAlpha).
static NSHashTable* FadedScreensStorage;

// A view's own alpha while it fades, put back when the transition ends.
static void RestoreFade(UIView* view) {
    NSNumber* original = objc_getAssociatedObject(view, FadeAlphaKey);
    if (!original) {
        return;
    }
    objc_setAssociatedObject(view, FadeAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, FadeTransitionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, FadeNavigationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [WeakSet(&FadingViewsStorage) removeObject:view];
    [UIView performWithoutAnimation:^{
        view.alpha = original.doubleValue;
    }];
}

// UIKit darkens the screen underneath while another slides over it, and
// shades the moving screen's edge. Over clear screens that shows as a dark
// veil on the wallpaper, so those views (which only live for the
// transition) are hidden. Only empty plain views are ever hidden: the
// screens, their wrappers and snapshots never are, even before UIKit has
// put the screen inside them.
static BOOL IsDarkShade(UIView* view) {
    UIColor* color = view.backgroundColor;
    if (!color) {
        return NO;
    }
    CGFloat red = 1, green = 1, blue = 1, alpha = 0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white = 1;
        if (![color getWhite:&white alpha:&alpha]) {
            return NO;
        }
        red = green = blue = white;
    }
    return alpha > 0 && red < 0.2 && green < 0.2 && blue < 0.2;
}

static BOOL IsTransitionShade(UIView* view) {
    if (view.subviews.count > 0 || view.hidden) {
        return NO;
    }
    Class viewClass = view.class;
    if (viewClass != UIView.class && viewClass != UIImageView.class) {
        return NO;
    }
    if ([NSStringFromClass(view.superview.class) containsString:@"Dimming"]) {
        return YES;
    }
    return viewClass == UIView.class && IsDarkShade(view);
}

static NSArray<UIView*>* HideTransitionDimming(UIView* container, UIView* fromView, UIView* toView) {
    NSMutableArray<UIView*>* hidden = [NSMutableArray array];
    NSMutableArray<UIView*>* queue = [container.subviews mutableCopy] ?: [NSMutableArray array];
    for (NSUInteger i = 0; i < queue.count && i < 40; i++) {
        UIView* view = queue[i];
        if (view == fromView || view == toView || [view isKindOfClass:BHTWallpaperView.class] ||
            [view.nextResponder isKindOfClass:UIViewController.class]) {
            continue;
        }
        if (view.subviews.count > 0) {
            // UIKit's dimming view wraps the screen: its shade is beside it.
            BOOL holdsScreen = (fromView && [fromView isDescendantOfView:view]) ||
                               (toView && [toView isDescendantOfView:view]);
            if (holdsScreen || [NSStringFromClass(view.class) containsString:@"Dimming"]) {
                [queue addObjectsFromArray:view.subviews];
            }
            continue;
        }
        if (IsTransitionShade(view)) {
            view.hidden = YES;
            [hidden addObject:view];
            [WeakSet(&HiddenShadesStorage) addObject:view];
        }
    }
    return hidden;
}

static void ShowShades(NSArray<UIView*>* shades) {
    for (UIView* shade in shades) {
        shade.hidden = NO;
        [WeakSet(&HiddenShadesStorage) removeObject:shade];
    }
}

// Fades `view` in (from clear) or out alongside the transition, once per
// transition even when several pop calls report the same one. The start is
// set again when the animation starts, in case X put the view back in the
// meantime.
static void FadeAlongside(UINavigationController* navigationController,
                          id<UIViewControllerTransitionCoordinator> coordinator, UIView* view, BOOL fadeIn,
                          UIView* fromView, UIView* toView) {
    if (!view) {
        return;
    }
    // Several pop calls can report the same transition: one fade each.
    NSValue* transition = [NSValue valueWithPointer:(__bridge const void*)coordinator];
    NSNumber* stored = objc_getAssociatedObject(view, FadeAlphaKey);
    if (stored && [objc_getAssociatedObject(view, FadeTransitionKey) isEqual:transition]) {
        return;
    }
    // A fade an earlier transition never undid keeps its real alpha, and this
    // transition fades the view anyway.
    CGFloat original = stored ? stored.doubleValue : view.alpha;
    // A view X keeps hidden this way is left to X.
    if (original < 0.01) {
        return;
    }
    objc_setAssociatedObject(view, FadeAlphaKey, @(original), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, FadeTransitionKey, transition, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, FadeNavigationKey,
                             [NSValue valueWithPointer:(__bridge const void*)navigationController],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([view.nextResponder isKindOfClass:UIViewController.class]) {
        objc_setAssociatedObject(view, ScreenNormalAlphaKey, @(original), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [WeakSet(&FadedScreensStorage) addObject:view];
    }
    [WeakSet(&FadingViewsStorage) addObject:view];
    [WeakSet(&FadingNavigationsStorage) addObject:navigationController];
    if (fadeIn) {
        [UIView performWithoutAnimation:^{
            view.alpha = 0;
        }];
    }
    __block NSArray<UIView*>* shades = nil;
    [coordinator
        animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            shades = HideTransitionDimming(context.containerView, fromView, toView);
            if (fadeIn) {
                [UIView performWithoutAnimation:^{
                    view.alpha = 0;
                }];
            }
            view.alpha = fadeIn ? original : 0;
        }
        completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            ShowShades(shades);
            RestoreFade(view);
        }];
}

// The strip X shows in the header for a screen (Following/For you...): it
// belongs to the screen, so it fades with it.
static UIView* HeaderAccessoryOf(UIViewController* controller) {
    SEL getter = @selector(tfn_navigationBarAccessoryView);
    NSMutableArray<UIViewController*>* queue = [NSMutableArray arrayWithObject:controller];
    for (NSUInteger i = 0; i < queue.count && i < 8; i++) {
        UIView* accessory = BHTSafeObject(queue[i], getter);
        if ([accessory isKindOfClass:UIView.class]) {
            return accessory;
        }
        [queue addObjectsFromArray:queue[i].childViewControllers];
    }
    return nil;
}

// UIKit's own coordinator for a navigation controller's transition. X's tab
// navigation controller answers transitionCoordinator with one of its own,
// which can still be an earlier transition's (right after a post was
// opened), so UIKit's is asked directly.
static id<UIViewControllerTransitionCoordinator> UIKitTransitionCoordinator(UINavigationController* navigationController) {
    static IMP uikitGetter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uikitGetter = [UINavigationController instanceMethodForSelector:@selector(transitionCoordinator)];
    });
    return uikitGetter ? ((id (*)(id, SEL))uikitGetter)(navigationController, @selector(transitionCoordinator)) : nil;
}

// The coordinator of the push or pop that just started: UIKit's or X's,
// whichever really moves `expectedFrom` (the screen being popped) or
// `expectedTo` (the screen being pushed).
static id<UIViewControllerTransitionCoordinator> CoordinatorFor(UINavigationController* navigationController,
                                                                 UIViewController* expectedFrom,
                                                                 UIViewController* expectedTo) {
    id<UIViewControllerTransitionCoordinator> candidates[2] = {
        UIKitTransitionCoordinator(navigationController), navigationController.transitionCoordinator};
    for (int i = 0; i < 2; i++) {
        id<UIViewControllerTransitionCoordinator> coordinator = candidates[i];
        if (!coordinator || !coordinator.isAnimated) {
            continue;
        }
        UIViewController* from = [coordinator viewControllerForKey:UITransitionContextFromViewControllerKey];
        UIViewController* to = [coordinator viewControllerForKey:UITransitionContextToViewControllerKey];
        if ((!expectedFrom || from == expectedFrom) && (!expectedTo || to == expectedTo)) {
            return coordinator;
        }
    }
    return nil;
}

// X's own navigation controllers, whose transitions show the wallpaper
// through their overlay instead (see "X's own transitions").
static BOOL UsesTransitionOverlay(UINavigationController* navigationController) {
    static Class navigationClass;
    static BOOL overlayAvailable;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        navigationClass = objc_getClass("TFNNavigationController");
        overlayAvailable = objc_getClass("TFNNavigationControllerTransitionAnimator") != nil;
    });
    return overlayAvailable && navigationClass && [navigationController isKindOfClass:navigationClass];
}

static void CrossFadeScreens(UINavigationController* navigationController, UIViewController* expectedFrom,
                             UIViewController* expectedTo) {
    if (!FullOn || UsesTransitionOverlay(navigationController)) {
        return;
    }
    id<UIViewControllerTransitionCoordinator> coordinator =
        CoordinatorFor(navigationController, expectedFrom, expectedTo);
    if (!coordinator) {
        return;
    }
    UIViewController* from = [coordinator viewControllerForKey:UITransitionContextFromViewControllerKey];
    UIViewController* to = [coordinator viewControllerForKey:UITransitionContextToViewControllerKey];
    UIView* fromView = from.viewIfLoaded;
    UIView* toView = to.viewIfLoaded;
    if (!fromView || !IsAppWindow(fromView.window)) {
        return;
    }
    FadeAlongside(navigationController, coordinator, fromView, NO, fromView, toView);
    if (toView && toView != fromView) {
        FadeAlongside(navigationController, coordinator, toView, YES, fromView, toView);
    }
    UIView* fromAccessory = from ? HeaderAccessoryOf(from) : nil;
    UIView* toAccessory = to ? HeaderAccessoryOf(to) : nil;
    if (fromAccessory && fromAccessory != toAccessory) {
        FadeAlongside(navigationController, coordinator, fromAccessory, NO, fromView, toView);
    }
    if (toAccessory && toAccessory != fromAccessory) {
        FadeAlongside(navigationController, coordinator, toAccessory, YES, fromView, toView);
    }
}

// A screen has finished appearing or disappearing: its transition is over,
// whatever the transition reported, so its fades (and its header strip's)
// are undone. A screen that was ever faded and now appears gets its normal
// alpha back even if something set it again after the fade ended, now and
// once more right after (the transition may still be cleaning up), unless a
// new transition is fading it by then.
static void ShowScreenAtNormalAlpha(UIView* view) {
    NSNumber* normal = objc_getAssociatedObject(view, ScreenNormalAlphaKey);
    if (!normal || objc_getAssociatedObject(view, FadeAlphaKey)) {
        return;
    }
    if (fabs(view.alpha - normal.doubleValue) > 0.01) {
        [UIView performWithoutAnimation:^{
            view.alpha = normal.doubleValue;
        }];
    }
}

static void EndFadesOf(UIViewController* controller, BOOL appearing) {
    UIView* view = controller.viewIfLoaded;
    if (!view) {
        return;
    }
    if (WeakSet(&FadingViewsStorage).count > 0) {
        RestoreFade(view);
        UIView* accessory = HeaderAccessoryOf(controller);
        if (accessory) {
            RestoreFade(accessory);
        }
    }
    if (appearing && objc_getAssociatedObject(view, ScreenNormalAlphaKey)) {
        ShowScreenAtNormalAlpha(view);
        __weak UIView* weakView = view;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView* strongView = weakView;
            if (strongView) {
                ShowScreenAtNormalAlpha(strongView);
            }
        });
    }
}

// Before each frame: once no navigation controller that started a fade is
// moving any more (finished, cancelled, or a transition that never reported
// its end), every fade is undone and every hidden shade shown again. Shades
// that turned out to hold something are shown at once.
static void SettleTransitions(void) {
    for (UIView* shade in WeakSet(&HiddenShadesStorage).allObjects) {
        if (shade.subviews.count > 0) {
            shade.hidden = NO;
            [WeakSet(&HiddenShadesStorage) removeObject:shade];
        }
    }
    // The screen on top of its navigation controller, with no fade running
    // on it, is never left see-through.
    for (UIView* screen in WeakSet(&FadedScreensStorage).allObjects) {
        if (!screen.window || objc_getAssociatedObject(screen, FadeAlphaKey)) {
            continue;
        }
        UIViewController* controller = (UIViewController*)screen.nextResponder;
        if (![controller isKindOfClass:UIViewController.class]) {
            continue;
        }
        UINavigationController* navigationController = controller.navigationController;
        if (navigationController && navigationController.topViewController != controller) {
            continue;
        }
        ShowScreenAtNormalAlpha(screen);
    }
    NSHashTable* fading = WeakSet(&FadingViewsStorage);
    if (fading.count == 0) {
        return;
    }
    for (UINavigationController* navigationController in WeakSet(&FadingNavigationsStorage).allObjects) {
        if (UIKitTransitionCoordinator(navigationController)) {
            return;
        }
    }
    for (UIView* view in fading.allObjects) {
        RestoreFade(view);
    }
    [fading removeAllObjects];
    [WeakSet(&FadingNavigationsStorage) removeAllObjects];
    ShowShades(WeakSet(&HiddenShadesStorage).allObjects);
}

static void PaintNavigationBar(UINavigationBar* bar, BOOL force);

// A screen's header, painted now: what X painted since the last pass, its
// strip, and the header itself.
static void PrepaintHeaderOf(UIViewController* controller) {
    if (!BarsOn || ![controller isKindOfClass:UIViewController.class]) {
        return;
    }
    ProcessThemedViews(NO);
    UIView* accessory = HeaderAccessoryOf(controller);
    if (accessory.window) {
        for (UIView* strip in StripsIn(accessory, 40)) {
            PaintStrip(strip, YES);
        }
    }
    UINavigationBar* bar = controller.navigationController.navigationBar;
    if (NavigationBarWantsWallpaper(bar)) {
        PaintNavigationBar(bar, NO);
    }
}

// X's navigation controller finished its own transition animation (done or
// cancelled): every fade it started ends now.
static void EndNavigationFades(UINavigationController* navigationController) {
    NSValue* navigation = [NSValue valueWithPointer:(__bridge const void*)navigationController];
    for (UIView* view in WeakSet(&FadingViewsStorage).allObjects) {
        if ([objc_getAssociatedObject(view, FadeNavigationKey) isEqual:navigation]) {
            RestoreFade(view);
        }
    }
    ShowShades(WeakSet(&HiddenShadesStorage).allObjects);
}

%hook UINavigationController

- (void)pushViewController:(UIViewController*)viewController animated:(BOOL)animated {
    %orig;
    if (animated) {
        CrossFadeScreens(self, nil, viewController);
    }
}

- (UIViewController*)popViewControllerAnimated:(BOOL)animated {
    UIViewController* popped = %orig;
    if (animated && popped) {
        CrossFadeScreens(self, popped, nil);
    }
    return popped;
}

- (NSArray*)popToViewController:(UIViewController*)viewController animated:(BOOL)animated {
    NSArray* popped = %orig;
    if (animated && popped.count) {
        CrossFadeScreens(self, popped.lastObject, viewController);
    }
    return popped;
}

- (NSArray*)popToRootViewControllerAnimated:(BOOL)animated {
    NSArray* popped = %orig;
    if (animated && popped.count) {
        CrossFadeScreens(self, popped.lastObject, self.viewControllers.firstObject);
    }
    return popped;
}

%end

%group TFNTransitions
%hook TFNNavigationController

- (void)_tfn_transitionAnimationCompletedIsCanceled:(BOOL)canceled isPush:(BOOL)push {
    %orig;
    EndNavigationFades((UINavigationController*)self);
}

// X snapshots a screen's header items to show while the header changes over
// (coming back to the timeline from the tab bar). The header is painted
// first, so the snapshot never carries the theme color.
- (void)_tfn_recordGlassBarItemMirrorsOfViewController:(UIViewController*)controller {
    PrepaintHeaderOf(controller);
    %orig;
}

- (void)_tfn_beginGlassBarTransitionToViewController:(UIViewController*)controller {
    PrepaintHeaderOf(((UINavigationController*)self).topViewController);
    PrepaintHeaderOf(controller);
    %orig;
}

%end
%end

// MARK: - X's own transitions

// X's navigation controllers move screens with their own animator, which
// darkens the screen underneath with an overlay that follows the slide (and
// the finger on a swipe back, cancelled ones included). In "every screen"
// mode that overlay is the wallpaper itself: the screen underneath is
// covered by the wallpaper as a new one slides in over it, and uncovered as
// a swipe back goes on. The screens' own alpha is never touched there, so
// X's transition code (which also rearranges the header) finds them as it
// left them.

// The overlay in the theme color, fully covering at its strongest; X's own
// color is put back when the mode is off.
static void PrepareTransitionOverlay(id animator) {
    SEL setter = @selector(setBackgroundViewOverlayColor:maximumAlpha:);
    SEL alphaGetter = @selector(maximumAlpha);
    if (![animator respondsToSelector:setter] || ![animator respondsToSelector:alphaGetter]) {
        return;
    }
    double maximumAlpha = ((double (*)(id, SEL))objc_msgSend)(animator, alphaGetter);
    id saved = objc_getAssociatedObject(animator, OverlayOriginalColorKey);
    if (FullOn) {
        if (!saved) {
            id original = objectIvar(animator, "_backgroundViewOverlayColor");
            objc_setAssociatedObject(animator, OverlayOriginalColorKey,
                                     [original isKindOfClass:UIColor.class] ? original : NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ((void (*)(id, SEL, id, double))objc_msgSend)(animator, setter, ThemeBackgroundColor(), maximumAlpha);
    } else if (saved) {
        objc_setAssociatedObject(animator, OverlayOriginalColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, id, double))objc_msgSend)(animator, setter,
                                                      [saved isKindOfClass:UIColor.class] ? saved : nil,
                                                      maximumAlpha);
    }
}

// Where X may put the overlay: beside the screens or on top of one.
static NSArray<UIView*>* TransitionOverlayCandidates(id<UIViewControllerContextTransitioning> transition) {
    NSMutableArray<UIView*>* views = [NSMutableArray array];
    UIView* container = transition.containerView;
    UIView* fromView = [transition viewControllerForKey:UITransitionContextFromViewControllerKey].viewIfLoaded;
    UIView* toView = [transition viewControllerForKey:UITransitionContextToViewControllerKey].viewIfLoaded;
    for (UIView* parent in @[container ?: (id)NSNull.null, fromView ?: (id)NSNull.null, toView ?: (id)NSNull.null]) {
        if ([parent isKindOfClass:UIView.class]) {
            [views addObjectsFromArray:parent.subviews];
            for (UIView* child in parent.subviews) {
                [views addObjectsFromArray:child.subviews];
            }
        }
    }
    return views;
}

// The overlay X just added (a new screen-sized view in the theme color, not
// a screen or one holding a screen) gets the picture. How many were found.
static NSUInteger PaintTransitionOverlay(id<UIViewControllerContextTransitioning> transition, NSHashTable* before) {
    NSUInteger painted = 0;
    UIView* container = transition.containerView;
    UIView* fromView = [transition viewControllerForKey:UITransitionContextFromViewControllerKey].viewIfLoaded;
    UIView* toView = [transition viewControllerForKey:UITransitionContextToViewControllerKey].viewIfLoaded;
    CGSize size = container.bounds.size;
    for (UIView* view in TransitionOverlayCandidates(transition)) {
        if ([before containsObject:view] || view == fromView || view == toView ||
            [view isKindOfClass:BHTWallpaperView.class] ||
            (fromView && [fromView isDescendantOfView:view]) || (toView && [toView isDescendantOfView:view])) {
            continue;
        }
        if (view.bounds.size.width < size.width * 0.8 || view.bounds.size.height < size.height * 0.8) {
            continue;
        }
        if (!ColorMatchesTheme(EffectiveBackgroundColor(view), view, 0.5)) {
            continue;
        }
        objc_setAssociatedObject(view, PlateKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        PaintPiece(view);
        painted++;
    }
    return painted;
}

// Opening a screen when X's animator didn't dim the one underneath: a
// wallpaper overlay of our own goes over it, between the two screens, and
// fades in over the slide, so the old screen fades out as the new one comes
// in. It's removed when the transition ends.
static void AddPushOverlay(id animator, id<UIViewControllerContextTransitioning> transition) {
    if (transition.isInteractive) {
        return;
    }
    UIView* container = transition.containerView;
    UIView* fromView = [transition viewControllerForKey:UITransitionContextFromViewControllerKey].viewIfLoaded;
    UIView* toView = [transition viewControllerForKey:UITransitionContextToViewControllerKey].viewIfLoaded;
    if (!container || !fromView || ![fromView isDescendantOfView:container]) {
        return;
    }
    UIView* holder = fromView;
    while (holder.superview && holder.superview != container) {
        holder = holder.superview;
    }
    if (holder.superview != container || (toView && [toView isDescendantOfView:holder])) {
        return;
    }
    BHTWallpaperView* overlay = [[BHTWallpaperView alloc] initWithFrame:container.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UpdateWallpaperView(overlay);
    overlay.alpha = 0;
    [container insertSubview:overlay aboveSubview:holder];
    NSMutableArray<UIView*>* added = objc_getAssociatedObject(animator, AddedOverlaysKey);
    if (!added) {
        added = [NSMutableArray array];
        objc_setAssociatedObject(animator, AddedOverlaysKey, added, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [added addObject:overlay];
    NSTimeInterval duration = 0.3;
    if ([animator respondsToSelector:@selector(transitionDuration:)]) {
        duration = ((NSTimeInterval (*)(id, SEL, id))objc_msgSend)(animator, @selector(transitionDuration:),
                                                                   transition);
    }
    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         overlay.alpha = 1;
                     }
                     completion:nil];
}

// Opening a screen: the header strip of the screen being left (and X's
// snapshot of its header, which X shows while the header changes over)
// fades out with it. Their alpha is put back when the transition ends.
static void FadeOutHeaderForPush(id animator, id<UIViewControllerContextTransitioning> transition) {
    if (transition.isInteractive) {
        return;
    }
    UIViewController* from = [transition viewControllerForKey:UITransitionContextFromViewControllerKey];
    UINavigationController* navigationController = from.navigationController;
    if (![navigationController isKindOfClass:UINavigationController.class]) {
        navigationController = objectIvar(animator, "_navigationController");
    }
    NSMutableArray<UIView*>* views = [NSMutableArray array];
    UIView* accessory = from ? HeaderAccessoryOf(from) : nil;
    if (accessory) {
        [views addObject:accessory];
    }
    UIView* snapshot = objectIvar(navigationController, "_glassBarTransitionSnapshot");
    if ([snapshot isKindOfClass:UIView.class] && snapshot != accessory) {
        [views addObject:snapshot];
    }
    NSMutableArray* faded = objc_getAssociatedObject(animator, AddedFadesKey);
    if (!faded) {
        faded = [NSMutableArray array];
        objc_setAssociatedObject(animator, AddedFadesKey, faded, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSTimeInterval duration = 0.3;
    if ([animator respondsToSelector:@selector(transitionDuration:)]) {
        duration = ((NSTimeInterval (*)(id, SEL, id))objc_msgSend)(animator, @selector(transitionDuration:),
                                                                   transition);
    }
    for (UIView* view in views) {
        if (!view.window || view.alpha < 0.01) {
            continue;
        }
        [faded addObject:@[view, @(view.alpha)]];
        [UIView animateWithDuration:duration
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             view.alpha = 0;
                         }
                         completion:nil];
    }
}

static void RemoveAddedOverlays(id animator) {
    NSMutableArray<UIView*>* added = objc_getAssociatedObject(animator, AddedOverlaysKey);
    for (UIView* overlay in added) {
        [overlay removeFromSuperview];
    }
    [added removeAllObjects];
    NSMutableArray* faded = objc_getAssociatedObject(animator, AddedFadesKey);
    for (NSArray* entry in faded) {
        UIView* view = entry[0];
        CGFloat alpha = [entry[1] doubleValue];
        [view.layer removeAnimationForKey:@"opacity"];
        [UIView performWithoutAnimation:^{
            view.alpha = alpha;
        }];
    }
    [faded removeAllObjects];
}

// X's animator slides the screens with Core Animation: a screen's real
// place jumps to where it ends up while it's drawn sliding there. A part of
// the picture inside a sliding screen (a profile's tab strip) is lined up
// for that end place, and its picture gets the exact opposite of the
// screen's slide, with the same timing: it stays still against the
// wallpaper the whole way, follows the finger on a swipe back, and runs
// backwards with a cancelled one. Everything is lined up again when the
// transition ends.

// The slide moving `view`: the position animation on it or the nearest
// view holding it, as a change relative to where it ends up.
static CABasicAnimation* SlideAnimationFor(UIView* view, UIView* container, CGPoint* fromOffset, CGPoint* toOffset) {
    for (UIView* mover = view; mover && mover != container.superview; mover = mover.superview) {
        CAAnimation* animation = [mover.layer animationForKey:@"position"];
        if ([animation isKindOfClass:CABasicAnimation.class]) {
            CABasicAnimation* slide = (CABasicAnimation*)animation;
            if (![slide.fromValue isKindOfClass:NSValue.class]) {
                continue;
            }
            CGPoint from = [slide.fromValue CGPointValue];
            CGPoint to = slide.toValue ? [slide.toValue CGPointValue] : mover.layer.position;
            if (slide.additive) {
                *fromOffset = from;
                *toOffset = slide.toValue ? to : CGPointZero;
            } else {
                CGPoint end = mover.layer.position;
                *fromOffset = CGPointMake(from.x - end.x, from.y - end.y);
                *toOffset = CGPointMake(to.x - end.x, to.y - end.y);
            }
            return slide;
        }
        CAAnimation* transformAnimation = [mover.layer animationForKey:@"transform"];
        if ([transformAnimation isKindOfClass:CABasicAnimation.class]) {
            CABasicAnimation* slide = (CABasicAnimation*)transformAnimation;
            if (![slide.fromValue isKindOfClass:NSValue.class]) {
                continue;
            }
            CATransform3D from = [slide.fromValue CATransform3DValue];
            CATransform3D to = slide.toValue ? [slide.toValue CATransform3DValue] : mover.layer.transform;
            CATransform3D end = mover.layer.transform;
            if (slide.additive) {
                *fromOffset = CGPointMake(from.m41, from.m42);
                *toOffset = CGPointMake(to.m41, to.m42);
            } else {
                *fromOffset = CGPointMake(from.m41 - end.m41, from.m42 - end.m42);
                *toOffset = CGPointMake(to.m41 - end.m41, to.m42 - end.m42);
            }
            return slide;
        }
    }
    return nil;
}

static void HoldPiecesStillDuringSlide(id<UIViewControllerContextTransitioning> transition) {
    UIView* container = transition.containerView;
    if (!container) {
        return;
    }
    for (UIView* view in WeakSet(&PiecesStorage).allObjects) {
        if (![view isDescendantOfView:container]) {
            continue;
        }
        CALayer* picture = PieceLayer(view, NO).sublayers.firstObject;
        if (!picture) {
            continue;
        }
        CGPoint fromOffset = CGPointZero;
        CGPoint toOffset = CGPointZero;
        CABasicAnimation* slide = SlideAnimationFor(view, container, &fromOffset, &toOffset);
        if (!slide || (fromOffset.x == toOffset.x && fromOffset.y == toOffset.y)) {
            continue;
        }
        AlignPiece(view);
        CABasicAnimation* counter = [slide copy];
        counter.keyPath = @"position";
        counter.additive = YES;
        counter.fromValue = [NSValue valueWithCGPoint:CGPointMake(-fromOffset.x, -fromOffset.y)];
        counter.toValue = [NSValue valueWithCGPoint:CGPointMake(-toOffset.x, -toOffset.y)];
        [picture addAnimation:counter forKey:@"BHTHoldStill"];
    }
}

%group TFNOverlay
%hook TFNNavigationControllerTransitionAnimator

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)transition {
    PrepareTransitionOverlay(self);
    RemoveAddedOverlays(self);
    if (!FullOn) {
        %orig;
        return;
    }
    NSHashTable* before = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory |
                                                            NSPointerFunctionsObjectPointerPersonality];
    for (UIView* view in TransitionOverlayCandidates(transition)) {
        [before addObject:view];
    }
    %orig;
    NSUInteger painted = PaintTransitionOverlay(transition, before);
    HoldPiecesStillDuringSlide(transition);
    objc_setAssociatedObject(self, TransitionWindowKey, [NSValue valueWithNonretainedObject:transition.containerView.window],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    long long operation = [(id)self respondsToSelector:@selector(operation)]
                              ? ((long long (*)(id, SEL))objc_msgSend)(self, @selector(operation))
                              : 0;
    if (operation == UINavigationControllerOperationPush) {
        if (painted == 0) {
            AddPushOverlay(self, transition);
        }
        FadeOutHeaderForPush(self, transition);
    }
}

- (void)animationEnded:(BOOL)transitionCompleted {
    %orig;
    RemoveAddedOverlays(self);
    // Parts lined up for where the screens would end up: lined up again for
    // where they are (a cancelled swipe puts them back).
    UIWindow* window = [objc_getAssociatedObject(self, TransitionWindowKey) nonretainedObjectValue];
    objc_setAssociatedObject(self, TransitionWindowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (BarsOn && [window isKindOfClass:UIWindow.class]) {
        RealignPieces(window);
    }
}

- (double)_tfn_maximumAlphaForTransition:(id)transition {
    return FullOn ? 1.0 : %orig;
}

- (BOOL)suppressDimming {
    return FullOn ? NO : %orig;
}

%end
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
// Changes when any of the bar's views two levels down is replaced, not just
// when their number changes: X swaps the header's parts (coming back to a tab).
static NSUInteger BarSignature(UINavigationBar* bar) {
    NSUInteger signature = (Generation << 16) ^ bar.subviews.count;
    for (UIView* subview in bar.subviews) {
        signature ^= (NSUInteger)(__bridge void*)subview;
        for (UIView* inner in subview.subviews) {
            signature ^= (NSUInteger)(__bridge void*)inner >> 3;
        }
    }
    return signature;
}

static void PaintNavigationBar(UINavigationBar* bar, BOOL force) {
    NSUInteger signature = BarSignature(bar);
    NSNumber* last = objc_getAssociatedObject(bar, BarPassKey);
    if (force || !last || last.unsignedIntegerValue != signature) {
        objc_setAssociatedObject(bar, BarPassKey, @(signature), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:bar];
        for (NSUInteger i = 0; i < queue.count && i < 150; i++) {
            UIView* view = queue[i];
            if ([view isKindOfClass:BHTWallpaperView.class] || IsCustomBlur(view)) {
                continue;
            }
            if (IsTabStrip(view)) {
                PaintStrip(view, YES);
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
            if (CanPaint(view, 0.5) && FitsInBar(view, bar)) {
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

// A screen once it has settled: X finishes coloring the header and the tab
// strips after the screen appears, which a full pass catches.
static NSHashTable* SettlingControllersStorage;

static void SettleScreen(UIViewController* controller) {
    UIView* root = controller.viewIfLoaded;
    if (!root || !IsAppWindow(root.window)) {
        return;
    }
    if (FullOn) {
        ClearController(controller, YES);
    } else {
        for (UIView* strip in StripsIn(root, 200)) {
            PaintStrip(strip, YES);
        }
    }
    UINavigationBar* bar = controller.navigationController.navigationBar;
    if (NavigationBarWantsWallpaper(bar)) {
        PaintNavigationBar(bar, YES);
    }
}

static void ScheduleSettlePass(UIViewController* controller) {
    if (!BarsOn || !controller) {
        return;
    }
    NSHashTable* pending = WeakSet(&SettlingControllersStorage);
    BOOL scheduled = pending.allObjects.count > 0;
    [pending addObject:controller];
    if (scheduled) {
        return;
    }
    // Right after this pass (most of X's late coloring), then once more for
    // what comes later.
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIViewController* settling in WeakSet(&SettlingControllersStorage).allObjects) {
            SettleScreen(settling);
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSArray<UIViewController*>* controllers = WeakSet(&SettlingControllersStorage).allObjects;
        [WeakSet(&SettlingControllersStorage) removeAllObjects];
        for (UIViewController* settling in controllers) {
            SettleScreen(settling);
        }
    });
}

static UIView* TabBarBackground(UIViewController* tabBarController) {
    UIView* background = BHTSafeObject(tabBarController, @selector(tabBarBackgroundView));
    return [background isKindOfClass:UIView.class] ? background : nil;
}

// A part of the picture at the bottom of the tab bar's background view, below
// anything in it (the icons may be), unless the view draws itself. It's laid
// out against the same back as everything else (the tab bar controller's view
// is only the bar's size, and against it the bar would show the top of the
// picture).
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
    slice.bht_reference = nil;
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

// Now and once X is done with this pass.
static void RefreshTabBarWallpaper(UIViewController* tabBarController) {
    if (!BarsOn) {
        return;
    }
    [WeakSet(&SeenTabBarControllersStorage) addObject:tabBarController];
    AttachTabBarWallpaper(tabBarController);
    __weak UIViewController* weakController = tabBarController;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController* controller = weakController;
        if (controller && BarsOn) {
            AttachTabBarWallpaper(controller);
        }
    });
}

static void RemoveTabBarWallpapers(void) {
    for (UIView* background in WeakSet(&TabBarBackgroundsStorage).allObjects) {
        [objc_getAssociatedObject(background, TabBarWallpaperKey) removeFromSuperview];
    }
    [WeakSet(&TabBarBackgroundsStorage) removeAllObjects];
}

// MARK: - Sidebar

static void ReapplyWallpaper(void);

// X's split controller (the sidebar and the main content) and the sidebar's
// view, recorded as they lay out.
static __weak UIViewController* AppSplit;
static __weak UIView* SidebarView;
// The sidebar view whose alpha was changed, to put back.
static __weak UIView* FadedSidebar;
static BOOL OpenPercentIsHundredths;

// The backs and parts stay at the bottom of their views as the app's
// containers lay out and the content slides for the sidebar.
static void KeepMainBackInPlace(UIWindow* window) {
    if (BarsOn) {
        RealignPieces(window);
    }
}

static BOOL IsInsideSidebar(UIView* view) {
    UIView* sidebar = SidebarView;
    return sidebar && [view isDescendantOfView:sidebar];
}

// The sidebar, while it's on screen.
static UIView* SidebarViewForLayers(void) {
    UIView* sidebar = SidebarView;
    return sidebar.window ? sidebar : nil;
}

static BOOL HoldsMainApp(UIView* view) {
    UIView* split = AppSplit.viewIfLoaded;
    return split && [split isDescendantOfView:view];
}

static UIView* SidebarOf(UIViewController* split) {
    UIViewController* dash = BHTSafeObject(split, @selector(dashViewController));
    UIView* view = [dash isKindOfClass:UIViewController.class] ? dash.viewIfLoaded : nil;
    return view ?: SidebarView;
}

// How far the sidebar is open, 0 to 1: what X reports, or how far the
// content has slid aside for it, whichever is further (so the sidebar is
// never left hidden while open).
static CGFloat SidebarOpenFraction(UIViewController* split, UIView* sidebar) {
    CGFloat fraction = 0;
    SEL getter = @selector(dashPanelOpenPercent);
    if ([split respondsToSelector:getter]) {
        double percent = ((double (*)(id, SEL))objc_msgSend)(split, getter);
        if (!isnan(percent)) {
            // Taken as 0 to 1; a value well past 1 means X counts to 100.
            if (percent > 1.5) {
                OpenPercentIsHundredths = YES;
            }
            if (OpenPercentIsHundredths) {
                percent /= 100.0;
            }
            fraction = MAX(0.0, MIN(1.0, percent));
        }
    }
    UIView* content = objectIvar(split, "_contentHostView");
    UIView* splitView = split.viewIfLoaded;
    CGFloat width = sidebar.bounds.size.width;
    if ([content isKindOfClass:UIView.class] && splitView && content.window == splitView.window && width > 1) {
        CGFloat moved = fabs([content convertPoint:CGPointZero toView:splitView].x);
        fraction = MAX(fraction, MIN(1.0, moved / width));
    }
    return fraction;
}

// On a phone the content covers the waiting sidebar; a sidebar always beside
// the content (a wide screen) is left alone.
static BOOL SidebarWaitsBehindContent(UIViewController* split, UIView* sidebar) {
    UIView* content = objectIvar(split, "_contentHostView");
    if (![content isKindOfClass:UIView.class] || content.window != sidebar.window) {
        return YES;
    }
    CGRect sidebarFrame = [sidebar convertRect:sidebar.bounds toView:nil];
    CGRect contentFrame = [content convertRect:content.bounds toView:nil];
    return CGRectIntersectsRect(CGRectInset(sidebarFrame, 1, 1), contentFrame);
}

static void SetSidebarAlpha(UIViewController* split, UIView* sidebar, CGFloat alpha) {
    if (fabs(sidebar.alpha - alpha) < 0.005) {
        return;
    }
    // Inside X's own animation of the slide: the fade runs with it.
    if ([UIView inheritedAnimationDuration] > 0) {
        sidebar.alpha = alpha;
        return;
    }
    UIViewPropertyAnimator* animator = BHTSafeObject(split, @selector(dashContentOffsetAnimator));
    if ([animator isKindOfClass:UIViewPropertyAnimator.class] && animator.state == UIViewAnimatingStateActive &&
        animator.isRunning) {
        [animator addAnimations:^{
            sidebar.alpha = alpha;
        }];
        return;
    }
    // X's spring moves the content a step at a time: the fade follows step by step.
    [UIView performWithoutAnimation:^{
        sidebar.alpha = alpha;
    }];
}

// X darkens the content (and the sidebar) with an overlay as the sidebar
// opens. Over the wallpaper that's a dark veil, so in "every screen" mode the
// overlay's color is made clear; the overlay itself stays (it takes the tap
// that closes the sidebar). Its color is put back when the mode is off.
// Views made clear here, with their color kept to put back.
static NSHashTable* ClearedVeilsStorage;

static void ClearVeil(UIView* veil) {
    CGColorRef drawn = veil.layer.backgroundColor;
    if (!drawn || CGColorGetAlpha(drawn) < 0.01) {
        return;
    }
    if (!objc_getAssociatedObject(veil, OverlayBackgroundKey)) {
        UIColor* original = veil.backgroundColor ?: [UIColor colorWithCGColor:drawn];
        objc_setAssociatedObject(veil, OverlayBackgroundKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [WeakSet(&ClearedVeilsStorage) addObject:veil];
    veil.backgroundColor = UIColor.clearColor;
}

// An empty plain view painted dark (black, or the theme's dark background):
// a veil laid over the content, not part of it.
static BOOL IsDarkVeil(UIView* view) {
    if (view.subviews.count > 0 || [view isKindOfClass:UIImageView.class] ||
        [view isKindOfClass:BHTWallpaperView.class] || [view isKindOfClass:UIVisualEffectView.class]) {
        return NO;
    }
    CGColorRef drawn = view.layer.backgroundColor;
    if (!drawn || CGColorGetAlpha(drawn) < 0.01) {
        return NO;
    }
    CGFloat red = 1, green = 1, blue = 1, alpha = 0;
    if (![[UIColor colorWithCGColor:drawn] getRed:&red green:&green blue:&blue alpha:&alpha]) {
        return NO;
    }
    return red < 0.2 && green < 0.2 && blue < 0.2;
}

static void ClearSidebarOverlays(UIViewController* split) {
    if (!FullOn) {
        for (UIView* veil in WeakSet(&ClearedVeilsStorage).allObjects) {
            UIColor* original = objc_getAssociatedObject(veil, OverlayBackgroundKey);
            objc_setAssociatedObject(veil, OverlayBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (original) {
                veil.backgroundColor = original;
            }
        }
        [WeakSet(&ClearedVeilsStorage) removeAllObjects];
        return;
    }
    if (!split) {
        return;
    }
    NSMutableArray<UIView*>* parents = [NSMutableArray array];
    if (split.viewIfLoaded) {
        [parents addObject:split.viewIfLoaded];
    }
    for (NSString* name in @[@"_contentHostView", @"_dashHostView"]) {
        UIView* host = objectIvar(split, name.UTF8String);
        if (![host isKindOfClass:UIView.class]) {
            continue;
        }
        [parents addObject:host];
        UIView* overlay = BHTSafeObject(host, @selector(overlayView));
        if ([overlay isKindOfClass:UIView.class]) {
            ClearVeil(overlay);
        }
    }
    for (UIView* parent in parents) {
        for (UIView* view in parent.subviews) {
            if (IsDarkVeil(view)) {
                ClearVeil(view);
            }
        }
    }
}

// The sidebar's alpha follows how far it's open in "every screen" mode, so it
// isn't seen through the clear content while it waits.
static void UpdateSidebarFade(UIViewController* split) {
    ClearSidebarOverlays(split);
    UIView* sidebar = SidebarOf(split);
    if (FullOn && sidebar && IsAppWindow(sidebar.window) && SidebarWaitsBehindContent(split, sidebar)) {
        FadedSidebar = sidebar;
        SetSidebarAlpha(split, sidebar, SidebarOpenFraction(split, sidebar));
        return;
    }
    UIView* faded = FadedSidebar;
    if (faded) {
        FadedSidebar = nil;
        SetSidebarAlpha(split, faded, 1);
    }
}

static void SidebarMoved(UIViewController* split) {
    AppSplit = split;
    UpdateSidebarFade(split);
    KeepMainBackInPlace(split.viewIfLoaded.window);
}

// The shade X lays over the content's edge (and over it as the sidebar
// opens) stays off in "every screen" mode.
%group SplitHost
%hook T1AppSplitHostView

- (void)setShadowAlpha:(double)alpha {
    %orig(FullOn ? 0 : alpha);
}

%end
%end

%hook T1AppSplitViewController

- (void)viewDidLayoutSubviews {
    %orig;
    SidebarMoved((UIViewController*)self);
}

- (void)private_applyDashLayoutAndNotify {
    %orig;
    SidebarMoved((UIViewController*)self);
}

- (void)private_updateOverlayViews {
    %orig;
    SidebarMoved((UIViewController*)self);
}

- (void)tpx_animationDidUpdate:(id)animation {
    %orig;
    SidebarMoved((UIViewController*)self);
}

- (void)tpx_animationDidStop:(id)animation {
    %orig;
    SidebarMoved((UIViewController*)self);
}

- (void)private_notifyDashDidSettleOpen:(BOOL)open {
    %orig;
    SidebarMoved((UIViewController*)self);
    // X restyles the content as the sidebar settles: a full pass once it's done.
    if (FullOn) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ReapplyWallpaper();
        });
    }
}

%end

// The sidebar's view.
%hook _TtC11TwitterDash21DashHostingController

- (void)viewDidLayoutSubviews {
    %orig;
    SidebarView = ((UIViewController*)self).viewIfLoaded;
}

%end

%hook TFNNavigationBar

- (void)layoutSubviews {
    %orig;
    if (NavigationBarWantsWallpaper((UINavigationBar*)self)) {
        PaintNavigationBar((UINavigationBar*)self, NO);
        // What X painted while laying the header out, in the same frame.
        ProcessThemedViews(NO);
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
    KeepMainBackInPlace(((UIViewController*)self).viewIfLoaded.window);
}

// X rebuilds the bar's background when the look changes (the app coming back
// from the background, where iOS flips the look for its snapshots).
- (void)_t1_updateBackground {
    %orig;
    RefreshTabBarWallpaper((UIViewController*)self);
}

- (void)traitCollectionDidChange:(UITraitCollection*)previousTraitCollection {
    %orig;
    RefreshTabBarWallpaper((UIViewController*)self);
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

// Everything the options ask for, applied over what's there.
static void ReapplyWallpaper(void) {
    UpdateSidebarFade(AppSplit);
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

static void ApplyWallpaperChange(void) {
    ReadWallpaperOptions();
    Generation++;
    // Start over, then add what the options ask for.
    RestoreEverything();
    ReapplyWallpaper();
}

// X restyles the app as it comes back from the background (iOS flips the
// look for its snapshots there): everything is applied again, now and once
// X is done.
static void ReapplyAfterForeground(void) {
    if (!WallpaperOn) {
        return;
    }
    ReapplyWallpaper();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ReapplyWallpaper();
    });
}

// MARK: - Following X's colors

// X reloaded its colors: everything again, before the frame is drawn.
static BOOL FullPassPending;

static void ThemeReloaded(void) {
    ForgetThemeColor();
    if (WallpaperOn) {
        FullPassPending = YES;
    }
}

// The view holding the tab bar's own picture, when `view` is part of the tab
// bar (the tab bar controller's view, only the bar's size).
static UIView* TabBarHostHolding(UIView* view) {
    for (UIViewController* controller in WeakSet(&SeenTabBarControllersStorage).allObjects) {
        UIView* background = TabBarBackground(controller);
        UIView* bar = controller.viewIfLoaded;
        if (!background || !bar) {
            continue;
        }
        UIView* host = [background isKindOfClass:UIVisualEffectView.class]
                           ? ((UIVisualEffectView*)background).contentView
                           : background;
        BOOL barSized = bar.window && bar.bounds.size.height <= bar.window.bounds.size.height * 0.25;
        if ((barSized && [view isDescendantOfView:bar]) || [view isDescendantOfView:background]) {
            return host;
        }
    }
    return nil;
}

// One view X just painted in the theme color, handled as the full passes
// would: a part of the picture in the header, the tab strips and short
// translucent bars; clear elsewhere in "every screen" mode, and inside
// cells of lists showing the picture.
static void ApplyToThemedView(UIView* view) {
    UIWindow* window = view.window;
    if (!window) {
        // Painted before going on screen (a tab's header coming back): handled
        // as it comes on screen, before it's drawn.
        [WeakSet(&OffscreenThemedViewsStorage) addObject:view];
        OffscreenThemedViewsPending = YES;
        return;
    }
    if (!IsAppWindow(window) || [view isKindOfClass:BHTWallpaperView.class] || IsInsideCustomBlur(view) ||
        IsInsideSeeThroughPresentation(view)) {
        return;
    }
    UIColor* color = EffectiveBackgroundColor(view);
    if (!ColorMatchesTheme(color, view, 0.5)) {
        return;
    }
    // Its own part of the picture already covers its color.
    if (PieceLayer(view, NO).superlayer == view.layer) {
        AlignPiece(view);
        return;
    }
    // The tab bar: views over its picture are made clear; the bar's own
    // views below the picture keep their color.
    UIView* tabBarHost = TabBarHostHolding(view);
    if (tabBarHost) {
        if (view != tabBarHost && [view isDescendantOfView:tabBarHost]) {
            for (UIView* ancestor = view; ancestor && ancestor != tabBarHost; ancestor = ancestor.superview) {
                if ([ancestor isKindOfClass:BHTWallpaperView.class]) {
                    return;
                }
            }
            ClearThemeColor(view, 0.5);
        }
        return;
    }
    for (UIView* ancestor = view; ancestor && ancestor != window; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:BHTWallpaperView.class]) {
            return;
        }
        // Inside a list that keeps its own color, nothing changes.
        if (ancestor != view && IsList(ancestor) && !IsHostList((UIScrollView*)ancestor) &&
            !ListHasWallpaper((UIScrollView*)ancestor)) {
            return;
        }
        if (IsTabStrip(ancestor)) {
            PaintStrip(ancestor, YES);
            return;
        }
        if ([ancestor isKindOfClass:UINavigationBar.class]) {
            if (NavigationBarWantsWallpaper((UINavigationBar*)ancestor) && CanPaint(view, 0.5) &&
                FitsInBar(view, (UINavigationBar*)ancestor)) {
                PaintPiece(view);
            }
            return;
        }
        if (ancestor != view &&
            ([ancestor isKindOfClass:UITableViewCell.class] || [ancestor isKindOfClass:UICollectionViewCell.class])) {
            UIView* list = ancestor.superview;
            while (list && !IsList(list)) {
                list = list.superview;
            }
            if (list && (IsHostList((UIScrollView*)list) || ListHasWallpaper((UIScrollView*)list))) {
                ClearThemeBackground(view);
            }
            return;
        }
    }
    if (!FullOn) {
        return;
    }
    if (IsList(view)) {
        MakeListClear((UIScrollView*)view);
        return;
    }
    // A short bar: the strip it holds, or its own part when it's slightly
    // translucent (content passes under it).
    if (view.bounds.size.height <= window.bounds.size.height * 0.25) {
        NSArray<UIView*>* strips = StripsIn(view, 30);
        if (strips.count) {
            for (UIView* strip in strips) {
                PaintStrip(strip, YES);
            }
            return;
        }
        if (!ColorIsThemeBackground(color, view)) {
            if (CanPaint(view, 0.5)) {
                PaintPiece(view);
            }
            return;
        }
    }
    if (ClearThemeBackground(view)) {
        EnsureBack(view);
    }
}

// Runs right before Core Animation draws each frame (and as screens lay
// out), so whatever X painted in the theme color in this pass, its color
// reloads included, is handled before it's ever seen. The full pass after a
// color reload only runs before drawing, not in the middle of a layout.
static void ProcessThemedViews(BOOL beforeDrawing) {
    if (beforeDrawing && FullPassPending) {
        FullPassPending = NO;
        ReapplyWallpaper();
    }
    if (!ThemedViewsPending) {
        return;
    }
    ThemedViewsPending = NO;
    NSArray<UIView*>* views = WeakSet(&ThemedViewsStorage).allObjects;
    [WeakSet(&ThemedViewsStorage) removeAllObjects];
    if (!BarsOn) {
        return;
    }
    for (UIView* view in views) {
        ApplyToThemedView(view);
    }
}

%group ColorReloads
%hook TFNDynamicColorManager

- (void)reloadDynamicColors {
    %orig;
    ThemeReloaded();
}

%end
%end

%group PaletteChanges
%hook TAEColorSettings

- (void)applyCurrentColorPalette {
    %orig;
    ThemeReloaded();
}

%end
%end

%hook TFNItemsDataViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [WeakSet(&SeenControllersStorage) addObject:(UIViewController*)self];
    if (WallpaperOn) {
        ApplyWallpaperToController((UIViewController*)self);
        ApplyBarWallpaperForController((UIViewController*)self);
        ScheduleSettlePass((UIViewController*)self);
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
    if (objc_getClass("_TtC10TFNUISwift29SegmentedTabsBarContainerView")) {
        %init(StripContainer);
    }
    if (objc_getClass("TFNDynamicColorManager")) {
        %init(ColorReloads);
    }
    if (objc_getClass("TFNNavigationController")) {
        %init(TFNTransitions);
    }
    if (objc_getClass("TFNNavigationControllerTransitionAnimator")) {
        %init(TFNOverlay);
    }
    if (objc_getClass("T1AppSplitHostView")) {
        %init(SplitHost);
    }
    if (objc_getClass("TAEColorSettings")) {
        %init(PaletteChanges);
    }
    ReadWallpaperOptions();

    // After UIKit's own before-commit work (1999000) and before Core
    // Animation commits the frame (2000000).
    CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, true, 1999500,
        ^(CFRunLoopObserverRef runLoopObserver, CFRunLoopActivity activity) {
            SettleTransitions();
            ProcessThemedViews(YES);
        });
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    CFRelease(observer);
    [NSNotificationCenter.defaultCenter addObserverForName:BHTWatermarkDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* notification) {
                                                    ApplyWallpaperChange();
                                                }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* notification) {
                                                    ReapplyAfterForeground();
                                                }];
}

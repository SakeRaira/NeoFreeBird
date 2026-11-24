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
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_imageView];
    }
    return self;
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

static void ClearThemeBackground(UIView* view) {
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
    [WeakSet(&ClearedViewsStorage) addObject:view];
    if (layerOnly) {
        view.layer.backgroundColor = UIColor.clearColor.CGColor;
    } else {
        view.backgroundColor = UIColor.clearColor;
    }
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

// Full timelines inside a tab, not small embedded lists such as carousels.
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

// MARK: - Applying

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
    PrepareVisibleCells(list);
}

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

static void ApplyWallpaperChange(void) {
    WallpaperOn = BHTWatermark.active;
    if (!WallpaperOn) {
        RestoreEverything();
        return;
    }
    for (UIViewController* controller in WeakSet(&SeenControllersStorage).allObjects) {
        ApplyWallpaperToController(controller);
    }
}

%hook TFNItemsDataViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [WeakSet(&SeenControllersStorage) addObject:(UIViewController*)self];
    if (WallpaperOn) {
        ApplyWallpaperToController((UIViewController*)self);
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
    WallpaperOn = BHTWatermark.active;
    [NSNotificationCenter.defaultCenter addObserverForName:BHTWatermarkDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* notification) {
                                                    ApplyWallpaperChange();
                                                }];
}

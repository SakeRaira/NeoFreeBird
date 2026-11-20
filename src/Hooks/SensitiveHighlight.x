//
//  SensitiveHighlight.x
//  NeoFreeBird
//
//  Tints the background of tweets that carry X's "possibly sensitive" flag a
//  light red, so they stand out even when the sensitive content warnings are
//  turned off.
//

#import <QuartzCore/QuartzCore.h>
#import "HookHelpers.h"

static NSString* const kHighlightSensitiveTweetsKey = @"highlight_sensitive_tweets";
static NSString* const kHighlightSensitiveTweetsDebugKey = @"highlight_sensitive_tweets_debug";
static const void* SensitiveHighlightLayerKey = &SensitiveHighlightLayerKey;
static const void* SensitiveDebugMarkerKey = &SensitiveDebugMarkerKey;

typedef NS_ENUM(NSInteger, BHTSensitiveVerdict) {
    // The cell had no status view or view model to inspect.
    BHTSensitiveVerdictUnknown,
    BHTSensitiveVerdictNotSensitive,
    BHTSensitiveVerdictSensitive,
};

// Every status cell that has been laid out, so toggling a setting can restyle
// the cells on screen without walking the whole view tree.
static NSHashTable<T1StatusCell*>* TrackedStatusCells(void) {
    static NSHashTable* cells;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cells = [NSHashTable weakObjectsHashTable];
    });
    return cells;
}

// Translucent so the theme's own background still reads through. Dark mode
// lands on the same dark maroon over Dim's navy as the reference design;
// light mode is a pale pink over white.
static UIColor* SensitiveHighlightColor(void) {
    static UIColor* color;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        color = [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
            if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
                return [UIColor colorWithRed:68.0 / 255.0
                                       green:17.0 / 255.0
                                        blue:0.0
                                       alpha:0.43];
            }
            return [UIColor colorWithRed:1.0
                                   green:59.0 / 255.0
                                    blue:48.0 / 255.0
                                   alpha:0.10];
        }];
    });
    return color;
}

// The return type of a real (not forwarded) zero-argument method, or 0. The
// detection probes selectors like -status across unrelated classes, and one
// returning a scalar must never be called as if it returned an object.
static char ReturnTypeForSelector(id object, SEL selector) {
    if (!object) {
        return 0;
    }

    Method method = class_getInstanceMethod(object_getClass(object), selector);
    const char* encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding ? encoding[0] : 0;
}

static id ObjectForSelectorIfResponds(id object, SEL selector) {
    if (ReturnTypeForSelector(object, selector) != '@') {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL BoolForSelectorIfResponds(id object, SEL selector) {
    char returnType = ReturnTypeForSelector(object, selector);
    if (returnType != 'B' && returnType != 'c') {
        return NO;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

// MARK: - Detection

// Media the server attached a sensitive media warning to (adult content,
// graphic violence, ...), whoever flagged it.
static BOOL ObjectHasSensitiveMedia(id object) {
    id entities = ObjectForSelectorIfResponds(object, @selector(entities));
    NSArray* media = ObjectForSelectorIfResponds(entities, @selector(media));
    if (![media isKindOfClass:NSArray.class]) {
        return NO;
    }

    for (id item in media) {
        if (ObjectForSelectorIfResponds(item, @selector(sensitiveMediaWarning))) {
            return YES;
        }
    }
    return NO;
}

// isPossiblySensitive is the raw server flag. The "no sensitive content
// warnings" option only overrides the warning-level checks
// (isPossiblySensitiveViewModelForAccount:, the image interstitials), so these
// keep reporting the server's verdict with warnings turned off.
static BOOL ObjectCarriesSensitiveFlag(id object) {
    return BoolForSelectorIfResponds(object, @selector(isPossiblySensitive)) ||
           BoolForSelectorIfResponds(object, @selector(hasSensitiveMediaWarningsFlaggedByAuthor)) ||
           ObjectHasSensitiveMedia(object);
}

// Status views hold a view model that may be a TFNTwitterStatus or a Swift
// adapter wrapping one (T1TwitterCoreStatusViewModelAdapter in 12.45), so
// check the view model and everything it links to. Retweets are wrappers, so
// the retweeted original counts; quoted tweets deliberately do not.
static BOOL ViewModelIsFlaggedSensitive(id viewModel) {
    static NSArray<NSString*>* links;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        links = @[@"statusViewModel", @"tweet", @"status", @"representedStatus",
                  @"retweetedStatus", @"canonicalStatus"];
    });

    NSHashTable* seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSMutableArray* queue = [NSMutableArray arrayWithObject:viewModel];
    [seen addObject:viewModel];

    for (NSUInteger i = 0; i < queue.count && i < 16; i++) {
        id object = queue[i];
        if (ObjectCarriesSensitiveFlag(object)) {
            return YES;
        }

        for (NSString* name in links) {
            id linked = ObjectForSelectorIfResponds(object, NSSelectorFromString(name));
            if (linked && ![seen containsObject:linked]) {
                [seen addObject:linked];
                [queue addObject:linked];
            }
        }
    }

    return NO;
}

static UIView* StatusViewForCell(T1StatusCell* cell) {
    return [cell respondsToSelector:@selector(statusView)] ? cell.statusView : nil;
}

static BHTSensitiveVerdict VerdictForStatusView(UIView* statusView) {
    id viewModel = ObjectForSelectorIfResponds(statusView, @selector(viewModel));
    if (!viewModel) {
        return BHTSensitiveVerdictUnknown;
    }
    return ViewModelIsFlaggedSensitive(viewModel) ? BHTSensitiveVerdictSensitive
                                                  : BHTSensitiveVerdictNotSensitive;
}

// MARK: - Drawing

static BOOL ViewPaintsOwnBackground(UIView* view) {
    UIColor* color = view.backgroundColor;
    if (color && CGColorGetAlpha(color.CGColor) > 0.01) {
        return YES;
    }

    CGColorRef layerColor = view.layer.backgroundColor;
    if (layerColor && CGColorGetAlpha(layerColor) > 0.01) {
        return YES;
    }

    // Custom drawing can fill the whole view without any background color.
    return [view.class instanceMethodForSelector:@selector(drawRect:)] !=
           [UIView instanceMethodForSelector:@selector(drawRect:)];
}

static CALayer* SensitiveHighlightLayer(T1StatusCell* cell, BOOL createIfNeeded) {
    CALayer* layer = objc_getAssociatedObject(cell, SensitiveHighlightLayerKey);
    if (layer || !createIfNeeded) {
        return layer;
    }

    layer = [CALayer layer];
    layer.name = @"BHTSensitiveHighlight";
    // No implicit fades when cells are reused or resized while scrolling.
    layer.actions = @{
        @"bounds": NSNull.null,
        @"position": NSNull.null,
        @"backgroundColor": NSNull.null,
        @"hidden": NSNull.null,
        @"sublayers": NSNull.null,
        @"onOrderIn": NSNull.null,
        @"onOrderOut": NSNull.null,
    };
    layer.hidden = YES;
    objc_setAssociatedObject(cell, SensitiveHighlightLayerKey, layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return layer;
}

// The tint has to sit above whatever paints the row's background and below
// the tweet's content. Backgrounds can be painted by the status view itself or
// by a view behind it (the cell, its content view, a solid color sibling), so:
// when the status view paints its own background the tint goes at the bottom
// of the status view's layer, otherwise directly beneath the status view.
static void PlaceHighlightLayer(CALayer* layer, T1StatusCell* cell, UIView* statusView) {
    CALayer* hostLayer;
    CALayer* referenceLayer = nil;
    CGRect frame;

    if (!statusView) {
        hostLayer = cell.contentView.layer;
        frame = cell.contentView.bounds;
    } else if (ViewPaintsOwnBackground(statusView) || !statusView.superview) {
        hostLayer = statusView.layer;
        frame = statusView.bounds;
    } else {
        hostLayer = statusView.superview.layer;
        referenceLayer = statusView.layer;
        frame = statusView.superview.bounds;
    }

    BOOL placed = NO;
    if (layer.superlayer == hostLayer) {
        NSArray<CALayer*>* siblings = hostLayer.sublayers;
        NSUInteger index = [siblings indexOfObjectIdenticalTo:layer];
        if (referenceLayer) {
            NSUInteger referenceIndex = [siblings indexOfObjectIdenticalTo:referenceLayer];
            placed = referenceIndex != NSNotFound && index + 1 == referenceIndex;
        } else {
            placed = index == 0;
        }
    }

    if (!placed) {
        [layer removeFromSuperlayer];
        if (referenceLayer) {
            [hostLayer insertSublayer:layer below:referenceLayer];
        } else {
            [hostLayer insertSublayer:layer atIndex:0];
        }
    }

    layer.frame = frame;
}

static void UpdateHighlightLayer(T1StatusCell* cell, UIView* statusView, BOOL show) {
    CALayer* layer = SensitiveHighlightLayer(cell, show);
    if (!layer) {
        return;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.hidden = !show;
    if (show) {
        PlaceHighlightLayer(layer, cell, statusView);
        layer.backgroundColor =
            [SensitiveHighlightColor() resolvedColorWithTraitCollection:cell.traitCollection].CGColor;
    }
    [CATransaction commit];
}

// Debug aid: a strip on the leading edge of every tweet showing what the
// detection decided. Red is sensitive, green is not, yellow means there was
// nothing to inspect. No strip at all means the cell never reached this file.
static void UpdateDebugMarker(T1StatusCell* cell, BOOL show, BHTSensitiveVerdict verdict) {
    UIView* marker = objc_getAssociatedObject(cell, SensitiveDebugMarkerKey);
    if (!show) {
        marker.hidden = YES;
        return;
    }

    if (!marker) {
        marker = [[UIView alloc] init];
        marker.userInteractionEnabled = NO;
        objc_setAssociatedObject(cell, SensitiveDebugMarkerKey, marker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIView* container = cell.contentView;
    if (marker.superview != container) {
        [container addSubview:marker];
    } else if (container.subviews.lastObject != marker) {
        [container bringSubviewToFront:marker];
    }

    switch (verdict) {
        case BHTSensitiveVerdictSensitive:
            marker.backgroundColor = UIColor.systemRedColor;
            break;
        case BHTSensitiveVerdictNotSensitive:
            marker.backgroundColor = UIColor.systemGreenColor;
            break;
        case BHTSensitiveVerdictUnknown:
            marker.backgroundColor = UIColor.systemYellowColor;
            break;
    }
    marker.frame = CGRectMake(0, 0, 6, container.bounds.size.height);
    marker.hidden = NO;
}

static void UpdateSensitiveHighlight(T1StatusCell* cell) {
    if (!cell) {
        return;
    }

    [TrackedStatusCells() addObject:cell];

    BOOL enabled = [BHTSettings boolForKey:kHighlightSensitiveTweetsKey];
    BOOL debug = [BHTSettings boolForKey:kHighlightSensitiveTweetsDebugKey];
    UIView* statusView = StatusViewForCell(cell);
    BHTSensitiveVerdict verdict = (enabled || debug) ? VerdictForStatusView(statusView)
                                                     : BHTSensitiveVerdictUnknown;

    UpdateHighlightLayer(cell, statusView, enabled && verdict == BHTSensitiveVerdictSensitive);
    UpdateDebugMarker(cell, debug, verdict);
}

// Quoted tweets bring status views of their own inside the cell; only the
// cell's own status view decides how the cell looks.
static void UpdateSensitiveHighlightForStatusView(UIView* statusView) {
    Class cellClass = objc_getClass("T1StatusCell");
    for (UIView* view = statusView.superview; view; view = view.superview) {
        if (![view isKindOfClass:cellClass]) {
            continue;
        }

        T1StatusCell* cell = (T1StatusCell*)view;
        if (StatusViewForCell(cell) == statusView) {
            UpdateSensitiveHighlight(cell);
        }
        return;
    }
}

void applySensitiveHighlightSetting(void) {
    for (T1StatusCell* cell in TrackedStatusCells().allObjects) {
        UpdateSensitiveHighlight(cell);
    }
}

%hook T1StatusCell

- (void)prepareForReuse {
    %orig;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    SensitiveHighlightLayer(self, NO).hidden = YES;
    [CATransaction commit];
}

- (void)layoutSubviews {
    %orig;
    UpdateSensitiveHighlight(self);
}

%end

%hook T1StandardStatusView

- (void)setViewModel:(id)viewModel options:(unsigned long long)options account:(id)account {
    %orig;
    UpdateSensitiveHighlightForStatusView(self);
}

%end

%hook T1ConversationFocalStatusView

- (void)setViewModel:(id)viewModel options:(unsigned long long)options account:(id)account {
    %orig;
    UpdateSensitiveHighlightForStatusView(self);
}

%end

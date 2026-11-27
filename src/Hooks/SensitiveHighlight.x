//
//  SensitiveHighlight.x
//  NeoFreeBird
//
//  Tints the background of tweets that carry X's "possibly sensitive" flag,
//  colored by the kind of sensitive media warning they carry, so they stand
//  out even when the sensitive content warnings are turned off.
//

#import <QuartzCore/QuartzCore.h>
#import "HookHelpers.h"

static NSString* const kHighlightSensitiveTweetsKey = @"highlight_sensitive_tweets";
static NSString* const kHighlightSensitiveTweetsDebugKey = @"highlight_sensitive_tweets_debug";
static const void* SensitiveHighlightLayerKey = &SensitiveHighlightLayerKey;
static const void* SensitiveDebugMarkerKey = &SensitiveDebugMarkerKey;

typedef NS_OPTIONS(NSUInteger, BHTSensitiveFlags) {
    BHTSensitiveFlagged = 1 << 0,
    BHTSensitiveAdultContent = 1 << 1,
    BHTSensitiveGraphicViolence = 1 << 2,
    BHTSensitiveOther = 1 << 3,
};

typedef NS_ENUM(NSInteger, BHTSensitiveVerdict) {
    // The cell had no status view or view model to inspect.
    BHTSensitiveVerdictUnknown,
    BHTSensitiveVerdictNotSensitive,
    // Flagged, but no media warning says what kind of content it is.
    BHTSensitiveVerdictUnspecified,
    BHTSensitiveVerdictAdultContent,
    BHTSensitiveVerdictGraphicViolence,
    BHTSensitiveVerdictOther,
};

static BOOL VerdictIsSensitive(BHTSensitiveVerdict verdict) {
    return verdict >= BHTSensitiveVerdictUnspecified;
}

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

// MARK: - Colors

static UIColor* TintRGBA(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha) {
    return [UIColor colorWithRed:red / 255.0 green:green / 255.0 blue:blue / 255.0 alpha:alpha];
}

static UIColor* DynamicTint(UIColor* dark, UIColor* light) {
    return [UIColor colorWithDynamicProvider:^UIColor*(UITraitCollection* traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
}

// Translucent so the theme's own background still reads through. The dark
// tints are 43% over the background: unspecified lands on the dark maroon of
// the reference design over Dim's navy, and the others on a magenta, a violet
// and a brown-orange of similar brightness. The light tints are the hue at low
// opacity over white.
static UIColor* HighlightColorForVerdict(BHTSensitiveVerdict verdict) {
    static NSDictionary<NSNumber*, UIColor*>* colors;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colors = @{
            @(BHTSensitiveVerdictUnspecified): DynamicTint(TintRGBA(68, 17, 0, 0.43), TintRGBA(255, 59, 48, 0.10)),
            @(BHTSensitiveVerdictAdultContent): DynamicTint(TintRGBA(93, 14, 41, 0.43), TintRGBA(255, 45, 146, 0.12)),
            @(BHTSensitiveVerdictGraphicViolence): DynamicTint(TintRGBA(65, 19, 87, 0.43), TintRGBA(175, 82, 222, 0.12)),
            @(BHTSensitiveVerdictOther): DynamicTint(TintRGBA(88, 41, 0, 0.43), TintRGBA(255, 149, 0, 0.14)),
        };
    });
    return colors[@(verdict)];
}

// MARK: - Safe selector probing

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

static BOOL ReturnTypeIsBool(char returnType) {
    return returnType == 'B' || returnType == 'c';
}

static id ObjectForSelectorIfResponds(id object, SEL selector) {
    if (ReturnTypeForSelector(object, selector) != '@') {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL BoolForSelectorIfResponds(id object, SEL selector) {
    if (!ReturnTypeIsBool(ReturnTypeForSelector(object, selector))) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

// MARK: - Detection

// TFSTwitterSensitiveMediaWarning. Its only ObjC-visible member is
// -hasAnyWarning, and it can exist with every category off. The categories
// are plain Swift stored properties without ObjC getters, so they're read
// from the ivars; if a future X renames them the warning still counts, just
// without a category.
static BHTSensitiveFlags FlagsForMediaWarning(id warning) {
    if (!warning) {
        return 0;
    }

    if (ReturnTypeIsBool(ReturnTypeForSelector(warning, @selector(hasAnyWarning))) &&
        !BoolForSelectorIfResponds(warning, @selector(hasAnyWarning))) {
        return 0;
    }

    BHTSensitiveFlags flags = BHTSensitiveFlagged;
    if (boolIvar(warning, "adultContent", NO)) {
        flags |= BHTSensitiveAdultContent;
    }
    if (boolIvar(warning, "graphicViolence", NO)) {
        flags |= BHTSensitiveGraphicViolence;
    }
    if (boolIvar(warning, "other", NO)) {
        flags |= BHTSensitiveOther;
    }
    return flags;
}

// isPossiblySensitive is the raw server flag. The "no sensitive content
// warnings" option only overrides the warning-level checks
// (isPossiblySensitiveViewModelForAccount:, the image interstitials), so these
// keep reporting the server's verdict with warnings turned off.
static BHTSensitiveFlags FlagsForObject(id object) {
    BHTSensitiveFlags flags = 0;
    if (BoolForSelectorIfResponds(object, @selector(isPossiblySensitive)) ||
        BoolForSelectorIfResponds(object, @selector(hasSensitiveMediaWarningsFlaggedByAuthor))) {
        flags |= BHTSensitiveFlagged;
    }

    id entities = ObjectForSelectorIfResponds(object, @selector(entities));
    NSArray* media = ObjectForSelectorIfResponds(entities, @selector(media));
    if ([media isKindOfClass:NSArray.class]) {
        for (id item in media) {
            flags |= FlagsForMediaWarning(ObjectForSelectorIfResponds(item, @selector(sensitiveMediaWarning)));
        }
    }

    return flags;
}

// The view model and everything it links to: it may be a TFNTwitterStatus or
// a Swift adapter wrapping one (T1TwitterCoreStatusViewModelAdapter in
// 12.45), sometimes two deep. Quoted tweets are deliberately not followed.
static NSArray* ObjectsLinkedFrom(id root) {
    static NSArray<NSString*>* links;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        links = @[@"statusViewModel", @"tweet", @"status", @"representedStatus",
                  @"retweetedStatus", @"canonicalStatus"];
    });

    NSHashTable* seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSMutableArray* queue = [NSMutableArray arrayWithObject:root];
    [seen addObject:root];

    for (NSUInteger i = 0; i < queue.count && i < 16; i++) {
        for (NSString* name in links) {
            id linked = ObjectForSelectorIfResponds(queue[i], NSSelectorFromString(name));
            if (linked && ![seen containsObject:linked]) {
                [seen addObject:linked];
                [queue addObject:linked];
            }
        }
    }
    return queue;
}

// For a retweet, the post that was retweeted: the retweet itself is a
// wrapper carrying the retweeter's own flag (set for their whole account when
// it's restricted, for instance), which says nothing about the post shown.
static id RetweetedOriginal(NSArray* objects) {
    BOOL isRetweet = NO;
    for (id object in objects) {
        id original = ObjectForSelectorIfResponds(object, @selector(retweetedStatus));
        if (original && original != object) {
            return original;
        }
        isRetweet = isRetweet || BoolForSelectorIfResponds(object, @selector(isRetweet));
    }
    if (!isRetweet) {
        return nil;
    }

    // Adapters answer representedStatus with the original's view model.
    for (id object in objects) {
        if (!BoolForSelectorIfResponds(object, @selector(isRetweet))) {
            continue;
        }
        id represented = ObjectForSelectorIfResponds(object, @selector(representedStatus));
        if (represented && represented != object) {
            return represented;
        }
    }
    return nil;
}

// X's own warning laid over a post's media: the interstitial the server
// sends with it ("Content warning: Adult content", "... labeled by X"),
// which can come without any of the flags above. It has no category of its
// own, so the kind is read from its title where it says one.
static BHTSensitiveFlags FlagsForInterstitial(id object) {
    id interstitial = ObjectForSelectorIfResponds(object, @selector(imageInterstitial));
    BOOL present = BoolForSelectorIfResponds(object, @selector(hasImageInterstitial));
    if (interstitial) {
        char returnType = ReturnTypeForSelector(interstitial, @selector(hasImageInterstitial));
        present = present || !ReturnTypeIsBool(returnType) ||
                  BoolForSelectorIfResponds(interstitial, @selector(hasImageInterstitial));
    }
    if (!present) {
        return 0;
    }

    BHTSensitiveFlags flags = BHTSensitiveFlagged;
    id title = ObjectForSelectorIfResponds(interstitial, @selector(title));
    NSString* text = [title isKindOfClass:NSString.class] ? title : ObjectForSelectorIfResponds(title, @selector(text));
    if ([text isKindOfClass:NSString.class]) {
        NSString* lower = text.lowercaseString;
        if ([lower containsString:@"成人"] || [lower containsString:@"adult"] || [lower containsString:@"nudity"]) {
            flags |= BHTSensitiveAdultContent;
        }
        if ([lower containsString:@"暴力"] || [lower containsString:@"violen"] || [lower containsString:@"gore"]) {
            flags |= BHTSensitiveGraphicViolence;
        }
    }
    return flags;
}

// Flags of the post a cell shows: for a retweet only the retweeted original
// and what it links to (its own marks: X may lay the retweeter's warning over
// it, which says nothing about the post), otherwise everything the view model
// links to, X's warning over the media included. Read as X says it, with
// warnings hidden or not.
static BHTSensitiveFlags FlagsForViewModel(id viewModel) {
    BOOL wasReading = BHTReadingRawSensitivity;
    BHTReadingRawSensitivity = YES;
    NSArray* objects = ObjectsLinkedFrom(viewModel);
    id original = RetweetedOriginal(objects);
    if (original) {
        objects = ObjectsLinkedFrom(original);
    }

    BHTSensitiveFlags flags = 0;
    for (id object in objects) {
        flags |= FlagsForObject(object);
        if (!original) {
            flags |= FlagsForInterstitial(object);
        }
    }
    BHTReadingRawSensitivity = wasReading;
    return flags;
}

// The author of any of `objects` with X's sensitive-media profile warning.
static BOOL AuthorIsMarked(NSArray* objects) {
    SEL typeSelector = @selector(profileInterstitialType);
    for (id object in objects) {
        id author = ObjectForSelectorIfResponds(object, @selector(fromUser));
        char returnType = ReturnTypeForSelector(author, typeSelector);
        if (returnType == 'q' || returnType == 'l' || returnType == 'i') {
            if (BHTIsSensitiveMediaInterstitialType(((long long (*)(id, SEL))objc_msgSend)(author, typeSelector))) {
                return YES;
            }
        }
    }
    return NO;
}

// For "Judge retweets by the original post" (SensitiveWarnings.x): the post
// a view model shows is a retweet, found the way the highlight finds it, and
// the retweeted original carries no mark of its own (its flags, its media's
// labels, its author's account).
BOOL BHTViewModelShowsRetweetOfUnflaggedPost(id viewModel) {
    if (!viewModel) {
        return NO;
    }
    id original = RetweetedOriginal(ObjectsLinkedFrom(viewModel));
    if (!original) {
        return NO;
    }
    NSArray* objects = ObjectsLinkedFrom(original);
    for (id object in objects) {
        if (FlagsForObject(object)) {
            return NO;
        }
    }
    return !AuthorIsMarked(objects);
}

// Several categories can apply at once; the most severe one picks the color.
static BHTSensitiveVerdict VerdictForFlags(BHTSensitiveFlags flags) {
    if (!(flags & BHTSensitiveFlagged)) {
        return BHTSensitiveVerdictNotSensitive;
    }
    if (flags & BHTSensitiveGraphicViolence) {
        return BHTSensitiveVerdictGraphicViolence;
    }
    if (flags & BHTSensitiveAdultContent) {
        return BHTSensitiveVerdictAdultContent;
    }
    if (flags & BHTSensitiveOther) {
        return BHTSensitiveVerdictOther;
    }
    return BHTSensitiveVerdictUnspecified;
}

static UIView* StatusViewForCell(T1StatusCell* cell) {
    return [cell respondsToSelector:@selector(statusView)] ? cell.statusView : nil;
}

static BHTSensitiveVerdict VerdictForStatusView(UIView* statusView) {
    id viewModel = ObjectForSelectorIfResponds(statusView, @selector(viewModel));
    if (!viewModel) {
        return BHTSensitiveVerdictUnknown;
    }
    return VerdictForFlags(FlagsForViewModel(viewModel));
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

// A nil color hides the highlight.
static void UpdateHighlightLayer(T1StatusCell* cell, UIView* statusView, UIColor* color) {
    CALayer* layer = SensitiveHighlightLayer(cell, color != nil);
    if (!layer) {
        return;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.hidden = color == nil;
    if (color) {
        PlaceHighlightLayer(layer, cell, statusView);
        layer.backgroundColor = [color resolvedColorWithTraitCollection:cell.traitCollection].CGColor;
    }
    [CATransaction commit];
}

// Debug aid: a strip on the leading edge of every tweet showing what the
// detection decided. Red is sensitive (any kind), green is not, yellow means
// there was nothing to inspect. No strip at all means the cell never reached
// this file.
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

    if (VerdictIsSensitive(verdict)) {
        marker.backgroundColor = UIColor.systemRedColor;
    } else if (verdict == BHTSensitiveVerdictNotSensitive) {
        marker.backgroundColor = UIColor.systemGreenColor;
    } else {
        marker.backgroundColor = UIColor.systemYellowColor;
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

    UpdateHighlightLayer(cell, statusView, enabled ? HighlightColorForVerdict(verdict) : nil);
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

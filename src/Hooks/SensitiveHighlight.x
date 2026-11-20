//
//  SensitiveHighlight.x
//  NeoFreeBird
//
//  Tints the background of tweets that carry X's "possibly sensitive" flag a
//  light red, so they stand out even when the sensitive content warnings are
//  turned off.
//

#import "HookHelpers.h"

static NSString* const kHighlightSensitiveTweetsKey = @"highlight_sensitive_tweets";
static const void* SensitiveHighlightViewKey = &SensitiveHighlightViewKey;

// Every status cell that has been laid out, so toggling the setting can
// restyle the cells on screen without walking the whole view tree.
static NSHashTable<T1StatusCell*>* TrackedStatusCells(void) {
    static NSHashTable* cells;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cells = [NSHashTable weakObjectsHashTable];
    });
    return cells;
}

// Translucent so separators, the tap highlight and the theme's own background
// still read through. Dark mode lands on the same dark maroon over Dim's navy
// as the reference design; light mode is a pale pink over white.
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

static id ObjectForSelectorIfResponds(id object, SEL selector) {
    if (![object respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL BoolForSelectorIfResponds(id object, SEL selector) {
    if (![object respondsToSelector:selector]) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

// Status views hold either a TFNTwitterStatus directly or a view model that
// wraps one (URT timeline items, combined view models), sometimes two deep.
static TFNTwitterStatus* StatusFromViewModel(id viewModel) {
    Class statusClass = objc_getClass("TFNTwitterStatus");
    if (!statusClass) {
        return nil;
    }

    NSArray<NSString*>* unwrapSelectors = @[@"statusViewModel", @"tweet", @"status"];
    for (NSUInteger depth = 0; viewModel && depth < 3; depth++) {
        if ([viewModel isKindOfClass:statusClass]) {
            return viewModel;
        }

        id next = nil;
        for (NSString* name in unwrapSelectors) {
            next = ObjectForSelectorIfResponds(viewModel, NSSelectorFromString(name));
            if (next && next != viewModel) {
                break;
            }
            next = nil;
        }
        viewModel = next;
    }

    return nil;
}

// isPossiblySensitive is the raw server flag. The "no sensitive content
// warnings" option only overrides the warning-level checks
// (isPossiblySensitiveViewModelForAccount:, the image interstitials), so this
// keeps working with warnings turned off.
static BOOL StatusCarriesSensitiveFlag(id status) {
    return BoolForSelectorIfResponds(status, @selector(isPossiblySensitive)) ||
           BoolForSelectorIfResponds(status, @selector(hasSensitiveMediaWarningsFlaggedByAuthor));
}

static BOOL StatusIsFlaggedSensitive(TFNTwitterStatus* status) {
    if (!status) {
        return NO;
    }

    if (StatusCarriesSensitiveFlag(status)) {
        return YES;
    }

    // A retweet is a wrapper; the flag that matters is on the original.
    id represented = ObjectForSelectorIfResponds(status, @selector(representedStatus));
    return represented && represented != status && StatusCarriesSensitiveFlag(represented);
}

static BOOL CellShowsSensitiveTweet(T1StatusCell* cell) {
    if (![cell respondsToSelector:@selector(statusView)]) {
        return NO;
    }

    id viewModel = ObjectForSelectorIfResponds(cell.statusView, @selector(viewModel));
    return StatusIsFlaggedSensitive(StatusFromViewModel(viewModel));
}

static UIView* SensitiveHighlightView(T1StatusCell* cell, BOOL createIfNeeded) {
    UIView* highlightView = objc_getAssociatedObject(cell, SensitiveHighlightViewKey);
    if (highlightView || !createIfNeeded) {
        return highlightView;
    }

    highlightView = [[UIView alloc] initWithFrame:cell.contentView.bounds];
    highlightView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    highlightView.userInteractionEnabled = NO;
    highlightView.backgroundColor = SensitiveHighlightColor();
    highlightView.hidden = YES;
    objc_setAssociatedObject(cell, SensitiveHighlightViewKey, highlightView,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return highlightView;
}

static void UpdateSensitiveHighlight(T1StatusCell* cell) {
    if (!cell) {
        return;
    }

    [TrackedStatusCells() addObject:cell];

    BOOL highlight = [BHTSettings boolForKey:kHighlightSensitiveTweetsKey] &&
                     CellShowsSensitiveTweet(cell);
    UIView* highlightView = SensitiveHighlightView(cell, highlight);
    if (!highlightView) {
        return;
    }

    highlightView.hidden = !highlight;
    if (!highlight) {
        return;
    }

    // Behind the tweet's content, on top of the cell's own background.
    UIView* container = cell.contentView;
    if (highlightView.superview != container) {
        [container insertSubview:highlightView atIndex:0];
    } else if (container.subviews.firstObject != highlightView) {
        [container sendSubviewToBack:highlightView];
    }
    highlightView.frame = container.bounds;
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
        if ([cell respondsToSelector:@selector(statusView)] && cell.statusView == statusView) {
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
    SensitiveHighlightView(self, NO).hidden = YES;
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

//
//  ShadowbanCheck.x
//  NeoFreeBird
//
//  A button beside a profile's ••• (beside search on your own profile, which
//  has no •••) opening Shadowban Checker F in a web view, with the account's
//  @username filled in and checked once. The check runs on that site's own
//  server, not through the app's X session, so X sees nothing of it; the site
//  sees which account was checked.
//
//  X places a profile's ••• and search one of two ways
//  (-[T1ProfileHeaderViewController _t1_usesSystemNavigationBar]: not in a
//  modal, and on X's newer navigation stack):
//  - in the navigation bar, as the navigation item's right bar button items
//    (-_t1_installSystemNavigationBarButtonItems). The button is added after
//    X's own items each time X sets them, which places it on their left.
//  - otherwise in a row of X's own buttons in the header
//    (T1ProfileHeaderView's trailingNavActionButtonsController.rowView), laid
//    out in -_t1_layoutNavActionButtonsRowsWithLayoutMetrics:. The button is
//    then a view of its own beside that row, sized, spaced and dressed like
//    the row's first button, following the row as it moves, hides and fades,
//    and the collapsed title keeps clear of it as it does of the row.
//

#import <WebKit/WebKit.h>
#import "../HookHelpers.h"

static NSString* const kShadowbanCheckerURL = @"https://x-shadowban-checker.fia-s.com/";
static const void* ShadowbanCheckItemKey = &ShadowbanCheckItemKey;

static BOOL ShadowbanCheckButtonOn(void) {
    return [BHTSettings boolForKey:@"shadowban_check_button"];
}

static NSString* ShadowbanCheckString(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

// MARK: - The page

// Fills the site's Username field the way typing would (it's a React field,
// so through the input's own value setter and an input event) and presses
// the search button beside it, once.
static NSString* const kFillAndCheckScript =
    @"(function (handle) {"
    @"  var tries = 0;"
    @"  function run() {"
    @"    var input = document.querySelector('input[placeholder=\\'Username\\']');"
    @"    if (!input) { if (++tries < 50) { setTimeout(run, 200); } return; }"
    @"    var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;"
    @"    setter.call(input, handle);"
    @"    input.dispatchEvent(new Event('input', { bubbles: true }));"
    @"    var row = input.parentElement && input.parentElement.parentElement;"
    @"    var buttons = row ? row.querySelectorAll('button') : [];"
    @"    for (var i = 0; i < buttons.length; i++) {"
    @"      if (buttons[i].type === 'submit') {"
    @"        var button = buttons[i];"
    @"        setTimeout(function () { button.click(); }, 300);"
    @"        return;"
    @"      }"
    @"    }"
    @"  }"
    @"  run();"
    @"})(%@[0]);";

@interface BHTShadowbanCheckViewController : UIViewController <WKNavigationDelegate>
- (instancetype)initWithUsername:(NSString*)username;
@end

@implementation BHTShadowbanCheckViewController {
    NSString* _username;
    WKWebView* _webView;
    BOOL _checked;
}

- (instancetype)initWithUsername:(NSString*)username {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _username = [username copy];
        self.title = ShadowbanCheckString(@"SHADOWBAN_CHECK_TITLE");
    }
    return self;
}

- (void)loadView {
    _webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:[[WKWebViewConfiguration alloc] init]];
    _webView.navigationDelegate = self;
    self.view = _webView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(bht_close)];
    [_webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:kShadowbanCheckerURL]]];
}

- (void)bht_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// Only on the first page that finishes loading; anything opened from there
// is left alone.
- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation {
    if (_checked || _username.length == 0) {
        return;
    }
    _checked = YES;
    NSData* json = [NSJSONSerialization dataWithJSONObject:@[_username] options:0 error:nil];
    NSString* argument = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
    if (!argument) {
        return;
    }
    [webView evaluateJavaScript:[NSString stringWithFormat:kFillAndCheckScript, argument] completionHandler:nil];
}

@end

// MARK: - The button

// The account a T1ProfileHeaderView shows.
static NSString* HeaderViewUsername(UIView* headerView) {
    NSString* username = BHTSafeString(BHTSafeObject(headerView, @selector(userDataSource)), @selector(username));
    if (username.length > 0) {
        return username;
    }
    id summary = BHTSafeObject(headerView, @selector(summaryView));
    return BHTSafeString(BHTSafeObject(summary, @selector(userDataSource)), @selector(username));
}

static NSString* ProfileUsername(UIViewController* header) {
    id viewModel = BHTSafeObject(header, @selector(viewModel));
    NSString* username = BHTSafeString(BHTSafeObject(viewModel, @selector(userDataSource)), @selector(username));
    return username.length > 0 ? username : HeaderViewUsername(BHTSafeObject(header, @selector(headerView)));
}

// Presented over whatever is on top in the window of `from`.
static void OpenShadowbanCheckFor(NSString* username, UIViewController* from) {
    if (username.length == 0 || !from) {
        return;
    }
    BHTShadowbanCheckViewController* check = [[BHTShadowbanCheckViewController alloc] initWithUsername:username];
    UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:check];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    UIViewController* presenter = from.view.window.rootViewController ?: (from.parentViewController ?: from);
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }
    [presenter presentViewController:navigation animated:YES completion:nil];
}

static void OpenShadowbanCheck(UIViewController* header) {
    OpenShadowbanCheckFor(ProfileUsername(header), header);
}

static UIBarButtonItem* ShadowbanCheckItem(UIViewController* header) {
    UIBarButtonItem* item = objc_getAssociatedObject(header, ShadowbanCheckItemKey);
    if (item) {
        return item;
    }
    UIImage* image = [UIImage systemImageNamed:@"eye.trianglebadge.exclamationmark"]
                         ?: [UIImage systemImageNamed:@"eye.slash"];
    __weak UIViewController* weakHeader = header;
    UIAction* action = [UIAction actionWithTitle:ShadowbanCheckString(@"SHADOWBAN_CHECK_TITLE")
                                           image:image
                                      identifier:nil
                                         handler:^(__kindof UIAction* sender) {
                                             OpenShadowbanCheck(weakHeader);
                                         }];
    item = [[UIBarButtonItem alloc] initWithImage:image style:UIBarButtonItemStylePlain target:nil action:nil];
    item.primaryAction = action;
    item.image = image;
    item.accessibilityLabel = ShadowbanCheckString(@"SHADOWBAN_CHECK_TITLE");
    objc_setAssociatedObject(header, ShadowbanCheckItemKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return item;
}

// After X has set the profile's right bar button items: the button goes
// after them (to their left), or comes off when the option is off.
static void UpdateShadowbanCheckButton(UIViewController* header) {
    UINavigationItem* navigationItem = header.parentViewController.navigationItem;
    if (!navigationItem) {
        return;
    }
    UIBarButtonItem* item = objc_getAssociatedObject(header, ShadowbanCheckItemKey);
    NSArray<UIBarButtonItem*>* items = navigationItem.rightBarButtonItems ?: @[];
    BOOL present = item && [items indexOfObjectIdenticalTo:item] != NSNotFound;
    BOOL wanted = ShadowbanCheckButtonOn() && BHTSafeBool(header, @selector(_t1_usesSystemNavigationBar)) &&
                  ProfileUsername(header).length > 0;
    if (wanted && !present) {
        [navigationItem setRightBarButtonItems:[items arrayByAddingObject:ShadowbanCheckItem(header)] animated:NO];
    } else if (!wanted && present) {
        NSMutableArray* kept = [items mutableCopy];
        [kept removeObjectIdenticalTo:item];
        [navigationItem setRightBarButtonItems:kept animated:NO];
    }
}

// MARK: - The button in the header's row

static const void* ShadowbanRowButtonKey = &ShadowbanRowButtonKey;
static const void* ShadowbanClearanceKey = &ShadowbanClearanceKey;
static const CGFloat kRowButtonFallbackSpacing = 8;

static double SafeDouble(id object, SEL selector) {
    if (!object) {
        return 0;
    }
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    const char* encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || (encoding[0] != 'd' && encoding[0] != 'f')) {
        return 0;
    }
    if (encoding[0] == 'f') {
        return ((float (*)(id, SEL))objc_msgSend)(object, selector);
    }
    return ((double (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL ViewIsShowing(UIView* view) {
    return [view isKindOfClass:UIView.class] && view.superview && !view.hidden && view.alpha > 0.01 &&
           CGRectGetWidth(view.bounds) > 1 && CGRectGetHeight(view.bounds) > 1;
}

@interface BHTShadowbanRowButton : UIControl
@property (nonatomic, weak) UIView* headerView;
@end

@implementation BHTShadowbanRowButton {
    UIView* _content;
    UIVisualEffectView* _effectView;
    UIView* _fillView;
    UIImageView* _iconView;
    UIVisualEffect* _sourceEffect;
    CGFloat _iconPointSize;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _content = [[UIView alloc] init];
        _content.userInteractionEnabled = NO;
        _content.clipsToBounds = YES;
        [self addSubview:_content];
        _effectView = [[UIVisualEffectView alloc] initWithEffect:nil];
        _effectView.userInteractionEnabled = NO;
        [_content addSubview:_effectView];
        _fillView = [[UIView alloc] init];
        _fillView.userInteractionEnabled = NO;
        [_content addSubview:_fillView];
        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeCenter;
        _iconView.userInteractionEnabled = NO;
        [_content addSubview:_iconView];
        self.accessibilityLabel = ShadowbanCheckString(@"SHADOWBAN_CHECK_TITLE");
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.isAccessibilityElement = YES;
        [self addTarget:self action:@selector(bht_open) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    _content.alpha = highlighted ? 0.5 : 1;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _content.frame = self.bounds;
    _content.layer.cornerRadius = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) / 2;
    _effectView.frame = _content.bounds;
    _fillView.frame = _content.bounds;
    _iconView.frame = _content.bounds;
}

// Dressed like X's button beside it: its background (the effect or color
// under it, X's glass when it's glass), its icon color and size.
- (void)bht_matchButton:(UIView*)source {
    UIVisualEffect* effect = nil;
    UIColor* fill = nil;
    NSMutableArray<UIView*>* queue = [NSMutableArray arrayWithObject:source];
    for (NSUInteger i = 0; i < queue.count && i < 60; i++) {
        UIView* view = queue[i];
        if (view != source && (view.hidden || view.alpha < 0.01)) {
            continue;
        }
        if ([view isKindOfClass:UIVisualEffectView.class]) {
            if (!effect) {
                effect = ((UIVisualEffectView*)view).effect;
            }
            continue;
        }
        UIColor* color = view.backgroundColor;
        if (!fill && color && CGColorGetAlpha(color.CGColor) > 0.01 &&
            CGRectGetWidth(view.bounds) >= CGRectGetWidth(source.bounds) * 0.8) {
            fill = color;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    if (!effect && !fill && BHTSafeBool(source, @selector(isGlassMaterialized))) {
        Class glass = NSClassFromString(@"UIGlassEffect");
        effect = glass ? [[glass alloc] init] : nil;
    }
    if (effect != _sourceEffect && !(effect && [effect isEqual:_sourceEffect])) {
        _sourceEffect = effect;
        _effectView.effect = effect;
    }
    _effectView.hidden = effect == nil;
    _fillView.backgroundColor = fill;
    _fillView.hidden = fill == nil;

    id configuration = BHTSafeObject(source, @selector(currentConfiguration));
    id foreground = BHTSafeObject(BHTSafeObject(configuration, @selector(style)), @selector(foregroundColor));
    self.tintColor = [foreground isKindOfClass:UIColor.class] ? foreground : (source.tintColor ?: UIColor.whiteColor);
    double iconSize = SafeDouble(BHTSafeObject(configuration, @selector(size)), @selector(iconSize));
    CGFloat pointSize = iconSize > 0 ? round(iconSize * 0.8) : 16;
    if (pointSize != _iconPointSize || !_iconView.image) {
        _iconPointSize = pointSize;
        UIImageSymbolConfiguration* symbol =
            [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightSemibold];
        _iconView.image = [UIImage systemImageNamed:@"eye.trianglebadge.exclamationmark" withConfiguration:symbol]
                              ?: [UIImage systemImageNamed:@"eye.slash" withConfiguration:symbol];
    }
}

- (void)bht_open {
    UIView* header = self.headerView;
    UIResponder* responder = header;
    while (responder && ![responder isKindOfClass:UIViewController.class]) {
        responder = responder.nextResponder;
    }
    OpenShadowbanCheckFor(HeaderViewUsername(header), (UIViewController*)responder);
}

@end

// X's buttons showing in the row, the one first in reading order (the
// leftmost, rightmost right to left) first.
static NSArray<UIView*>* ShowingRowButtons(id controller, UIView* row, UIView* header, BOOL rightToLeft) {
    NSMutableArray<UIView*>* buttons = [NSMutableArray array];
    id visible = BHTSafeObject(controller, @selector(visibleButtons));
    for (id button in [visible isKindOfClass:NSArray.class] ? visible : @[]) {
        if (ViewIsShowing(button) && [button isDescendantOfView:row]) {
            [buttons addObject:button];
        }
    }
    [buttons sortUsingComparator:^NSComparisonResult(UIView* a, UIView* b) {
        CGFloat ax = CGRectGetMidX([a convertRect:a.bounds toView:header]);
        CGFloat bx = CGRectGetMidX([b convertRect:b.bounds toView:header]);
        if (ax == bx) {
            return NSOrderedSame;
        }
        return ((ax < bx) != rightToLeft) ? NSOrderedAscending : NSOrderedDescending;
    }];
    return buttons;
}

// Puts the button before the first of X's buttons in the header's trailing
// row (hidden when the row is, or with the option off). With
// `adjustClearance`, right after X has set the collapsed title's clearance
// for the row, widens it by the button.
static void UpdateShadowbanRowButton(UIView* header, BOOL adjustClearance) {
    id controller = BHTSafeObject(header, @selector(trailingNavActionButtonsController));
    UIView* row = BHTSafeObject(controller, @selector(rowView));
    if (![row isKindOfClass:UIView.class]) {
        return;
    }
    BHTShadowbanRowButton* button = objc_getAssociatedObject(row, ShadowbanRowButtonKey);
    BOOL rightToLeft = header.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    NSArray<UIView*>* buttons = nil;
    if (ShadowbanCheckButtonOn() && ViewIsShowing(row) && row.superview && HeaderViewUsername(header).length > 0) {
        buttons = ShowingRowButtons(controller, row, header, rightToLeft);
    }
    UIView* source = buttons.firstObject;
    if (!source) {
        button.hidden = YES;
        return;
    }
    if (!button) {
        button = [[BHTShadowbanRowButton alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(row, ShadowbanRowButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    button.headerView = header;
    if (button.superview != row.superview) {
        [row.superview insertSubview:button aboveSubview:row];
    }

    CGRect anchor = [source convertRect:source.bounds toView:row.superview];
    id configuration = BHTSafeObject(source, @selector(currentConfiguration));
    CGFloat spacing = SafeDouble(BHTSafeObject(configuration, @selector(size)), @selector(interButtonSpacing));
    if (spacing <= 0 && buttons.count > 1) {
        CGRect next = [buttons[1] convertRect:buttons[1].bounds toView:row.superview];
        spacing = rightToLeft ? CGRectGetMinX(anchor) - CGRectGetMaxX(next) : CGRectGetMinX(next) - CGRectGetMaxX(anchor);
    }
    if (spacing <= 0 || spacing > 40) {
        spacing = kRowButtonFallbackSpacing;
    }
    CGFloat width = CGRectGetWidth(anchor);
    CGFloat x = rightToLeft ? CGRectGetMaxX(anchor) + spacing : CGRectGetMinX(anchor) - spacing - width;
    CGRect frame = CGRectMake(x, CGRectGetMinY(anchor), width, CGRectGetHeight(anchor));
    if (!CGRectEqualToRect(button.frame, frame)) {
        button.frame = frame;
    }
    [button bht_matchButton:source];
    button.alpha = row.alpha * source.alpha;
    button.userInteractionEnabled = row.userInteractionEnabled;
    button.hidden = NO;

    // The collapsed name and @username keep clear of the row's buttons by
    // this much from the trailing edge; once more for this one, unless it's
    // already in (X didn't set it again since).
    id summary = BHTSafeObject(header, @selector(summaryView));
    SEL setter = @selector(setCollapsedTrailingClearance:);
    if (adjustClearance && [summary respondsToSelector:setter]) {
        double clearance = SafeDouble(summary, @selector(collapsedTrailingClearance));
        NSNumber* added = objc_getAssociatedObject(summary, ShadowbanClearanceKey);
        if (clearance > 0 && !(added && fabs(added.doubleValue - clearance) < 0.5)) {
            double widened = clearance + width + spacing;
            ((void (*)(id, SEL, double))objc_msgSend)(summary, setter, widened);
            objc_setAssociatedObject(summary, ShadowbanClearanceKey, @(widened), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

%hook T1ProfileHeaderView

- (void)_t1_layoutNavActionButtonsRowsWithLayoutMetrics:(id)metrics {
    %orig;
    UpdateShadowbanRowButton((UIView*)self, YES);
}

- (void)_t1_setNavActionRowHidden:(BOOL)hidden controller:(id)controller {
    %orig;
    UpdateShadowbanRowButton((UIView*)self, NO);
}

%end

// The row laying out its buttons anew (one appearing as the profile loads,
// one going) or X restyling them as the header collapses.
%hook XDSButtonRow

- (void)layoutSubviews {
    %orig;
    BHTShadowbanRowButton* button = objc_getAssociatedObject(self, ShadowbanRowButtonKey);
    if (button.headerView) {
        UpdateShadowbanRowButton(button.headerView, NO);
    }
}

%end

%hook ProfileActionButtonsController

- (void)updateContextScrolledPastCollapse:(BOOL)scrolledPastCollapse
                 showingNormalMainContent:(BOOL)showingNormalMainContent
                                 animated:(BOOL)animated {
    %orig;
    UIView* row = BHTSafeObject(self, @selector(rowView));
    BHTShadowbanRowButton* button = [row isKindOfClass:UIView.class] ? objc_getAssociatedObject(row, ShadowbanRowButtonKey) : nil;
    if (button.headerView) {
        __weak UIView* header = button.headerView;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (header) {
                UpdateShadowbanRowButton(header, NO);
            }
        });
    }
}

%end

%hook T1ProfileHeaderViewController

- (void)_t1_installSystemNavigationBarButtonItems {
    %orig;
    UpdateShadowbanCheckButton((UIViewController*)self);
}

- (void)_t1_updateSystemNavigationBarAdoption {
    %orig;
    UpdateShadowbanCheckButton((UIViewController*)self);
}

// The @username may only be known once the profile has loaded.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UpdateShadowbanCheckButton((UIViewController*)self);
}

%end

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
//  The profile puts its ••• and search into its navigation item's right bar
//  button items (-_t1_installSystemNavigationBarButtonItems); the button is
//  added after X's own items each time X sets them, which places it on their
//  left. A profile shown in a modal lays its buttons out in the header
//  instead and gets none.
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

static NSString* ProfileUsername(UIViewController* header) {
    id viewModel = BHTSafeObject(header, @selector(viewModel));
    return BHTSafeString(BHTSafeObject(viewModel, @selector(userDataSource)), @selector(username));
}

static void OpenShadowbanCheck(UIViewController* header) {
    NSString* username = ProfileUsername(header);
    if (!header || username.length == 0) {
        return;
    }
    BHTShadowbanCheckViewController* check = [[BHTShadowbanCheckViewController alloc] initWithUsername:username];
    UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:check];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    UIViewController* presenter = header.parentViewController ?: header;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }
    [presenter presentViewController:navigation animated:YES completion:nil];
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

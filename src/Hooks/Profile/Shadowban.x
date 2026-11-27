//
//  Shadowban.x
//  NeoFreeBird
//
//  What X itself has put on an account, the way Shadowban Scanner shows it
//  on the web: a red ring around the avatar of an account X restricts
//  (outside the purple ring of a Space it's in), and the details from a
//  profile's ••• menu. Only what the app already gets with the account is
//  used; nothing is fetched.
//   - Profile interstitial: X shows a warning before the profile (sensitive
//     media and the like). Rings the avatar.
//   - Withheld in countries. Rings the avatar.
//   - Graduated access: in the details only (an account missing the field
//     can't be told from one held back).
//   - The account's own sensitive flag: X's app never asks for it, so the
//     details say so.
//

#import <QuartzCore/QuartzCore.h>
#import "../HookHelpers.h"

static const void* ShadowbanRingKey = &ShadowbanRingKey;

static BOOL ShadowbanScannerOn(void) {
    return [BHTSettings boolForKey:@"shadowban_scanner"];
}

static long long InterstitialTypeOf(id user) {
    return BHTSafeLongLong(user, @selector(profileInterstitialType));
}

static NSArray<NSString*>* WithheldCountriesOf(id user) {
    id countries = BHTSafeObject(user, @selector(withheldInCountries));
    return [countries isKindOfClass:NSArray.class] ? countries : @[];
}

static BOOL UserIsRestricted(id user) {
    return user && (InterstitialTypeOf(user) != 0 || WithheldCountriesOf(user).count > 0);
}

// MARK: - The ring

// What the ring goes around: the avatar, or the presence view holding it
// inset to make room for the purple ring of a Space.
static UIView* RingedViewFor(UIView* avatar) {
    UIView* view = avatar.superview;
    for (int depth = 0; view && depth < 3; depth++, view = view.superview) {
        if ([NSStringFromClass(view.class) containsString:@"PresenceView"]) {
            return view.bounds.size.width >= avatar.bounds.size.width + 1 ? view : avatar;
        }
    }
    return avatar;
}

// The avatar's corner radius as drawn (organizations have rounded squares),
// or a negative number for a circle.
static CGFloat AvatarCornerRadius(UIView* avatar) {
    CGFloat half = MIN(avatar.bounds.size.width, avatar.bounds.size.height) / 2;
    NSMutableArray<UIView*>* views = [NSMutableArray arrayWithObject:avatar];
    [views addObjectsFromArray:avatar.subviews];
    for (UIView* view in views) {
        CGFloat radius = view.layer.cornerRadius;
        if (radius > 0.5) {
            CGFloat scale = view.bounds.size.width > 0 ? avatar.bounds.size.width / view.bounds.size.width : 1;
            radius *= scale;
            return radius >= half - 1 ? -1 : radius;
        }
    }
    return -1;
}

static NSDictionary* NoRingAnimations(void) {
    static NSDictionary* actions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        actions = @{@"bounds": NSNull.null, @"position": NSNull.null, @"frame": NSNull.null,
                    @"path": NSNull.null, @"hidden": NSNull.null, @"lineWidth": NSNull.null,
                    @"strokeColor": NSNull.null};
    });
    return actions;
}

static void UpdateShadowbanRing(UIView* avatar) {
    CAShapeLayer* ring = objc_getAssociatedObject(avatar, ShadowbanRingKey);
    BOOL show = ShadowbanScannerOn() && avatar.window && !avatar.hidden && avatar.alpha > 0.01 &&
                avatar.bounds.size.width >= 12 && UserIsRestricted(BHTSafeObject(avatar, @selector(user)));
    UIView* ringed = show ? RingedViewFor(avatar) : nil;
    // Drawn in the ringed view when nothing clips it there (it then moves
    // with it), otherwise beside it in its superview.
    BOOL inside = ringed && !ringed.clipsToBounds && !ringed.layer.masksToBounds && !ringed.layer.mask;
    CALayer* host = inside ? ringed.layer : ringed.superview.layer;
    if (!show || !host) {
        if (ring && !ring.hidden) {
            ring.hidden = YES;
        }
        return;
    }

    if (!ring) {
        ring = [CAShapeLayer layer];
        ring.fillColor = UIColor.clearColor.CGColor;
        ring.actions = NoRingAnimations();
        objc_setAssociatedObject(avatar, ShadowbanRingKey, ring, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGRect frame = inside ? ringed.bounds : [ringed convertRect:ringed.bounds toView:ringed.superview];
    CGFloat lineWidth = MAX(1.5, round(frame.size.width * 0.045 * 2) / 2);
    CGFloat gap = ringed == avatar ? 1 : 0.5;
    CGFloat outset = gap + lineWidth;
    CGRect ringFrame = CGRectInset(frame, -outset, -outset);
    CGRect pathRect = CGRectMake(lineWidth / 2, lineWidth / 2, ringFrame.size.width - lineWidth,
                                 ringFrame.size.height - lineWidth);
    CGFloat corner = AvatarCornerRadius(avatar);
    UIBezierPath* path = corner < 0
                             ? [UIBezierPath bezierPathWithOvalInRect:pathRect]
                             : [UIBezierPath bezierPathWithRoundedRect:pathRect
                                                          cornerRadius:corner * frame.size.width /
                                                                           MAX(1, avatar.bounds.size.width) +
                                                                       gap + lineWidth / 2];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (ring.superlayer != host) {
        [host addSublayer:ring];
    } else if (host.sublayers.lastObject != ring) {
        [ring removeFromSuperlayer];
        [host addSublayer:ring];
    }
    ring.frame = ringFrame;
    ring.path = path.CGPath;
    ring.lineWidth = lineWidth;
    ring.strokeColor = [UIColor.systemRedColor resolvedColorWithTraitCollection:avatar.traitCollection].CGColor;
    ring.hidden = NO;
    [CATransaction commit];
}

%hook TUIAvatarImageView

- (void)setUser:(id)user {
    %orig;
    UpdateShadowbanRing((UIView*)self);
}

- (void)layoutSubviews {
    %orig;
    UpdateShadowbanRing((UIView*)self);
}

- (void)didMoveToWindow {
    %orig;
    UpdateShadowbanRing((UIView*)self);
}

- (void)setHidden:(BOOL)hidden {
    %orig;
    UpdateShadowbanRing((UIView*)self);
}

- (void)setFrame:(CGRect)frame {
    %orig;
    UpdateShadowbanRing((UIView*)self);
}

- (void)setCenter:(CGPoint)center {
    %orig;
    UpdateShadowbanRing((UIView*)self);
}

%end

// MARK: - The details

static NSString* ShadowbanString(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

static NSString* CountryList(NSArray<NSString*>* codes) {
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    for (NSString* code in codes) {
        if (![code isKindOfClass:NSString.class] || code.length == 0) {
            continue;
        }
        NSString* name = [NSLocale.currentLocale localizedStringForCountryCode:code];
        [names addObject:name.length ? [NSString stringWithFormat:@"%@ (%@)", name, code.uppercaseString]
                                     : code.uppercaseString];
    }
    return [names componentsJoinedByString:@", "];
}

static NSString* ShadowbanStatusText(id user) {
    NSMutableArray<NSString*>* lines = [NSMutableArray array];

    [lines addObject:[NSString stringWithFormat:@"%@: %@", ShadowbanString(@"SHADOWBAN_STATUS_SENSITIVE_ACCOUNT"),
                                                ShadowbanString(@"SHADOWBAN_STATUS_UNAVAILABLE")]];

    BOOL graduated = BHTSafeBool(user, @selector(hasGraduatedAccess));
    long long graduatedType = BHTSafeLongLong(user, @selector(graduatedAccessType));
    NSString* graduatedText = ShadowbanString(graduated ? @"SHADOWBAN_STATUS_GRADUATED_CLEAR"
                                                        : @"SHADOWBAN_STATUS_GRADUATED_RESTRICTED");
    if (graduatedType != 0) {
        graduatedText = [NSString stringWithFormat:ShadowbanString(@"SHADOWBAN_STATUS_KIND_FORMAT"), graduatedText,
                                                   graduatedType];
    }
    [lines addObject:[NSString stringWithFormat:@"%@: %@", ShadowbanString(@"SHADOWBAN_STATUS_GRADUATED_ACCESS"),
                                                graduatedText]];

    long long interstitial = InterstitialTypeOf(user);
    NSString* interstitialText =
        interstitial != 0 ? [NSString stringWithFormat:ShadowbanString(@"SHADOWBAN_STATUS_KIND_FORMAT"),
                                                       ShadowbanString(@"SHADOWBAN_STATUS_YES"), interstitial]
                          : ShadowbanString(@"SHADOWBAN_STATUS_NO");
    [lines addObject:[NSString stringWithFormat:@"%@: %@", ShadowbanString(@"SHADOWBAN_STATUS_PROFILE_MEDIA"),
                                                interstitialText]];

    NSString* countries = CountryList(WithheldCountriesOf(user));
    [lines addObject:[NSString stringWithFormat:@"%@: %@", ShadowbanString(@"SHADOWBAN_STATUS_WITHHELD"),
                                                countries.length ? countries : ShadowbanString(@"SHADOWBAN_STATUS_NO")]];

    [lines addObject:@""];
    [lines addObject:ShadowbanString(@"SHADOWBAN_STATUS_NOTE")];
    return [lines componentsJoinedByString:@"\n"];
}

// Once the ••• menu has gone, from whatever is on top.
static void PresentShadowbanStatus(UIViewController* from, id user) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController* presenter = from.view.window.rootViewController ?: from;
        while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
            presenter = presenter.presentedViewController;
        }
        if (!presenter) {
            return;
        }
        UIAlertController* alert =
            [UIAlertController alertControllerWithTitle:ShadowbanString(@"SHADOWBAN_STATUS_TITLE")
                                                message:ShadowbanStatusText(user)
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ShadowbanString(@"OK_ACTION_LABEL")
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

%hook T1ProfileHeaderViewController

- (id)profileMoreActionsBaseActionItemsWithSender:(id)sender {
    NSArray* items = %orig;
    if (!ShadowbanScannerOn() || ![items isKindOfClass:NSArray.class] ||
        ![items.firstObject isKindOfClass:%c(TFNActionItem)]) {
        return items;
    }
    id viewModel = BHTSafeObject(self, @selector(viewModel));
    id user = BHTSafeObject(BHTSafeObject(viewModel, @selector(userDataSource)), @selector(user));
    if (!user) {
        return items;
    }

    __weak UIViewController* weakSelf = (UIViewController*)self;
    TFNActionItem* item = [%c(TFNActionItem) actionItemWithTitle:ShadowbanString(@"SHADOWBAN_STATUS_TITLE")
                                                        imageName:@"safety_exclamation_stroke"
                                                           action:^{
                                                               UIViewController* header = weakSelf;
                                                               if (header) {
                                                                   PresentShadowbanStatus(header, user);
                                                               }
                                                           }];
    return item ? [items arrayByAddingObject:item] : items;
}

%end

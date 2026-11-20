//
//  SensitiveZonesViewController.m
//  NeoFreeBird
//

#import "Settings/Pages/SensitiveZonesViewController.h"
#import "Core/BHTBundle.h"
#import "Core/BHTSensitiveZones.h"
#import "Headers/TWHeaders.h"
#import "Settings/ModernSettingsCells.h"
#import "ThemeColor/Palette.h"

typedef NS_ENUM(NSInteger, ZonesSection) {
    ZonesSectionSettings,
    ZonesSectionPlaces,
    ZonesSectionCount,
};

typedef NS_ENUM(NSInteger, ZonesSettingsRow) {
    ZonesSettingsRowEnabled,
    ZonesSettingsRowRadius,
    ZonesSettingsRowStatus,
    ZonesSettingsRowCount,
};

// After the places themselves.
typedef NS_ENUM(NSInteger, ZonesAddRow) {
    ZonesAddRowCurrentLocation,
    ZonesAddRowCoordinates,
    ZonesAddRowCount,
};

static NSString* L(NSString* key) {
    return [[BHTBundle sharedBundle] localizedStringForKey:key];
}

@interface SensitiveZonesViewController ()
@property (nonatomic, strong) TFNTwitterAccount* account;
@property (nonatomic, strong) UITableView* tableView;
@property (nonatomic, copy) NSArray<NSDictionary*>* places;
@end

@implementation SensitiveZonesViewController

- (instancetype)initWithAccount:(TFNTwitterAccount*)account {
    if ((self = [super init])) {
        _account = account;
        _places = BHTSensitiveZones.places;
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    NSString* title = L(@"SENSITIVE_ZONES_TITLE");
    if (self.account) {
        self.navigationItem.titleView =
            [objc_getClass("TFNTitleView") titleViewWithTitle:title
                                                     subtitle:self.account.displayUsername];
    } else {
        self.title = title;
    }

    self.view.backgroundColor = [Palette currentBackgroundColor];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [Palette currentBackgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    [self.tableView registerClass:[ModernSettingsToggleCell class] forCellReuseIdentifier:@"ToggleCell"];
    [self.tableView registerClass:[ModernSettingsToggleCell class] forCellReuseIdentifier:@"InfoCell"];
    [self.tableView registerClass:[ModernSettingsCompactButtonCell class]
           forCellReuseIdentifier:@"CompactButtonCell"];
    [self.view addSubview:self.tableView];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(zonesDidChange)
                                               name:BHTSensitiveZonesDidChangeNotification
                                             object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadPlaces];
}

- (void)zonesDidChange {
    [self.tableView reloadData];
}

- (void)reloadPlaces {
    self.places = BHTSensitiveZones.places;
    [self.tableView reloadData];
}

- (void)savePlaces:(NSArray<NSDictionary*>*)places {
    [BHTSensitiveZones setPlaces:places];
    [self reloadPlaces];
}

#pragma mark - Text

- (NSString*)radiusLabel:(NSInteger)radius {
    return [NSString stringWithFormat:@"%ld m", (long)radius];
}

- (NSString*)statusText {
    BHTSensitiveZones* zones = BHTSensitiveZones.shared;
    switch (zones.status) {
        case BHTSensitiveZoneStatusOff:
            return L(@"SENSITIVE_ZONES_STATUS_OFF");
        case BHTSensitiveZoneStatusNoPlaces:
            return L(@"SENSITIVE_ZONES_STATUS_NO_PLACES");
        case BHTSensitiveZoneStatusNeedsPermission:
            return L(@"SENSITIVE_ZONES_STATUS_NEEDS_PERMISSION");
        case BHTSensitiveZoneStatusLocating:
            return L(@"SENSITIVE_ZONES_STATUS_LOCATING");
        case BHTSensitiveZoneStatusInside:
            return [NSString stringWithFormat:L(@"SENSITIVE_ZONES_STATUS_INSIDE"), zones.insidePlaceName ?: @""];
        case BHTSensitiveZoneStatusOutside:
            return L(@"SENSITIVE_ZONES_STATUS_OUTSIDE");
    }
    return @"";
}

- (NSString*)nameOfPlace:(NSDictionary*)place {
    NSString* name = place[@"name"];
    return [name isKindOfClass:NSString.class] && name.length > 0 ? name : L(@"SENSITIVE_ZONES_UNNAMED");
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return ZonesSectionCount;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == ZonesSectionSettings) {
        return ZonesSettingsRowCount;
    }
    return self.places.count + ZonesAddRowCount;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    return section == ZonesSectionPlaces ? L(@"SENSITIVE_ZONES_PLACES_HEADER") : nil;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    return section == ZonesSectionPlaces ? L(@"SENSITIVE_ZONES_PLACES_FOOTER") : nil;
}

- (UITableViewCell*)infoCellForTableView:(UITableView*)tableView
                               indexPath:(NSIndexPath*)indexPath
                                   title:(NSString*)title
                                subtitle:(NSString*)subtitle
                              selectable:(BOOL)selectable {
    ModernSettingsToggleCell* cell = [tableView dequeueReusableCellWithIdentifier:@"InfoCell"
                                                                     forIndexPath:indexPath];
    [cell configureWithTitle:title subtitle:subtitle];
    cell.toggleSwitch.hidden = YES;
    cell.selectionStyle = selectable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell*)compactCellForTableView:(UITableView*)tableView
                                  indexPath:(NSIndexPath*)indexPath
                                      title:(NSString*)title
                                   subtitle:(NSString*)subtitle {
    ModernSettingsCompactButtonCell* cell = [tableView dequeueReusableCellWithIdentifier:@"CompactButtonCell"
                                                                            forIndexPath:indexPath];
    [cell configureWithTitle:title subtitle:subtitle];
    return cell;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    if (indexPath.section == ZonesSectionSettings) {
        switch (indexPath.row) {
            case ZonesSettingsRowEnabled: {
                ModernSettingsToggleCell* cell = [tableView dequeueReusableCellWithIdentifier:@"ToggleCell"
                                                                                 forIndexPath:indexPath];
                [cell configureWithTitle:L(@"SENSITIVE_ZONES_ENABLED_TITLE")
                                subtitle:L(@"SENSITIVE_ZONES_ENABLED_DETAIL")];
                cell.toggleSwitch.on = BHTSensitiveZones.enabled;
                [cell.toggleSwitch removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
                [cell addTarget:self action:@selector(enabledChanged:) forControlEvents:UIControlEventValueChanged];
                return cell;
            }
            case ZonesSettingsRowRadius:
                return [self compactCellForTableView:tableView
                                           indexPath:indexPath
                                               title:L(@"SENSITIVE_ZONES_RADIUS_TITLE")
                                            subtitle:[self radiusLabel:BHTSensitiveZones.radius]];
            default: {
                BOOL needsPermission =
                    BHTSensitiveZones.shared.status == BHTSensitiveZoneStatusNeedsPermission;
                return [self infoCellForTableView:tableView
                                        indexPath:indexPath
                                            title:L(@"SENSITIVE_ZONES_STATUS_TITLE")
                                         subtitle:[self statusText]
                                       selectable:needsPermission];
            }
        }
    }

    if (indexPath.row < (NSInteger)self.places.count) {
        NSDictionary* place = self.places[indexPath.row];
        NSString* coordinate = [NSString stringWithFormat:@"%.5f, %.5f",
                                                          [place[@"lat"] doubleValue],
                                                          [place[@"lon"] doubleValue]];
        return [self infoCellForTableView:tableView
                                indexPath:indexPath
                                    title:[self nameOfPlace:place]
                                 subtitle:coordinate
                               selectable:YES];
    }

    NSInteger addRow = indexPath.row - self.places.count;
    NSString* title = addRow == ZonesAddRowCurrentLocation ? L(@"SENSITIVE_ZONES_ADD_CURRENT")
                                                           : L(@"SENSITIVE_ZONES_ADD_COORDINATES");
    return [self compactCellForTableView:tableView indexPath:indexPath title:title subtitle:@""];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == ZonesSectionSettings) {
        if (indexPath.row == ZonesSettingsRowRadius) {
            [self showRadiusPicker];
        } else if (indexPath.row == ZonesSettingsRowStatus &&
                   BHTSensitiveZones.shared.status == BHTSensitiveZoneStatusNeedsPermission) {
            [self showPermissionDeniedAlert];
        }
        return;
    }

    if (indexPath.row < (NSInteger)self.places.count) {
        [self showActionsForPlaceAtIndex:indexPath.row];
        return;
    }

    if (indexPath.row - (NSInteger)self.places.count == ZonesAddRowCurrentLocation) {
        [self addCurrentLocation];
    } else {
        [self addPlaceByCoordinates];
    }
}

- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath {
    if (indexPath.section != ZonesSectionPlaces || indexPath.row >= (NSInteger)self.places.count) {
        return nil;
    }

    NSInteger index = indexPath.row;
    UIContextualAction* delete =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:L(@"SENSITIVE_ZONES_DELETE")
                                              handler:^(UIContextualAction* action, UIView* sourceView,
                                                        void (^completion)(BOOL)) {
                                                  [self deletePlaceAtIndex:index];
                                                  completion(YES);
                                              }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

#pragma mark - Settings

- (void)enabledChanged:(UISwitch*)sender {
    [BHTSensitiveZones setEnabled:sender.isOn];
    [self.tableView reloadData];
}

- (void)showRadiusPicker {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:L(@"SENSITIVE_ZONES_RADIUS_TITLE")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    for (NSNumber* radius in BHTSensitiveZones.radiusChoices) {
        [alert addAction:[UIAlertAction actionWithTitle:[self radiusLabel:radius.integerValue]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction* action) {
                                                    [BHTSensitiveZones setRadius:radius.integerValue];
                                                    [self.tableView reloadData];
                                                }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:L(@"CANCEL_ACTION_LABEL")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showPermissionDeniedAlert {
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:L(@"SENSITIVE_ZONES_LOCATION_DENIED_TITLE")
                                            message:L(@"SENSITIVE_ZONES_LOCATION_DENIED_MESSAGE")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"SENSITIVE_ZONES_OPEN_SETTINGS")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                                NSURL* url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
                                                [UIApplication.sharedApplication openURL:url
                                                                                 options:@{}
                                                                       completionHandler:nil];
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"CANCEL_ACTION_LABEL")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showMessage:(NSString*)message {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:message
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"OK_ACTION_LABEL")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Places

- (NSString*)defaultNameForNewPlace {
    return [NSString stringWithFormat:L(@"SENSITIVE_ZONES_DEFAULT_NAME"), (long)self.places.count + 1];
}

- (void)addPlaceWithName:(NSString*)name coordinate:(CLLocationCoordinate2D)coordinate {
    NSString* trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray* places = [self.places mutableCopy];
    [places addObject:[BHTSensitiveZones placeWithName:trimmed.length ? trimmed : [self defaultNameForNewPlace]
                                            coordinate:coordinate]];
    [self savePlaces:places];
}

- (void)deletePlaceAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.places.count) {
        return;
    }
    NSMutableArray* places = [self.places mutableCopy];
    [places removeObjectAtIndex:index];
    [self savePlaces:places];
}

- (void)showActionsForPlaceAtIndex:(NSInteger)index {
    NSDictionary* place = self.places[index];
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self nameOfPlace:place]
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"SENSITIVE_ZONES_RENAME")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                                [self renamePlaceAtIndex:index];
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"SENSITIVE_ZONES_DELETE")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction* action) {
                                                [self deletePlaceAtIndex:index];
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"CANCEL_ACTION_LABEL")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)renamePlaceAtIndex:(NSInteger)index {
    NSDictionary* place = self.places[index];
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:L(@"SENSITIVE_ZONES_NAME_TITLE")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak UIAlertController* weakAlert = alert;
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.text = [self nameOfPlace:place];
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"CANCEL_ACTION_LABEL")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction
                         actionWithTitle:L(@"SAVE_ACTION_LABEL")
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction* action) {
                                     NSString* name = [weakAlert.textFields.firstObject.text
                                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                                     if (name.length == 0 || index >= (NSInteger)self.places.count) {
                                         return;
                                     }
                                     NSMutableArray* places = [self.places mutableCopy];
                                     NSMutableDictionary* renamed = [places[index] mutableCopy];
                                     renamed[@"name"] = name;
                                     places[index] = [renamed copy];
                                     [self savePlaces:places];
                                 }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptNameForCoordinate:(CLLocationCoordinate2D)coordinate {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:L(@"SENSITIVE_ZONES_NAME_TITLE")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak UIAlertController* weakAlert = alert;
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = L(@"SENSITIVE_ZONES_NAME_PLACEHOLDER");
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"CANCEL_ACTION_LABEL")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"SAVE_ACTION_LABEL")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                                [self addPlaceWithName:weakAlert.textFields.firstObject.text
                                                            coordinate:coordinate];
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addCurrentLocation {
    BHTSensitiveZones* zones = BHTSensitiveZones.shared;
    CLAuthorizationStatus authorization = zones.authorizationStatus;
    if (authorization == kCLAuthorizationStatusDenied || authorization == kCLAuthorizationStatusRestricted) {
        [self showPermissionDeniedAlert];
        return;
    }

    UIAlertController* waiting = [UIAlertController alertControllerWithTitle:L(@"SENSITIVE_ZONES_LOCATING")
                                                                     message:nil
                                                              preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    void (^finish)(CLLocation*) = ^(CLLocation* location) {
        [waiting dismissViewControllerAnimated:YES
                                    completion:^{
                                        typeof(self) strongSelf = weakSelf;
                                        if (!strongSelf) {
                                            return;
                                        }
                                        if (!location) {
                                            CLAuthorizationStatus now = BHTSensitiveZones.shared.authorizationStatus;
                                            if (now == kCLAuthorizationStatusDenied ||
                                                now == kCLAuthorizationStatusRestricted) {
                                                [strongSelf showPermissionDeniedAlert];
                                            } else {
                                                [strongSelf showMessage:L(@"SENSITIVE_ZONES_LOCATION_FAILED")];
                                            }
                                            return;
                                        }
                                        [strongSelf promptNameForCoordinate:location.coordinate];
                                    }];
    };

    // Fetch only once the alert is up: a recent fix comes back synchronously,
    // and dismissing an alert mid-presentation does nothing.
    [self presentViewController:waiting
                       animated:YES
                     completion:^{
                         [zones fetchCurrentLocation:finish];
                     }];
}

// "35.681236, 139.767125" as copied from a map app; full-width commas and
// plain spaces work too.
- (BOOL)parseCoordinate:(NSString*)text into:(CLLocationCoordinate2D*)coordinate {
    NSString* normalized = [[text stringByReplacingOccurrencesOfString:@"，" withString:@","]
        stringByReplacingOccurrencesOfString:@"、"
                                  withString:@","];
    NSCharacterSet* separators = [NSCharacterSet characterSetWithCharactersInString:@", \t\n"];
    NSMutableArray<NSString*>* parts = [NSMutableArray array];
    for (NSString* part in [normalized componentsSeparatedByCharactersInSet:separators]) {
        if (part.length) {
            [parts addObject:part];
        }
    }
    if (parts.count != 2) {
        return NO;
    }

    double values[2];
    for (NSUInteger i = 0; i < 2; i++) {
        NSScanner* scanner = [NSScanner scannerWithString:parts[i]];
        if (![scanner scanDouble:&values[i]] || !scanner.isAtEnd) {
            return NO;
        }
    }

    CLLocationCoordinate2D parsed = CLLocationCoordinate2DMake(values[0], values[1]);
    if (!CLLocationCoordinate2DIsValid(parsed)) {
        return NO;
    }
    *coordinate = parsed;
    return YES;
}

- (void)addPlaceByCoordinates {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:L(@"SENSITIVE_ZONES_ADD_COORDINATES")
                                                                   message:L(@"SENSITIVE_ZONES_COORDINATES_MESSAGE")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak UIAlertController* weakAlert = alert;
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = L(@"SENSITIVE_ZONES_NAME_PLACEHOLDER");
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.placeholder = @"35.681236, 139.767125";
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"CANCEL_ACTION_LABEL")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:L(@"SAVE_ACTION_LABEL")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                                CLLocationCoordinate2D coordinate;
                                                if (![self parseCoordinate:weakAlert.textFields.lastObject.text
                                                                      into:&coordinate]) {
                                                    [self showMessage:L(@"SENSITIVE_ZONES_INVALID_COORDINATES")];
                                                    return;
                                                }
                                                [self addPlaceWithName:weakAlert.textFields.firstObject.text
                                                            coordinate:coordinate];
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

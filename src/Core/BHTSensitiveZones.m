//
//  BHTSensitiveZones.m
//  NeoFreeBird
//

#import "Core/BHTSensitiveZones.h"
#import <UIKit/UIKit.h>
#import "Core/BHTBundle.h"
#import "Core/BHTSettings.h"

NSNotificationName const BHTSensitiveZonesDidChangeNotification = @"BHTSensitiveZonesDidChangeNotification";

NSString* const BHTSensitiveZonesEnabledKey = @"sensitive_zones_enabled";
NSString* const BHTSensitiveZonesPlacesKey = @"sensitive_zones_places";
NSString* const BHTSensitiveZonesRadiusKey = @"sensitive_zones_radius";
NSString* const BHTSensitiveZonesSummaryKey = @"sensitive_zones_summary";

static NSString* const kWarningsOptionKey = @"disable_sensitive_tweet_warnings";
static const NSInteger kDefaultRadius = 200;

// A fix older than this says nothing about where the device is now.
static const NSTimeInterval kMaxLocationAge = 5 * 60;
// Once inside, leaving takes this much more than the radius, so a fix
// wobbling on the boundary doesn't flip the warnings back and forth.
static const CLLocationDistance kExitMargin = 30;
// "Add current location" waits this long for a good fix before settling for
// the best one so far.
static const NSTimeInterval kFetchTimeout = 10;
static const CLLocationAccuracy kGoodFetchAccuracy = 50;

@interface BHTSensitiveZones ()
@property (atomic, readwrite) BHTSensitiveZoneStatus status;
@property (nonatomic, readwrite, nullable) NSString* insidePlaceName;
@property (atomic, readwrite) BOOL forcesWarnings;
@property (nonatomic, strong, nullable) CLLocationManager* manager;
@property (nonatomic, strong) NSMutableArray<void (^)(CLLocation*)>* pendingFetches;
@property (nonatomic, strong, nullable) CLLocation* bestFetchLocation;
@property (nonatomic) NSUInteger fetchGeneration;
@property (nonatomic) BOOL updating;
@end

@implementation BHTSensitiveZones

+ (instancetype)shared {
    static BHTSensitiveZones* shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [self new];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _pendingFetches = [NSMutableArray array];

        // Until the first fix arrives, a configured setup errs on the side of
        // showing warnings; timelines can render before reload gets to run.
        BHTSensitiveZoneStatus initial = [self configuredStatus];
        _status = initial == BHTSensitiveZoneStatusOutside ? BHTSensitiveZoneStatusLocating : initial;
        _forcesWarnings = [BHTSensitiveZones statusForcesWarnings:_status];

        NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
        [center addObserver:self
                   selector:@selector(reload)
                       name:UIApplicationDidBecomeActiveNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(applicationDidEnterBackground)
                       name:UIApplicationDidEnterBackgroundNotification
                     object:nil];

        // Never synchronously: a reload can post the change notification, and
        // an observer reaching for +shared inside its dispatch_once would
        // deadlock.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reload];
        });
    }
    return self;
}

#pragma mark - Settings

+ (BOOL)enabled {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:BHTSensitiveZonesEnabledKey];
    return value ? [value boolValue] : YES;
}

+ (void)setEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:BHTSensitiveZonesEnabledKey];
    [[self shared] reload];
}

+ (NSArray<NSDictionary*>*)places {
    NSArray* stored = [NSUserDefaults.standardUserDefaults arrayForKey:BHTSensitiveZonesPlacesKey];
    NSMutableArray* places = [NSMutableArray array];
    for (id place in stored) {
        if ([place isKindOfClass:NSDictionary.class] &&
            [place[@"lat"] isKindOfClass:NSNumber.class] &&
            [place[@"lon"] isKindOfClass:NSNumber.class]) {
            [places addObject:place];
        }
    }
    return places;
}

+ (void)setPlaces:(NSArray<NSDictionary*>*)places {
    [NSUserDefaults.standardUserDefaults setObject:places forKey:BHTSensitiveZonesPlacesKey];
    [[self shared] reload];
}

+ (NSInteger)radius {
    NSInteger radius = [NSUserDefaults.standardUserDefaults integerForKey:BHTSensitiveZonesRadiusKey];
    return radius > 0 ? radius : kDefaultRadius;
}

+ (void)setRadius:(NSInteger)radius {
    [NSUserDefaults.standardUserDefaults setInteger:radius forKey:BHTSensitiveZonesRadiusKey];
    [[self shared] reload];
}

+ (NSArray<NSNumber*>*)radiusChoices {
    return @[@50, @100, @200, @300, @500, @1000, @2000];
}

+ (NSDictionary*)placeWithName:(NSString*)name coordinate:(CLLocationCoordinate2D)coordinate {
    return @{@"name": name ?: @"", @"lat": @(coordinate.latitude), @"lon": @(coordinate.longitude)};
}

#pragma mark - Status

+ (BOOL)statusForcesWarnings:(BHTSensitiveZoneStatus)status {
    return status == BHTSensitiveZoneStatusNeedsPermission ||
           status == BHTSensitiveZoneStatusLocating || status == BHTSensitiveZoneStatusInside;
}

// Off or NoPlaces when there's nothing to watch, Outside when there is (the
// location then decides).
- (BHTSensitiveZoneStatus)configuredStatus {
    if (![BHTSettings boolForKey:kWarningsOptionKey] || !BHTSensitiveZones.enabled) {
        return BHTSensitiveZoneStatusOff;
    }
    if (BHTSensitiveZones.places.count == 0) {
        return BHTSensitiveZoneStatusNoPlaces;
    }
    return BHTSensitiveZoneStatusOutside;
}

- (void)setStatus:(BHTSensitiveZoneStatus)status placeName:(nullable NSString*)placeName {
    BOOL changed = status != self.status ||
                   !(placeName == self.insidePlaceName || [placeName isEqualToString:self.insidePlaceName]);
    self.insidePlaceName = placeName;
    self.status = status;
    self.forcesWarnings = [BHTSensitiveZones statusForcesWarnings:status];

    if (changed) {
        [NSNotificationCenter.defaultCenter postNotificationName:BHTSensitiveZonesDidChangeNotification
                                                          object:self];
    }
}

- (void)updateSummary {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSUInteger count = BHTSensitiveZones.places.count;
    if (!BHTSensitiveZones.enabled || count == 0) {
        [defaults removeObjectForKey:BHTSensitiveZonesSummaryKey];
        return;
    }

    NSString* format = [[BHTBundle sharedBundle] localizedStringForKey:@"SENSITIVE_ZONES_SUMMARY_FORMAT"];
    [defaults setObject:[NSString stringWithFormat:format, (long)count, (long)BHTSensitiveZones.radius]
                 forKey:BHTSensitiveZonesSummaryKey];
}

#pragma mark - Watching

- (CLLocationManager*)locationManager {
    if (!self.manager) {
        self.manager = [CLLocationManager new];
        self.manager.delegate = self;
        self.manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;
        self.manager.distanceFilter = 20;
        self.manager.pausesLocationUpdatesAutomatically = NO;
    }
    return self.manager;
}

- (CLAuthorizationStatus)authorizationStatus {
    return self.locationManager.authorizationStatus;
}

- (void)requestPermission {
    if (self.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
        [self.locationManager requestWhenInUseAuthorization];
    }
}

- (BOOL)isAuthorized {
    CLAuthorizationStatus status = self.authorizationStatus;
    return status == kCLAuthorizationStatusAuthorizedWhenInUse ||
           status == kCLAuthorizationStatusAuthorizedAlways;
}

- (void)reload {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reload];
        });
        return;
    }

    [self updateSummary];

    BHTSensitiveZoneStatus configured = [self configuredStatus];
    if (configured != BHTSensitiveZoneStatusOutside) {
        [self setStatus:configured placeName:nil];
        [self updateLocationUpdates];
        return;
    }

    CLAuthorizationStatus authorization = self.authorizationStatus;
    if (authorization == kCLAuthorizationStatusNotDetermined) {
        // The authorization callback reloads once the user answers.
        [self requestPermission];
        [self setStatus:BHTSensitiveZoneStatusLocating placeName:nil];
        return;
    }
    if (![self isAuthorized]) {
        [self setStatus:BHTSensitiveZoneStatusNeedsPermission placeName:nil];
        [self updateLocationUpdates];
        return;
    }

    [self updateLocationUpdates];
    [self evaluateLocation:self.locationManager.location];
}

- (BOOL)wantsUpdates {
    if (self.pendingFetches.count > 0) {
        return YES;
    }
    return [self configuredStatus] == BHTSensitiveZoneStatusOutside && [self isAuthorized] &&
           UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

- (void)updateLocationUpdates {
    BOOL wants = [self wantsUpdates];
    if (wants && !self.updating) {
        [self.locationManager startUpdatingLocation];
        self.updating = YES;
    } else if (!wants && self.updating) {
        [self.locationManager stopUpdatingLocation];
        self.updating = NO;
    }
}

- (void)applicationDidEnterBackground {
    [self updateLocationUpdates];
}

- (void)evaluateLocation:(nullable CLLocation*)location {
    if ([self configuredStatus] != BHTSensitiveZoneStatusOutside || ![self isAuthorized]) {
        return;
    }

    if (!location || location.horizontalAccuracy < 0 ||
        -location.timestamp.timeIntervalSinceNow > kMaxLocationAge) {
        [self setStatus:BHTSensitiveZoneStatusLocating placeName:nil];
        return;
    }

    // The fix's uncertainty counts against it: in range as soon as any part
    // of its accuracy circle reaches a place's range.
    CLLocationDistance reach = BHTSensitiveZones.radius + location.horizontalAccuracy;
    if (self.status == BHTSensitiveZoneStatusInside) {
        reach += kExitMargin;
    }

    for (NSDictionary* place in BHTSensitiveZones.places) {
        CLLocation* center = [[CLLocation alloc] initWithLatitude:[place[@"lat"] doubleValue]
                                                        longitude:[place[@"lon"] doubleValue]];
        if ([location distanceFromLocation:center] <= reach) {
            NSString* name = [place[@"name"] isKindOfClass:NSString.class] ? place[@"name"] : @"";
            [self setStatus:BHTSensitiveZoneStatusInside placeName:name];
            return;
        }
    }

    [self setStatus:BHTSensitiveZoneStatusOutside placeName:nil];
}

#pragma mark - Current location for new places

- (void)fetchCurrentLocation:(void (^)(CLLocation* _Nullable))completion {
    CLLocation* cached = self.locationManager.location;
    if (cached && cached.horizontalAccuracy >= 0 && cached.horizontalAccuracy <= kGoodFetchAccuracy &&
        -cached.timestamp.timeIntervalSinceNow < 30) {
        completion(cached);
        return;
    }

    if (self.authorizationStatus == kCLAuthorizationStatusDenied ||
        self.authorizationStatus == kCLAuthorizationStatusRestricted) {
        completion(nil);
        return;
    }

    [self.pendingFetches addObject:[completion copy]];
    if (self.pendingFetches.count > 1) {
        return;
    }

    self.bestFetchLocation = nil;
    NSUInteger generation = ++self.fetchGeneration;
    [self requestPermission];
    [self updateLocationUpdates];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFetchTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       if (generation == self.fetchGeneration) {
                           [self finishFetchesWithLocation:self.bestFetchLocation];
                       }
                   });
}

- (void)finishFetchesWithLocation:(nullable CLLocation*)location {
    NSArray* fetches = [self.pendingFetches copy];
    [self.pendingFetches removeAllObjects];
    self.bestFetchLocation = nil;
    self.fetchGeneration++;
    [self updateLocationUpdates];

    for (id fetch in fetches) {
        void (^completion)(CLLocation*) = fetch;
        completion(location);
    }
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManagerDidChangeAuthorization:(CLLocationManager*)manager {
    if (self.pendingFetches.count > 0 && ![self isAuthorized] &&
        self.authorizationStatus != kCLAuthorizationStatusNotDetermined) {
        [self finishFetchesWithLocation:nil];
    }
    [self reload];
}

- (void)locationManager:(CLLocationManager*)manager didUpdateLocations:(NSArray<CLLocation*>*)locations {
    CLLocation* location = locations.lastObject;
    if (!location) {
        return;
    }

    if (self.pendingFetches.count > 0 && location.horizontalAccuracy >= 0) {
        if (!self.bestFetchLocation ||
            location.horizontalAccuracy < self.bestFetchLocation.horizontalAccuracy) {
            self.bestFetchLocation = location;
        }
        if (location.horizontalAccuracy <= kGoodFetchAccuracy) {
            [self finishFetchesWithLocation:location];
        }
    }

    [self evaluateLocation:location];
}

- (void)locationManager:(CLLocationManager*)manager didFailWithError:(NSError*)error {
    if ([error.domain isEqualToString:kCLErrorDomain] && error.code == kCLErrorDenied) {
        if (self.pendingFetches.count > 0) {
            [self finishFetchesWithLocation:nil];
        }
        [self reload];
    }
}

@end

BOOL BHTSensitiveWarningsSuppressed(void) {
    if (![BHTSettings boolForKey:kWarningsOptionKey]) {
        return NO;
    }
    return !BHTSensitiveZones.shared.forcesWarnings;
}

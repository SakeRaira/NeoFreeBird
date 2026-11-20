//
//  BHTSensitiveZones.h
//  NeoFreeBird
//
//  Places where "No sensitive content warnings" steps aside: while the device
//  is within range of one of them the warnings come back, and they go away
//  again once it leaves. Location is only watched while the app is active and
//  never leaves the device.
//

#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BHTSensitiveZoneStatus) {
    // The feature, or the warnings option it overrides, is off.
    BHTSensitiveZoneStatusOff,
    BHTSensitiveZoneStatusNoPlaces,
    // No location permission. Warnings are shown, to be safe.
    BHTSensitiveZoneStatusNeedsPermission,
    // No recent enough location yet. Warnings are shown, to be safe.
    BHTSensitiveZoneStatusLocating,
    BHTSensitiveZoneStatusInside,
    BHTSensitiveZoneStatusOutside,
};

// Posted on the main queue whenever the status changes.
extern NSNotificationName const BHTSensitiveZonesDidChangeNotification;

// Settings keys.
extern NSString* const BHTSensitiveZonesEnabledKey;  // BOOL, on by default
extern NSString* const BHTSensitiveZonesPlacesKey;   // [{name, lat, lon}]
extern NSString* const BHTSensitiveZonesRadiusKey;   // meters
extern NSString* const BHTSensitiveZonesSummaryKey;  // subtitle for the settings row

@interface BHTSensitiveZones : NSObject <CLLocationManagerDelegate>

+ (instancetype)shared;

@property (atomic, readonly) BHTSensitiveZoneStatus status;
// Name of the place the device is in range of, when status is Inside.
@property (nonatomic, readonly, nullable) NSString* insidePlaceName;
// Whether warnings have to be shown right now despite the warnings option.
// Safe to read from any thread.
@property (atomic, readonly) BOOL forcesWarnings;

@property (class, nonatomic, readonly) BOOL enabled;
@property (class, nonatomic, readonly) NSArray<NSDictionary*>* places;
@property (class, nonatomic, readonly) NSInteger radius;
@property (class, nonatomic, readonly) NSArray<NSNumber*>* radiusChoices;

+ (void)setEnabled:(BOOL)enabled;
+ (void)setPlaces:(NSArray<NSDictionary*>*)places;
+ (void)setRadius:(NSInteger)radius;
+ (NSDictionary*)placeWithName:(NSString*)name coordinate:(CLLocationCoordinate2D)coordinate;

// Re-reads the settings and starts or stops watching the location.
- (void)reload;

@property (nonatomic, readonly) CLAuthorizationStatus authorizationStatus;
- (void)requestPermission;

// One fix good enough to save as a place, or nil if none came in time.
- (void)fetchCurrentLocation:(void (^)(CLLocation* _Nullable location))completion;

@end

// Whether "No sensitive content warnings" should take effect right now: the
// option is on and no registered place forces the warnings back.
BOOL BHTSensitiveWarningsSuppressed(void);

NS_ASSUME_NONNULL_END

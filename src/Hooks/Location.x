//
//  Location.x
//  NeoFreeBird
//
//  Keeps X from reading where you are. X fetches the device's location again
//  and again while it's open (T1GeoDataProvider, through TSALocationManager)
//  and hands it to search, auto geotagging and other features. Every reader
//  goes through a per-account access check X already has for when location
//  isn't allowed, so this answers that check with "not allowed" and keeps the
//  shared location manager from starting at all.
//
//  NeoFreeBird's own "Show warnings at places" (BHTSensitiveZones) keeps its
//  own CLLocationManager and is not affected.
//
//  Read once per launch: start and stop calls have to match, which a setting
//  changing mid-session could break, so changes apply after a restart.
//

#import "HookHelpers.h"

static BOOL XLocationBlocked;

// MARK: - The access check

%hook TFNGeoDataAccountAccessController

- (BOOL)isAccessAllowed {
    return XLocationBlocked ? NO : %orig;
}

- (BOOL)isUsingRetainedGeoDataAllowed {
    return XLocationBlocked ? NO : %orig;
}

%end

// MARK: - Providers

%hook TFNAccessControlledGeoDataProvider

- (BOOL)isEnabled {
    return XLocationBlocked ? NO : %orig;
}

- (BOOL)isCachedLocationAvailable {
    return XLocationBlocked ? NO : %orig;
}

- (id)currentLocation {
    return XLocationBlocked ? nil : %orig;
}

- (BOOL)isUsingRetainedGeoDataAllowed {
    return XLocationBlocked ? NO : %orig;
}

- (void)startUpdates {
    if (XLocationBlocked) {
        return;
    }
    %orig;
}

%end

%hook T1SafeStartupGeoDataProvider

- (BOOL)isEnabled {
    return XLocationBlocked ? NO : %orig;
}

- (BOOL)isCachedLocationAvailable {
    return XLocationBlocked ? NO : %orig;
}

- (id)currentLocation {
    return XLocationBlocked ? nil : %orig;
}

- (BOOL)isUsingRetainedGeoDataAllowed {
    return XLocationBlocked ? NO : %orig;
}

- (void)startUpdates {
    if (XLocationBlocked) {
        return;
    }
    %orig;
}

%end

// The app-wide provider behind both of the above. Its periodic refresh is a
// chain of timed updates started at launch.
%hook T1GeoDataProvider

- (BOOL)isEnabled {
    return XLocationBlocked ? NO : %orig;
}

- (BOOL)isCachedLocationAvailable {
    return XLocationBlocked ? NO : %orig;
}

- (id)currentLocation {
    return XLocationBlocked ? nil : %orig;
}

- (BOOL)isUsingRetainedGeoDataAllowed {
    return XLocationBlocked ? NO : %orig;
}

- (void)startUpdates {
    if (XLocationBlocked) {
        return;
    }
    %orig;
}

- (void)_startChainedLocationUpdate {
    if (XLocationBlocked) {
        return;
    }
    %orig;
}

- (void)_restartChainedLocationUpdate {
    if (XLocationBlocked) {
        return;
    }
    %orig;
}

%end

// MARK: - The location manager

// Counts its subscribers and runs CoreLocation while there are any. With both
// halves skipped the count stays at zero and the GPS is never switched on.
%hook TSALocationManager

- (void)startUpdatingLocation {
    if (XLocationBlocked) {
        return;
    }
    %orig;
}

- (void)stopUpdatingLocation {
    if (XLocationBlocked) {
        return;
    }
    %orig;
}

%end

// MARK: - Auto geotagging

// Tags a new post with the place the last one was tagged with.
%hook TFNTwitterAutoGeotagger

- (void)performAutotag {
    if (XLocationBlocked) {
        return;
    }
    %orig;
}

%end

%ctor {
    XLocationBlocked = [BHTSettings boolForKey:@"block_x_location"];
    %init;
}

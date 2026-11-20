//
//  TimelineFilters.x
//  NeoFreeBird
//
//  Keeps topic snoozes (and topic/country filters) on the For You tab from
//  switching themselves off after the server's reset period.
//
//  The reset is driven by TwitterHome.HomeTimelineFilterAutoResetCoordinator,
//  a pure Swift object that reads the period through a closure and resets the
//  filter from an NSTimer, so it can't be hooked itself. The period comes from
//  the co_timeline_reset_period_minutes feature switch, which FeatureSwitches.x
//  stretches past any realistic session. The typed accessors below cover reads
//  that go through Objective-C instead of the keyed switch funnels; the
//  iOS-only "reset on app background" and "auto-resets in ..." switches have no
//  known keys, so these accessors are the only seam for them.
//

#import "HookHelpers.h"

static BOOL KeepTimelineFilters(void) {
    return [BHTSettings boolForKey:@"keep_timeline_filters"];
}

%hook TwitterHomeFeatures

- (long long)filteredTimelineResetPeriodMinutes {
    return KeepTimelineFilters() ? BHTTimelineFilterNeverResetMinutes : %orig;
}

// Background mode resets the filter when the app goes to the background
// instead of on the wall clock; keep it on the wall clock, which never fires.
- (BOOL)isFilteredTimelineResetOnAppBackgroundEnabled {
    return KeepTimelineFilters() ? NO : %orig;
}

// The filter sheet's "resets in ..." note would no longer be true.
- (BOOL)isFilteredTimelineShowAutoResetTextEnabled {
    return KeepTimelineFilters() ? NO : %orig;
}

%end

%hook THFHomeTimelineFilterStateProvider

- (long long)resetPeriodMinutes {
    return KeepTimelineFilters() ? BHTTimelineFilterNeverResetMinutes : %orig;
}

- (BOOL)isShowAutoResetTextEnabled {
    return KeepTimelineFilters() ? NO : %orig;
}

%end

//
//  TimelineFilters.x
//  NeoFreeBird
//
//  Keeps topic snoozes (and topic/country filters) on the For You tab from
//  switching themselves off.
//
//  X resets them one of two ways, picked by the server per account: on the
//  wall clock once co_timeline_reset_period_minutes has passed, or as the app
//  goes to the background. Either way stays the way X picked it: the period
//  is stretched past any session (FeatureSwitches.m, and the typed accessors
//  below for reads that go through Objective-C), and the background reset is
//  skipped. Forcing the mode itself (wall clock instead of background) only
//  reached X's Objective-C side; its Swift side read the switch and kept the
//  other mode, the two disagreed on whether the filter was still on, and X
//  refused to refresh ("Can't load posts") on every Home tab until the app
//  was relaunched.
//
//  The reset itself is driven by TwitterHome.HomeTimelineFilterAutoResetCoordinator,
//  a pure Swift object that reads the period through a closure and resets the
//  filter from an NSTimer, so it can't be hooked itself.
//

#import "HookHelpers.h"

static BOOL KeepTimelineFilters(void) {
    return [BHTSettings boolForKey:@"keep_timeline_filters"];
}

%hook TwitterHomeFeatures

- (long long)filteredTimelineResetPeriodMinutes {
    return KeepTimelineFilters() ? BHTTimelineFilterNeverResetMinutes : %orig;
}

// The filter sheet's "resets in ..." note would no longer be true.
- (BOOL)isFilteredTimelineShowAutoResetTextEnabled {
    return KeepTimelineFilters() ? NO : %orig;
}

// X refuses to refresh a filtered timeline it doesn't count as active any
// more; a kept filter stays refreshable whatever X counts.
- (BOOL)isFilteredTimelineRefreshRequiresActiveFilterEnabled {
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

// Where the background mode clears the filter as the app leaves the screen;
// coming back finds it as it was, as if the app had stayed open.
- (void)handleDidEnterBackground {
    if (KeepTimelineFilters()) {
        return;
    }
    %orig;
}

%end

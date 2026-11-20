//
//  Performance.x
//  NeoFreeBird
//
//  Lightweight mode: stops diagnostics X runs in the background for its own
//  measurements and that do nothing for the person using the app. Each one
//  goes through a gate X already has (a sampling decision, an enable check,
//  a start call), so turning it off takes the path X takes when the
//  diagnostic simply isn't selected. Most of these are set up at launch, so
//  changes apply after a restart.
//

#import "HookHelpers.h"

static BOOL LightweightOption(NSString* key) {
    return [BHTSettings boolForKey:key];
}

// MARK: - Frame drop reports

// T1FrameRateReporter watches every frame and, on a drop or a stall, records
// the main thread's call stack to report it, which costs most right when the
// app is already struggling. The frame rate monitor itself stays: other code
// reads the current refresh rate from it.

%hook T1FrameRateReporter

- (void)enableCallStackReportingWithFrameDropEventReporter:(id)reporter {
    if (LightweightOption(@"perf_no_frame_drop_reports")) {
        return;
    }
    %orig;
}

- (void)enableStallTracking:(BOOL)tracking withThreshold:(unsigned long long)threshold {
    %orig(LightweightOption(@"perf_no_frame_drop_reports") ? NO : tracking, threshold);
}

- (void)_t1_reportStackTraceWithDeltaFPS:(double)fps {
    if (LightweightOption(@"perf_no_frame_drop_reports")) {
        return;
    }
    %orig;
}

- (void)_t1_reportFrameDropEventWithCallStackReturnAddresses:(id)addresses {
    if (LightweightOption(@"perf_no_frame_drop_reports")) {
        return;
    }
    %orig;
}

%end

%hook TDTVariableFrameRateMonitor

- (void)startStackTraceRecording {
    if (LightweightOption(@"perf_no_frame_drop_reports")) {
        return;
    }
    %orig;
}

%end

// MARK: - Performance tracing

// Timing spans for launch, screen loads, network requests and tweet cell
// layout, reported through scribe. Every trace asks its sampling policy
// first; a policy that never samples is the same as never being picked.

%hook T1PerformanceTracingFeature

+ (BOOL)isEnabled {
    return LightweightOption(@"perf_no_tracing") ? NO : %orig;
}

%end

%hook TFSTraceSamplingPolicy

- (BOOL)canStartTrace {
    return LightweightOption(@"perf_no_tracing") ? NO : %orig;
}

%end

// Zipkin trace headers added to API requests.
%hook XApiZipkinTracing

- (BOOL)isEnabled {
    return LightweightOption(@"perf_no_tracing") ? NO : %orig;
}

- (void)setIsEnabled:(BOOL)enabled {
    %orig(LightweightOption(@"perf_no_tracing") ? NO : enabled);
}

%end

// Share of tweet cell layouts that get traced.
%hook T1StandardStatusView

+ (long long)layoutTracingSamplingFractionalPercentage {
    return LightweightOption(@"perf_no_tracing") ? 0 : %orig;
}

%end

// MARK: - Thread diagnostics

// Periodically logs the state of every thread in the app.
%hook TLTThreadDiagnostics

+ (void)startPeriodicLogging {
    if (LightweightOption(@"perf_no_thread_diagnostics")) {
        return;
    }
    %orig;
}

%end

// MARK: - Watchdogs

// Timers that watch launch, foregrounding and the main thread for hangs and,
// past a limit, report them and can end the app on purpose (-crash) so the
// hang shows up as a crash report.

%hook TFNTwitterWatchdog

+ (BOOL)shouldEnableWatchdog {
    return LightweightOption(@"perf_no_watchdogs") ? NO : %orig;
}

// Should one run anyway, it doesn't get to end the app. The launch and
// default watchdogs override this, so they are covered below too.
- (void)crash {
    if (LightweightOption(@"perf_no_watchdogs")) {
        return;
    }
    %orig;
}

%end

%hook TFNTwitterLaunchWatchdog

- (void)crash {
    if (LightweightOption(@"perf_no_watchdogs")) {
        return;
    }
    %orig;
}

%end

%hook TFNTwitterDefaultWatchdog

- (void)crash {
    if (LightweightOption(@"perf_no_watchdogs")) {
        return;
    }
    %orig;
}

%end

%hook TLTWatchdog

- (void)start {
    if (LightweightOption(@"perf_no_watchdogs")) {
        return;
    }
    %orig;
}

%end

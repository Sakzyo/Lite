#pragma once
#import <Cocoa/Cocoa.h>
// Test-only tally of whether the window under test could receive input. The harness
// names this in a failed run, because another app's window can stop a page's timers
// and input and look like a regression. It never decides a check.
static inline void LTSampleWindowState(NSMutableDictionary *results, NSWindow *window) {
    if (!window.visible) return;
    NSMutableDictionary *state = results[@"windowState"] ?: [NSMutableDictionary new];
    results[@"windowState"] = state;
    state[@"samples"] = @([state[@"samples"] integerValue] + 1);
    if (!NSApp.active) state[@"inactive"] = @([state[@"inactive"] integerValue] + 1);
    if (!(window.occlusionState & NSWindowOcclusionStateVisible))
        state[@"covered"] = @([state[@"covered"] integerValue] + 1);
}

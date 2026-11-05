#import <Foundation/Foundation.h>
#import "../lite/model/LTStore.h"
#include <math.h>
#include <objc/message.h>
static const double FrameBudgetMs = 1000.0 / 60;
static const int ProbeSaves = 40;
static const NSTimeInterval ProbeSpacing = 0.1, ProbeTick = 0.002;
static double Now(void) { return NSProcessInfo.processInfo.systemUptime; }
static NSDictionary *Stats(NSArray<NSNumber *> *values) {
    NSArray *sorted = [values sortedArrayUsingSelector:@selector(compare:)];
    double median = ([sorted[(sorted.count - 1) / 2] doubleValue] + [sorted[sorted.count / 2] doubleValue]) / 2;
    return @{ @"median_ms": @(median), @"p95_ms": sorted[(NSUInteger)ceil(sorted.count * 0.95) - 1], @"samples_ms": values };
}
// Runs saves spaced like user actions on a live main run loop, and ticks that loop far faster
// than a frame. A gap between ticks is time the main thread could not have drawn or handled input.
// The same harness builds against the old synchronous store: it falls back when commit:completion: is absent.
@interface FrameProbe : NSObject
- (NSDictionary *)run:(LTStore *)store;
@end
@implementation FrameProbe {
    LTStore *_store;
    NSMutableArray *_calls, *_gaps, *_durable;
    double _lastTick;
    int _started, _finished;
}
- (void)tick:(NSTimer *)timer {
    double now = Now();
    if (_lastTick > 0) [_gaps addObject:@((now - _lastTick) * 1000)];
    _lastTick = now;
}
- (void)save:(NSTimer *)timer {
    if (_started == ProbeSaves) { [timer invalidate]; return; }
    int index = _started++;
    void (^change)(LTProfile *) = ^(LTProfile *p) { p.nodes.firstObject.customTitle = [NSString stringWithFormat:@"Probe %d", index]; };
    double start = Now();
    SEL queued = NSSelectorFromString(@"commit:completion:");
    if ([_store respondsToSelector:queued]) {
        void (^done)(NSError *) = ^(NSError *error) {
            if (error) { NSLog(@"%@", error); exit(1); }
            [self->_durable addObject:@((Now() - start) * 1000)];
            self->_finished++;
        };
        ((void (*)(id, SEL, id, id))objc_msgSend)(_store, queued, change, done);
    } else {
        NSError *error = nil;
        if (![_store commit:change error:&error]) { NSLog(@"%@", error); exit(1); }
        [_durable addObject:@((Now() - start) * 1000)];
        _finished++;
    }
    [_calls addObject:@((Now() - start) * 1000)];
}
- (NSDictionary *)run:(LTStore *)store {
    _store = store; _calls = [NSMutableArray new]; _gaps = [NSMutableArray new]; _durable = [NSMutableArray new];
    NSTimer *ticks = [NSTimer scheduledTimerWithTimeInterval:ProbeTick target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:ProbeSpacing target:self selector:@selector(save:) userInfo:nil repeats:YES];
    // Each pass of the loop is bounded so the deadline holds even if a run-loop source stays busy.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:ProbeSaves * ProbeSpacing + 30];
    while (_finished < ProbeSaves && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    [ticks invalidate];
    if (_finished < ProbeSaves) { NSLog(@"Frame probe timed out after %d saves", _finished); exit(1); }
    NSUInteger missed = 0; double worst = 0;
    for (NSNumber *gap in _gaps) { worst = MAX(worst, gap.doubleValue); if (gap.doubleValue > FrameBudgetMs) missed++; }
    return @{@"saves": @(ProbeSaves), @"mode": [store respondsToSelector:NSSelectorFromString(@"commit:completion:")] ? @"queued" : @"synchronous",
             @"frame_budget_ms": @(FrameBudgetMs), @"main_call": Stats(_calls), @"saved_durably_after": Stats(_durable),
             @"largest_main_thread_gap_ms": @(worst), @"gaps_over_budget": @(missed), @"ticks": @(_gaps.count)};
}
@end
int main(void) { @autoreleasepool {
    NSMutableArray *rows = [NSMutableArray new];
    for (NSNumber *count in @[@2000, @10000]) { @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:LTUUID()];
        NSString *path = [directory stringByAppendingPathComponent:@"Lite.sqlite"];
        NSError *error = nil;
        LTStore *store = [[LTStore alloc] initWithPath:path error:&error];
        BOOL seeded = [store commit:^(LTProfile *p) {
            for (NSInteger i = 0; i < count.integerValue; i++) {
                LTNode *n = [LTNode new]; n.identifier = [NSString stringWithFormat:@"node-%ld", (long)i];
                n.spaceID = p.activeSpaceID; n.kind = @"pinned"; n.title = n.identifier;
                n.url = @"https://example.invalid/profile-fixture"; n.pinnedURL = n.url; n.order = i;
                [p.nodes addObject:n];
            }
        } error:&error];
        if (!seeded) { NSLog(@"%@", error); return 1; }
        NSMutableArray *commits = [NSMutableArray new], *opens = [NSMutableArray new], *serialization = [NSMutableArray new];
        NSMutableArray *copies = [NSMutableArray new], *validations = [NSMutableArray new], *unsorted = [NSMutableArray new];
        for (NSInteger i = 0; i < 20; i++) { @autoreleasepool {
            double start = Now();
            if (![store commit:^(LTProfile *p) { p.nodes.firstObject.customTitle = [NSString stringWithFormat:@"Edit %ld", (long)i]; } error:&error]) { NSLog(@"%@", error); return 1; }
            [commits addObject:@((Now()-start)*1000)];
            start = Now();
            [NSJSONSerialization dataWithJSONObject:store.profile.JSON options:NSJSONWritingSortedKeys error:&error];
            [serialization addObject:@((Now()-start)*1000)];
            start = Now(); LTProfile *copy = [store.profile transactionCopy];
            [copies addObject:@((Now()-start)*1000)];
            start = Now();
            if (![copy validate:&error]) { NSLog(@"%@", error); return 1; }
            [validations addObject:@((Now()-start)*1000)];
            start = Now(); [NSJSONSerialization dataWithJSONObject:copy.JSON options:0 error:&error];
            [unsorted addObject:@((Now()-start)*1000)];
            start = Now(); LTStore *reopened = [[LTStore alloc] initWithPath:path error:&error];
            [opens addObject:@((Now()-start)*1000)];
            if (reopened.profile.nodes.count != count.unsignedIntegerValue) return 2;
        }}
        NSDictionary *probe = [[FrameProbe new] run:store];
        [rows addObject:@{@"nodes": count, @"commit": Stats(commits), @"open": Stats(opens), @"sorted_serialization": Stats(serialization),
                          @"copy": Stats(copies), @"validate": Stats(validations), @"serialize": Stats(unsorted), @"frame_probe": probe}];
        store = nil; [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    }}
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"workload": @"20 durable commits editing one title, then 40 saves 100 ms apart on a live main run loop with a 2 ms tick; fixed synthetic pinned nodes; -O3", @"results": rows} options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
}}

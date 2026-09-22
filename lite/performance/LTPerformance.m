#import "LTPerformance.h"
LTLifecycleAction LTPolicy(NSString *mode, double idle, BOOL protectedPage, BOOL pressure) {
    if (protectedPage)
        return LTLifecycleKeep;
    double freeze = [mode isEqual:@"Balanced"] ? 300 : [mode isEqual:@"Maximum Saving"] ? 30 : 120;
    double discard = [mode isEqual:@"Balanced"]         ? 1800
                     : [mode isEqual:@"Maximum Saving"] ? 180
                                                        : 600;
    if (pressure || idle >= discard)
        return LTLifecycleDiscard;
    if (idle >= freeze)
        return LTLifecycleFreeze;
    return LTLifecycleKeep;
}
@implementation LTPerformance {
    NSTimer *_timer;
    dispatch_source_t _pressure;
}
- (void)start {
    __weak typeof(self) weak = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:30
                                             repeats:YES
                                               block:^(NSTimer *t) {
                                                 [weak reclaim:NO];
                                               }];
    _timer.tolerance = 10;
    _pressure = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, dispatch_get_main_queue());
    dispatch_source_set_event_handler(_pressure, ^{
      [weak reclaim:YES];
    });
    dispatch_resume(_pressure);
}
- (void)stop {
    [_timer invalidate];
    _timer = nil;
    if (_pressure) {
        dispatch_source_cancel(_pressure);
        _pressure = nil;
    }
}
- (void)dealloc {
    [self stop];
}
- (void)reclaim:(BOOL)pressure {
    double now = NSDate.date.timeIntervalSince1970;
    for (LTPage *p in self.pages()) {
        BOOL protect = p.visible || p.loading || p.dirty || p.audible || p.capturing ||
                       p.downloading || p.keepAwake || p.pictureInPicture || p.closing;
        LTLifecycleAction a = LTPolicy(self.mode(), now - p.lastVisible, protect, pressure);
        if (a == LTLifecycleDiscard && p.alive)
            [p discard];
        else if (a == LTLifecycleFreeze)
            [p freeze:YES];
    }
}
@end

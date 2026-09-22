#import "LTSmoke.h"
#import "../browser/LTEngine.h"
#import "../macos/LTPasswords.h"
#import "../performance/LTPerformance.h"
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
static NSDictionary *ResourceSample(void) {
    NSMutableArray<NSNumber *> *pids = [NSMutableArray arrayWithObject:@(getpid())];
    for (NSUInteger i = 0; i < pids.count; i++) {
        pid_t children[256];
        int count = proc_listchildpids(pids[i].intValue, children, sizeof(children));
        for (int j = 0; j < MIN(count, 256); j++)
            if (children[j] > 0 && ![pids containsObject:@(children[j])])
                [pids addObject:@(children[j])];
    }
    uint64_t rss = 0, footprint = 0, cpu = 0;
    int measured = 0;
    for (NSNumber *pid in pids) {
        struct rusage_info_v4 info = {};
        if (proc_pid_rusage(pid.intValue, RUSAGE_INFO_V4, (rusage_info_t *)&info) == 0) {
            rss += info.ri_resident_size;
            footprint += info.ri_phys_footprint;
            cpu += info.ri_user_time + info.ri_system_time;
            measured++;
        }
    }
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    return @{
        @"processes" : @(measured),
        @"rssMiB" : @(rss / 1048576.0),
        @"footprintMiB" : @(footprint / 1048576.0),
        @"cpuSeconds" : @(cpu * (double)timebase.numer / timebase.denom / 1e9),
        @"time" : @(NSDate.date.timeIntervalSince1970)
    };
}
@interface LTSmoke : NSObject <LTPageDelegate>
@property NSWindow *window;
@property LTPage *normal;
@property LTPage *privatePage;
@property LTBrowserContext *normalContext;
@property LTBrowserContext *privateContext;
@property NSMutableDictionary *results;
@property NSString *origin;
@property NSString *output;
@property NSInteger stage;
@property double started;
@property NSTimer *timer;
@property NSMutableArray<LTPage *> *benchmarkPages;
@property double settledAt;
- (void)begin;
@end
static LTSmoke *running;
@implementation LTSmoke
- (void)begin {
    _results = [NSMutableDictionary new];
    _results[@"processID"] = @(getpid());
    _results[@"os"] = NSProcessInfo.processInfo.operatingSystemVersionString;
    _results[@"physicalMemoryGiB"] = @(NSProcessInfo.processInfo.physicalMemory / 1073741824.0);
    _started = NSDate.date.timeIntervalSince1970;
    _normalContext = [[LTBrowserContext alloc] initPrivate:NO];
    _privateContext = [[LTBrowserContext alloc] initPrivate:YES];
    _window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 640)
                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                              NSWindowStyleMaskResizable
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    _window.title = @"Lite — Engine Verification";
    _window.releasedWhenClosed = NO;
    _normal = [[LTPage alloc] initWithID:@"normal" url:_origin context:_normalContext];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--lite-blocking-smoke"]) {
        _stage = 19;
        _normal.url = [_origin stringByAppendingString:@"content-blocking?phase=enabled"];
    }
    _normal.delegate = self;
    _normal.visible = YES;
    _window.contentView = _normal.container;
    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [_normal loadIfNeeded];
    LTBrowserTasks();
    __weak typeof(self) weak = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:.2
                                             repeats:YES
                                               block:^(NSTimer *t) {
                                                 [weak tick];
                                               }];
}
- (void)tick {
    if (NSDate.date.timeIntervalSince1970 - _started > 90) {
        _results[@"timeout"] = @YES;
        [self finish];
        return;
    }
    if (_stage == 0 && !_normal.loading && [_normal.title isEqual:@"Lite Test Page"]) {
        _stage = 1;
        _results[@"startupSeconds"] = @(NSDate.date.timeIntervalSince1970 - _started);
        [_normal evaluateForTesting:
                     @"(async()=>{document.cookie='liteSmoke=present; path=/; "
                     @"SameSite=Lax';localStorage.setItem('liteSmoke','present');let db=await new "
                     @"Promise((resolve,reject)=>{let "
                     @"r=indexedDB.open('lite-smoke',1);r.onsuccess=()=>resolve(r.result);r."
                     @"onerror=()=>reject(r.error)});db.close();let w=await "
                     @"WebAssembly.instantiate(new Uint8Array([0,97,115,109,1,0,0,0]));return "
                     @"{chromium:navigator.userAgent.includes('Chrome/"
                     @"154'),dom:document.querySelector('h1').textContent==='Lite browser "
                     @"test',indexedDB:!!db,wasm:!!w,webgl:!!document.createElement('canvas')."
                     @"getContext('webgl2'),fetch:await(await "
                     @"fetch('/"
                     @"echo')).text()==='lite-ok',cookie:document.cookie.includes('liteSmoke="
                     @"present')};})()"
                         completion:^(id value, BOOL success) {
                           self.results[@"webPlatform"] = value ?: @{};
                           self.results[@"webPlatformEvaluation"] = @(success);
                           self.stage = 2;
                           [self.normal navigate:[self.origin stringByAppendingString:@"second"]];
                         }];
    } else if (_stage == 2 && !_normal.loading && [_normal.title isEqual:@"Second Page"]) {
        _results[@"forwardNavigation"] = @(_normal.canBack);
        _stage = 3;
        [_normal back];
    } else if (_stage == 3 && !_normal.loading && [_normal.title isEqual:@"Lite Test Page"]) {
        _results[@"backNavigation"] = @(_normal.canForward);
        _stage = 4;
        _privatePage = [[LTPage alloc] initWithID:@"private" url:_origin context:_privateContext];
        _privatePage.delegate = self;
        _privatePage.visible = YES;
        _normal.container.frame = NSMakeRect(0, 0, 450, 640);
        _normal.container.autoresizingMask = NSViewHeightSizable;
        NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 640)];
        [root addSubview:_normal.container];
        _privatePage.container.frame = NSMakeRect(450, 0, 450, 640);
        _privatePage.container.autoresizingMask = NSViewHeightSizable;
        [root addSubview:_privatePage.container];
        _window.contentView = root;
        [_privatePage loadIfNeeded];
    } else if (_stage == 4 && !_privatePage.loading &&
               [_privatePage.title isEqual:@"Lite Test Page"]) {
        _stage = 5;
        _results[@"independentChromiumPages"] = @(LTLivingBrowserCount() == 2);
        [_privatePage
            evaluateForTesting:
                @"({cookie:document.cookie,storage:localStorage.getItem('liteSmoke')})"
                    completion:^(id value, BOOL success) {
                      self.results[@"privateIsolation"] =
                          @(success && ![value[@"cookie"] containsString:@"liteSmoke"] &&
                            value[@"storage"] == NSNull.null);
                      self.stage = 6;
                      [self.normal
                          evaluateForTesting:@"document.querySelector('input').value='edited';"
                                             @"document.querySelector('input').dispatchEvent(new "
                                             @"Event('input',{bubbles:true}));true"
                                  completion:^(id v, BOOL ok){
                                  }];
                    }];
    } else if (_stage == 6 && _normal.dirty) {
        _results[@"formProtectionSignal"] = @YES;
        _normal.visible = NO;
        [_normal freeze:YES];
        _results[@"dirtyTabNotFrozen"] = @(!_normal.frozen);
        _normal.dirty = NO;
        [_normal freeze:YES];
        _results[@"backgroundFreeze"] = @(_normal.frozen);
        [_normal freeze:NO];
        _results[@"backgroundResume"] = @(!_normal.frozen);
        _stage = 7;
        [_normal discard];
    } else if (_stage == 7 && !_normal.alive) {
        _results[@"discardReleasedBrowser"] = @(LTLivingBrowserCount() == 1);
        _normal.visible = YES;
        [_normal loadIfNeeded];
        _stage = 8;
    } else if (_stage == 8 && !_normal.loading && _normal.alive &&
               [_normal.title isEqual:@"Lite Test Page"]) {
        _results[@"discardRestore"] = @YES;
        _stage = 9;
        [_normal evaluateForTesting:@"document.cookie.includes('liteSmoke=present')"
                         completion:^(id v, BOOL ok) {
                           self.results[@"restoredCookies"] = @(ok && [v boolValue]);
                           [self.privatePage close];
                           self.stage = 10;
                           self.settledAt = NSDate.date.timeIntervalSince1970;
                         }];
    } else if (_stage == 10 && !_privatePage.alive &&
               NSDate.date.timeIntervalSince1970 - _settledAt > 2) {
        _results[@"memory1"] = ResourceSample();
        _benchmarkPages = [NSMutableArray new];
        [self addBenchmarkPages:9];
        _stage = 11;
    } else if (_stage == 11 && [self benchmarkReady]) {
        _results[@"memory10"] = ResourceSample();
        [self addBenchmarkPages:40];
        _stage = 12;
    } else if (_stage == 12 && [self benchmarkReady]) {
        _results[@"memory50"] = ResourceSample();
        for (LTPage *p in _benchmarkPages)
            [p discard];
        _stage = 13;
        _settledAt = NSDate.date.timeIntervalSince1970;
    } else if (_stage == 13 && LTLivingBrowserCount() == 1 &&
               NSDate.date.timeIntervalSince1970 - _settledAt > 6) {
        _results[@"afterDiscard"] = ResourceSample();
        _results[@"rendererDiscardCount"] = @49;
        _stage = 14;
        _settledAt = NSDate.date.timeIntervalSince1970;
    } else if (_stage == 14 && NSDate.date.timeIntervalSince1970 - _settledAt > 5) {
        NSDictionary *sample = ResourceSample(), *previous = _results[@"afterDiscard"];
        _results[@"idleCPUPercent"] =
            @(([sample[@"cpuSeconds"] doubleValue] - [previous[@"cpuSeconds"] doubleValue]) /
              ([sample[@"time"] doubleValue] - [previous[@"time"] doubleValue]) * 100);
        _stage = 15;
        [_normal navigate:[_origin stringByAppendingString:@"login"]];
    } else if (_stage == 15 && !_normal.loading && [_normal.title isEqual:@"Lite login test"]) {
        _stage = 16;
        [self checkLoginScripts];
    } else if (_stage == 17 && _normal.errorText.length) {
        _results[@"taskManagerEndProcess"] = @YES;
        [_normal reload];
        _stage = 18;
    } else if (_stage == 18 && !_normal.loading && !_normal.errorText.length) {
        _results[@"taskManagerReloadAfterEnd"] = @YES;
        _stage = 19;
        [_normal navigate:[_origin stringByAppendingString:@"content-blocking?phase=enabled"]];
    } else if ((_stage == 19 || _stage == 21 || _stage == 23 || _stage == 25) && !_normal.loading &&
               [_normal.title isEqual:@"Lite content blocking test"]) {
        NSInteger phase = _stage++;
        [_normal evaluateForTesting:@"window.blockingResult || null" completion:^(id value, BOOL success) {
            if (!success || ![value isKindOfClass:NSDictionary.class]) { self.stage = phase; return; }
            BOOL paused = phase == 21;
            NSString *key = phase == 19 ? @"blockingEnabled" : phase == 21 ? @"blockingSitePause" :
                            phase == 23 ? @"blockingResumed" : @"blockingGlobalPause";
            if (phase == 25) paused = YES;
            self.results[key] = @([value[@"blocked"] boolValue] != paused &&
                [value[@"redirectBlocked"] boolValue] != paused && [value[@"allowed"] boolValue] &&
                value[@"workerBlocked"] != NSNull.null && [value[@"workerBlocked"] boolValue] != paused &&
                [value[@"cosmetic"] boolValue] != paused && [value[@"dynamicCosmetic"] boolValue] != paused &&
                [value[@"normalVisible"] boolValue] &&
                (paused ? [value[@"hits"] integerValue] >= 3 : [value[@"hits"] integerValue] == 0));
            self.results[[key stringByAppendingString:@"Details"]] = value;
            if (phase == 19) {
                self.results[@"blockingCounter"] = @(self.normal.blockedRequests >= 2);
                [self.normalContext updateBlockingPreferences:@{@"disabledSites": @[@"127.0.0.1"]}];
                self.stage = 21;
                [self.normal navigate:[self.origin stringByAppendingString:@"content-blocking?phase=paused"]];
            } else if (phase == 21) {
                [self.normalContext updateBlockingPreferences:nil];
                self.stage = 23;
                [self.normal navigate:[self.origin stringByAppendingString:@"content-blocking?phase=resumed"]];
            } else if (phase == 23) {
                [self.normalContext updateBlockingPreferences:@{@"disabled": @YES}];
                self.stage = 25;
                [self.normal navigate:[self.origin stringByAppendingString:@"content-blocking?phase=global"]];
            } else {
                // The regular context is paused; a fresh private context must still block.
                self.privatePage = [[LTPage alloc] initWithID:@"blocking-private"
                    url:[self.origin stringByAppendingString:@"content-blocking?phase=private"] context:self.privateContext];
                self.privatePage.delegate = self;
                [self.privatePage loadIfNeeded];
                self.stage = 27;
            }
        }];
    } else if (_stage == 27 && !_privatePage.loading && [_privatePage.title isEqual:@"Lite content blocking test"]) {
        _stage = 28;
        [_privatePage evaluateForTesting:@"window.blockingResult || null" completion:^(id value, BOOL success) {
            if (!success || ![value isKindOfClass:NSDictionary.class]) { self.stage = 27; return; }
            self.results[@"blockingPrivateIsolation"] = @([value[@"blocked"] boolValue] &&
                [value[@"workerBlocked"] boolValue] && [value[@"cosmetic"] boolValue] &&
                [value[@"hits"] integerValue] == 0 && self.privatePage.blockedRequests >= 2);
            [self finish];
        }];
    }
}
- (void)checkLoginScripts {
    NSString *origin = LTLoginOrigin(_normal.url);
    NSDictionary *entry = @{@"origin" : origin, @"username" : @"synthetic-user"};
    NSString *password = @"Synthetic-only-'\\\"-\\n";
    NSString *fill = LTLoginFillScript(entry, password);
    NSString *read = LTLoginReadScript(origin);
    // Run the actual fill/read scripts with synthetic data. Return booleans only, never secrets.
    NSString *script = [NSString
        stringWithFormat:
            @"(()=>{const "
            @"f=document.querySelector('form'),p=f.querySelector('[type=password]');let "
            @"events=0;f.addEventListener('input',()=>events++);const fill=()=>%@;const "
            @"ok=fill(),v=%@;const "
            @"normal=ok&&v.username==='synthetic-user'&&v.password===p.value&&p.value.length>10&&"
            @"events===2;const noSubmit=document.querySelector('#status').textContent==='Not "
            @"submitted';p.value='';f.action='https://other.lite.invalid/';const "
            @"cross=!fill()&&p.value==='';f.action='/login';p.autocomplete='new-password';const "
            @"creation=!fill()&&p.value==='';p.autocomplete='current-password';p.style.display='"
            @"none';const hidden=!fill()&&p.value==='';p.style.display='';const wrong=%@;return "
            @"{loginFill:normal,loginNoSubmit:noSubmit,loginCrossSiteRejected:cross,"
            @"loginNewPasswordRejected:creation,loginHiddenRejected:hidden,"
            @"loginWrongOriginRejected:!wrong&&p.value===''};})()",
            fill, read,
            LTLoginFillScript(@{@"origin" : @"https://other.lite.invalid", @"username" : @"wrong"},
                              @"Synthetic-only")];
    [_normal evaluateJavaScript:script
                     completion:^(id value, BOOL success) {
                       if (success && [value isKindOfClass:NSDictionary.class])
                           [self.results addEntriesFromDictionary:value];
                       [self performSelector:@selector(checkTaskManager) withObject:nil afterDelay:2.5];
                     }];
}
- (void)checkTaskManager {
    NSArray *tasks = LTBrowserTasks();
    self.results[@"taskManagerReportsTasks"] = @(tasks.count >= 3);
    BOOL measured = NO, browserProtected = NO;
    NSNumber *renderer = nil;
    for (NSDictionary *task in tasks) {
        measured |= [task[@"memory"] longLongValue] > 0 && [task[@"cpu"] doubleValue] >= 0;
        if ([task[@"browser"] boolValue]) browserProtected = !LTEndBrowserTask(task[@"id"]);
        if ([task[@"killable"] boolValue] && [task[@"title"] containsString:@"Lite login test"])
            renderer = task[@"id"];
    }
    self.results[@"taskManagerMeasurements"] = @(measured);
    self.results[@"taskManagerProtectsBrowser"] = @(browserProtected);
    if (renderer && LTEndBrowserTask(renderer)) self.stage = 17;
    else [self finish];
}
- (void)addBenchmarkPages:(NSInteger)count {
    for (NSInteger i = 0; i < count; i++) {
        LTPage *p = [[LTPage alloc] initWithID:NSUUID.UUID.UUIDString
                                           url:_origin
                                       context:_normalContext];
        p.delegate = self;
        p.visible = NO;
        p.container.hidden = YES;
        [_window.contentView addSubview:p.container];
        [_benchmarkPages addObject:p];
        [p loadIfNeeded];
    }
}
- (BOOL)benchmarkReady {
    for (LTPage *p in _benchmarkPages)
        if (p.loading || ![p.title isEqual:@"Lite Test Page"])
            return NO;
    return YES;
}
- (void)finish {
    [_timer invalidate];
    _timer = nil;
    _results[@"elapsedSeconds"] = @(NSDate.date.timeIntervalSince1970 - _started);
    _results[@"stage"] = @(_stage);
    _results[@"privateTitle"] = _privatePage.title ?: @"";
    _results[@"privateError"] = _privatePage.errorText ?: @"";
    _results[@"privateAlive"] = @(_privatePage.alive);
    NSData *data =
        [NSJSONSerialization dataWithJSONObject:_results
                                        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                          error:nil];
    [data writeToFile:_output atomically:YES];
    [_normal close];
    [_privatePage close];
    for (LTPage *p in _benchmarkPages)
        [p close];
    LTQuitWhenBrowsersClose();
}
- (void)pageChanged:(LTPage *)page {
}
- (void)pageClosed:(LTPage *)page {
}
- (void)pageCloseCanceled:(LTPage *)page {
}
- (void)page:(LTPage *)page openURL:(NSString *)url {
}
- (void)page:(LTPage *)page downloadChanged:(NSDictionary *)download {
}
@end
void LTRunSmoke(NSString *origin, NSString *output) {
    running = [LTSmoke new];
    running.origin = origin;
    running.output = output;
    [running begin];
}

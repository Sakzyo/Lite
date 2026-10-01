#import "LTSmoke.h"
#import "../browser/LTEngine.h"
#import "../macos/LTPasswords.h"
#import "../performance/LTPerformance.h"
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
static NSString *const StorageSeedScript = @"(async()=>{document.cookie='deleteMe=yes;path=/';localStorage.setItem('deleteMe','yes');sessionStorage.setItem('deleteMe','yes');let r=indexedDB.open('delete-me',1);await new Promise((ok,no)=>{r.onsuccess=()=>{r.result.close();ok()};r.onerror=no});await(await caches.open('delete-me')).put('/echo',new Response('cached'));await navigator.serviceWorker.register('/blocking-worker.js');await navigator.serviceWorker.ready;return true})()";
static NSString *const StorageCheckScript = @"(async()=>({cookies:!document.cookie.includes('deleteMe'),local:localStorage.getItem('deleteMe')===null,session:sessionStorage.getItem('deleteMe')===null,indexedDB:!(await indexedDB.databases()).some(d=>d.name==='delete-me'),cache:!(await caches.keys()).includes('delete-me'),workers:(await navigator.serviceWorker.getRegistrations()).length===0}))()";
static NSString *const MediaRequestScript = @"window.liteMediaResult=navigator.mediaDevices.getUserMedia({audio:true,video:true}).then(stream=>{window.liteMedia=stream;return {granted:true,kinds:stream.getTracks().map(t=>t.kind).sort(),live:stream.getTracks().every(t=>t.readyState==='live')}}).catch(error=>({granted:false,error:error.name}));true";
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
static BOOL YouTubeGuardPassed(NSDictionary *result, BOOL enabled) {
    if (![result isKindOfClass:NSDictionary.class] || result.count != 10) return NO;
    for (NSString *name in result) {
        NSDictionary *state = result[name];
        BOOL seek = enabled && ([@[@"clientAd", @"serverAd"] containsObject:name]);
        NSInteger clicks = !enabled ? 0 : [name isEqual:@"skip"] ? 1 : [name isEqual:@"reusedSkip"] ? 2 : 0;
        if ([state[@"seeks"] integerValue] != (seek ? 1 : 0) ||
            [state[@"clicks"] integerValue] != clicks ||
            [state[@"currentTime"] integerValue] != (seek ? 15 : 11) ||
            [state[@"volume"] doubleValue] != 1 || [state[@"rate"] doubleValue] != 1) return NO;
    }
    return YES;
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
@property NSUInteger browsersBeforeDevTools;
@property NSUInteger loginSubmissions;
@property BOOL capturedExpectedLogin;
@property LTBrowserContext *proxyContext;
@property LTPage *proxyPage;
@property NSDictionary *lastDownload;
@property NSString *firstDownloadPath;
@property LTPage *downloadPage;
@property NSNumber *pausedBytes;
@property NSUInteger authPrompts;
@property BOOL wrongAuthenticationSent;
@property LTPage *authenticationClosePage;
@property NSUInteger browsersBeforeAuthenticationClose;
@property LTPage *mediaClosePage;
@property NSUInteger browsersBeforeMediaClose;
@property NSInteger lastReportedStage;
@property NSInteger enduranceCycle;
@property NSInteger restartPhase;
@property NSMutableArray *enduranceSamples;
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
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--lite-readiness-smoke"]) {
        _stage = 100;
        _normal.url = [_origin stringByAppendingString:@"auth-basic"];
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--lite-blocking-smoke"]) {
        _stage = 19;
        _normal.url = [_origin stringByAppendingString:@"content-blocking?phase=enabled"];
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--lite-storage-reopen"] ||
        [NSProcessInfo.processInfo.arguments containsObject:@"--lite-storage-reset-check"]) {
        _stage = [NSProcessInfo.processInfo.arguments containsObject:@"--lite-storage-reopen"] ? 201 : 202;
        _normal.url = [_origin stringByAppendingString:@"storage"];
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
- (NSArray<NSView *> *)descendants:(NSView *)view {
    NSMutableArray *views = [NSMutableArray arrayWithObject:view];
    for (NSView *child in view.subviews) [views addObjectsFromArray:[self descendants:child]];
    return views;
}
- (void)answerAuthentication {
    NSWindow *sheet = _window.attachedSheet;
    if (!sheet) return;
    NSArray *views = [self descendants:sheet.contentView];
    NSTextField *username = nil; NSSecureTextField *password = nil; NSButton *signIn = nil;
    for (NSView *view in views) {
        if ([view isKindOfClass:NSButton.class] && [((NSButton *)view).title isEqual:@"Sign In"]) signIn = (NSButton *)view;
        if ([view isKindOfClass:NSSecureTextField.class]) password = (NSSecureTextField *)view;
        else if ([view isKindOfClass:NSTextField.class] && [view.accessibilityLabel isEqual:@"Authentication username"]) username = (NSTextField *)view;
    }
    if (username && password && signIn) {
        _authPrompts++;
        username.stringValue = @"synthetic-http";
        BOOL rejectFirstAttempt = _stage == 100 && !_wrongAuthenticationSent;
        password.stringValue = rejectFirstAttempt ? @"synthetic-wrong-password" : @"synthetic-only-password";
        if (rejectFirstAttempt) _wrongAuthenticationSent = YES;
        [signIn performClick:nil];
    }
}
- (void)tick {
    if (_stage != _lastReportedStage) {
        _lastReportedStage = _stage;
        NSData *progress = [NSJSONSerialization dataWithJSONObject:@{@"stage": @(_stage), @"url": _normal.url ?: @"", @"title": _normal.title ?: @"", @"error": _normal.errorText ?: @"", @"authPrompts": @(_authPrompts)} options:0 error:nil];
        [progress writeToFile:[_output.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"smoke-progress.json"] atomically:YES];
    }
    if (_stage >= 100 && _stage <= 104) {
        [self answerAuthentication];
        if (_normal.errorText.length) { [self finish]; return; }
    }
    if (NSDate.date.timeIntervalSince1970 - _started > 140) {
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
        _normal.visible = YES;
        _stage = 60;
        [_normal evaluateForTesting:@"window.liteTimerTicks=0;window.liteTimer=setInterval(()=>++window.liteTimerTicks,20);true"
            completion:^(id value, BOOL success) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    [self.normal evaluateForTesting:@"window.liteTimerTicks" completion:^(id before, BOOL ok) {
                        self.normal.visible = NO;
                        [self.normal freeze:YES];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                            [self.normal freeze:NO];
                            [self.normal evaluateForTesting:@"window.liteTimerTicks" completion:^(id frozen, BOOL checked) {
                                self.results[@"backgroundFreeze"] = @(success && ok && checked && [frozen integerValue] - [before integerValue] <= 2);
                                self.results[@"freezeTimerSamples"] = @{@"before": before ?: NSNull.null, @"afterThaw": frozen ?: NSNull.null, @"ok": @(success && ok && checked)};
                                self.normal.visible = YES;
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                                    [self.normal evaluateForTesting:@"window.liteTimerTicks" completion:^(id resumed, BOOL checked) {
                                        self.results[@"backgroundResume"] = @(checked && [resumed integerValue] > [frozen integerValue]);
                                        self.normal.visible = NO;
                                        [self.normal discard];
                                        self.results[@"historyDiscardProtected"] = @(self.normal.alive && self.normal.canForward);
                                        [self.normal freeze:NO];
                                        [self.normal forward];
                                        self.stage = 61;
                                    }];
                                });
                            }];
                        });
                    }];
                });
            }];
    } else if (_stage == 61 && !_normal.loading && [_normal.title isEqual:@"Second Page"]) {
        _results[@"forwardNavigation"] = @YES;
        [_normal back]; _stage = 62;
    } else if (_stage == 62 && !_normal.loading && [_normal.title isEqual:@"Lite Test Page"]) {
        [_normal close]; _stage = 63;
    } else if (_stage == 63 && !_normal.alive) {
        [_normal.container removeFromSuperview];
        _normal = [[LTPage alloc] initWithID:@"normal-single-entry" url:[_origin stringByAppendingString:@"scroll"] context:_normalContext];
        _normal.delegate = self;
        [_window.contentView addSubview:_normal.container];
        [_normal loadIfNeeded]; _stage = 64;
    } else if (_stage == 64 && !_normal.loading && [_normal.title isEqual:@"Lite Test Page"]) {
        _stage = 65;
        [_normal evaluateForTesting:@"scrollTo(0,800);true" completion:^(id value, BOOL success) {
            [self.normal discard]; self.stage = 7;
        }];
    } else if (_stage == 7 && !_normal.alive) {
        _results[@"discardReleasedBrowser"] = @(LTLivingBrowserCount() == 1);
        _normal.visible = YES;
        [_normal loadIfNeeded];
        _stage = 8;
    } else if (_stage == 8 && !_normal.loading && _normal.alive &&
               [_normal.title isEqual:@"Lite Test Page"]) {
        _results[@"discardRestore"] = @YES;
        _stage = 9;
        [_normal evaluateForTesting:@"({cookie:document.cookie.includes('liteSmoke=present'),scroll:scrollY})"
                         completion:^(id v, BOOL ok) {
                           self.results[@"restoredCookies"] = @(ok && [v[@"cookie"] boolValue]);
                           self.results[@"discardScrollRestored"] = @(ok && [v[@"scroll"] doubleValue] >= 790);
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
        if (![NSProcessInfo.processInfo.arguments containsObject:@"--lite-blocking-smoke"])
            [self checkPrivateLoginCapture];
        _stage = 28;
        [_privatePage evaluateForTesting:@"window.blockingResult || null" completion:^(id value, BOOL success) {
            if (!success || ![value isKindOfClass:NSDictionary.class]) { self.stage = 27; return; }
            self.results[@"blockingPrivateIsolation"] = @([value[@"blocked"] boolValue] &&
                [value[@"workerBlocked"] boolValue] && [value[@"cosmetic"] boolValue] &&
                [value[@"hits"] integerValue] == 0 && self.privatePage.blockedRequests >= 2);
            [self.normalContext updateBlockingPreferences:nil];
            self.stage = 29;
            [self.normal navigate:@"https://www.youtube.com:18744/watch?v=first"];
        }];
    } else if ((_stage == 29 || _stage == 31 || _stage == 33 || _stage == 35 || _stage == 37) &&
               !(_stage == 37 ? _privatePage.loading : _normal.loading)) {
        NSInteger phase = _stage++;
        LTPage *page = phase == 37 ? _privatePage : _normal;
        [page evaluateForTesting:@"window.youtubeResult || null" completion:^(id value, BOOL success) {
            if (!success || ![value isKindOfClass:NSDictionary.class] || ![value[@"complete"] boolValue]) {
                self.stage = phase; return;
            }
            BOOL paused = phase == 31 || phase == 35;
            NSString *key = phase == 29 ? @"youtubeEnabled" : phase == 31 ? @"youtubeSitePause" :
                phase == 33 ? @"youtubeResumed" : phase == 35 ? @"youtubeGlobalPause" : @"youtubePrivateIsolation";
            BOOL passed = [value[@"contentPreserved"] boolValue] && [value[@"unrelatedPreserved"] boolValue] &&
                [value[@"tailPreserved"] boolValue] && [value[@"encodedContentPreserved"] boolValue] &&
                YouTubeGuardPassed(value[@"guard"], !paused);
            for (NSString *field in @[@"initialClean", @"fetchClean", @"xhrClean", @"spaClean", @"encodedClean"])
                passed &= [value[field] boolValue] != paused;
            self.results[key] = @(passed);
            self.results[[key stringByAppendingString:@"Details"]] = value;
            if (phase == 37) {
                // Policy changes must stop/restart the existing guard without reloading.
                [self.privateContext updateBlockingPreferences:@{@"disabled": @YES}];
                self.stage = 39;
                return;
            }
            NSDictionary *preferences = phase == 29 ? @{@"disabledSites": @[@"www.youtube.com"]} :
                phase == 31 ? @{@"cosmeticDisabled": @YES} : @{@"disabled": @YES};
            [self.normalContext updateBlockingPreferences:preferences];
            self.stage = phase + 2;
            [(phase == 35 ? self.privatePage : self.normal) navigate:@"https://www.youtube.com:18744/watch?v=first"];
        }];
    } else if (_stage == 39 || _stage == 41) {
        NSInteger phase = _stage++;
        [_privatePage evaluateForTesting:@"new Promise(r=>setTimeout(r,100)).then(()=>window.testYouTubePlayer())"
            completion:^(id value, BOOL success) {
                NSString *key = phase == 39 ? @"youtubeLivePause" : @"youtubeLiveResume";
                self.results[key] = @(success && YouTubeGuardPassed(value, phase == 41));
                self.results[[key stringByAppendingString:@"Details"]] = value ?: @{};
                if (phase == 39) {
                    [self.privateContext updateBlockingPreferences:nil];
                    self.stage = 41;
                } else {
                    self.browsersBeforeDevTools = LTLivingBrowserCount();
                    [self.normal showDevTools];
                    self.stage = 43;
                }
            }];
    } else if (_stage == 43 && [_normal hasDevTools] && LTLivingBrowserCount() > _browsersBeforeDevTools) {
        // Reopening an existing inspector must reuse its window and client.
        [_normal showDevTools];
        _results[@"devToolsSingleWindow"] = @(LTLivingBrowserCount() == _browsersBeforeDevTools + 1);
        [_normal closeDevTools];
        _stage = 45;
    } else if (_stage == 45 && ![_normal hasDevTools] && LTLivingBrowserCount() == _browsersBeforeDevTools) {
        _stage = 46;
        [_normal evaluateForTesting:@"1 + 1" completion:^(id value, BOOL success) {
            self.results[@"devToolsOpenClose"] = @(success && [value integerValue] == 2 &&
                [self.results[@"devToolsSingleWindow"] boolValue]);
            if ([NSProcessInfo.processInfo.arguments containsObject:@"--lite-blocking-smoke"]) [self finish];
            else { self.stage = 100; [self.normal navigate:[self.origin stringByAppendingString:@"auth-basic"]]; }
        }];
    } else if (_stage == 100 && !_normal.loading && [_normal.title isEqual:@"Authenticated basic"]) {
        _results[@"httpBasicAuthentication"] = @(_authPrompts >= 1);
        _results[@"httpAuthenticationRetry"] = @(_wrongAuthenticationSent && _authPrompts >= 2);
        _stage = 101;
        [_normal navigate:[_origin stringByAppendingString:@"auth-digest"]];
    } else if (_stage == 101 && !_normal.loading && [_normal.title isEqual:@"Authenticated digest"]) {
        _results[@"httpDigestAuthentication"] = @(_authPrompts >= 2);
        _proxyContext = [[LTBrowserContext alloc] initPrivate:YES];
        _results[@"proxyFixtureConfigured"] = @([_proxyContext configureFixtureProxyForTesting]);
        _proxyPage = [[LTPage alloc] initWithID:@"proxy-auth" url:[_origin stringByAppendingString:@"auth-proxy"] context:_proxyContext];
        _proxyPage.delegate = self;
        [_window.contentView addSubview:_proxyPage.container];
        [_proxyPage loadIfNeeded]; _stage = 102;
    } else if (_stage == 102 && !_proxyPage.loading && [_proxyPage.title isEqual:@"Authenticated proxy"]) {
        _results[@"proxyAuthentication"] = @(_authPrompts >= 3);
        [_proxyPage close];
        _stage = 105;
        [_normal navigate:[_origin stringByAppendingString:@"storage"]];
    } else if (_stage == 105 && !_normal.loading && [_normal.title isEqual:@"Lite storage test"]) {
        _stage = 106;
        [_normal evaluateJavaScript:StorageSeedScript completion:^(id value, BOOL success) {
            self.results[@"storageSeeded"] = @(success && [value isEqual:@YES]);
            [self.normal clearSiteDataWithCompletion:^(BOOL cleared, NSString *message) {
                self.results[@"siteStorageDeletionCompleted"] = @(cleared);
                self.stage = 107; [self.normal reload];
            }];
        }];
    } else if (_stage == 107 && !_normal.loading && [_normal.title isEqual:@"Lite storage test"]) {
        _stage = 108;
        [_normal evaluateJavaScript:StorageCheckScript completion:^(id value, BOOL success) {
            BOOL passed = success && [value isKindOfClass:NSDictionary.class] && [value count] == 6;
            if (passed) for (NSString *key in value) passed &= [value[key] boolValue];
            self.results[@"siteStorageAbsentAfterReload"] = @(passed);
            self.results[@"siteStorageDetails"] = value ?: @{};
            self.stage = 109;
            [self.normal navigate:[self.origin stringByAppendingString:@"download-fixture"]];
        }];
    } else if (_stage == 109 && [_lastDownload[@"complete"] boolValue]) {
        NSData *data = [NSData dataWithContentsOfFile:_lastDownload[@"path"]];
        _results[@"downloadCompleted"] = @(data.length == 24 * 4096);
        _results[@"downloadQuarantined"] = _lastDownload[@"quarantined"] ?: @NO;
        _results[@"downloadSecurityError"] = _lastDownload[@"securityError"] ?: @"";
        _firstDownloadPath = _lastDownload[@"path"];
        _results[@"downloadArtifact"] = _firstDownloadPath;
        _lastDownload = nil; _stage = 140;
        [_normal navigate:[_origin stringByAppendingString:@"download-fixture"]];
    } else if (_stage == 140 && [_lastDownload[@"complete"] boolValue]) {
        _results[@"downloadDuplicateFilename"] = @(![_firstDownloadPath isEqual:_lastDownload[@"path"]] &&
            [NSData dataWithContentsOfFile:_firstDownloadPath].length == 24 * 4096);
        _lastDownload = nil; _stage = 141;
        [_normal navigate:[_origin stringByAppendingString:@"download-slow"]];
    } else if (_stage == 141 && [_lastDownload[@"active"] boolValue] && [_lastDownload[@"received"] longLongValue] > 0) {
        _normal.visible = NO; [_normal discard];
        _results[@"downloadProtectsDiscard"] = @(_normal.alive && _normal.downloading);
        [_normal downloadAction:@"pause" identifier:[_lastDownload[@"id"] integerValue]];
        _stage = 142;
    } else if (_stage == 142 && [_lastDownload[@"paused"] boolValue]) {
        _pausedBytes = _lastDownload[@"received"];
        _settledAt = NSDate.date.timeIntervalSince1970; _stage = 143;
    } else if (_stage == 143 && NSDate.date.timeIntervalSince1970 - _settledAt > .5) {
        _results[@"downloadPaused"] = @([_lastDownload[@"paused"] boolValue] && [_lastDownload[@"received"] isEqual:_pausedBytes]);
        [_normal downloadAction:@"resume" identifier:[_lastDownload[@"id"] integerValue]]; _stage = 144;
    } else if (_stage == 144 && [_lastDownload[@"active"] boolValue] && ![_lastDownload[@"paused"] boolValue]) {
        _results[@"downloadResumed"] = @YES;
        [_normal downloadAction:@"cancel" identifier:[_lastDownload[@"id"] integerValue]]; _stage = 145;
    } else if (_stage == 145 && [_lastDownload[@"canceled"] boolValue]) {
        _results[@"downloadCanceled"] = @(!_normal.downloading);
        _normal.visible = YES; _lastDownload = nil; _stage = 146;
        [_normal navigate:[_origin stringByAppendingString:@"download-interrupted"]];
    } else if (_stage == 146 && [_lastDownload[@"interrupted"] boolValue]) {
        _results[@"downloadNetworkInterrupted"] = @([_lastDownload[@"reasonCode"] integerValue] == 38 && [_lastDownload[@"reason"] length] > 0);
        _downloadPage = [[LTPage alloc] initWithID:@"download-close" url:[_origin stringByAppendingString:@"download-slow"] context:_normalContext];
        _downloadPage.delegate = self; [_window.contentView addSubview:_downloadPage.container];
        [_downloadPage loadIfNeeded]; _stage = 147;
    } else if (_stage == 147 && [_lastDownload[@"page"] isEqual:@"download-close"] && [_lastDownload[@"active"] boolValue]) {
        [_downloadPage close]; _stage = 148;
    } else if (_stage == 148 && !_downloadPage.alive) {
        _results[@"downloadClosureStopsMetadata"] = @(![_lastDownload[@"active"] boolValue] && ![_lastDownload[@"canResume"] boolValue] && !_downloadPage.downloading);
        _stage = 149;
        [_normal navigate:[_origin stringByAppendingString:@"storage?permissions"]];
    } else if (_stage == 149 && !_normal.loading && [_normal.title isEqual:@"Lite storage test"]) {
        _stage = 153;
        [_normal evaluateJavaScript:@"(async()=>{window.liteAudio=new AudioContext();const oscillator=liteAudio.createOscillator(),gain=liteAudio.createGain();gain.gain.value=0;oscillator.connect(gain).connect(liteAudio.destination);oscillator.start();await liteAudio.resume();return liteAudio.state==='running'})()" completion:^(id value, BOOL success) {
            self.results[@"webAudioRunning"] = @(success && [value isEqual:@YES]);
        }];
    } else if (_stage == 153 && _normal.audible) {
        _normal.visible = NO; [_normal freeze:YES]; [_normal discard];
        _results[@"webAudioProtected"] = @(_normal.alive && !_normal.frozen && [_results[@"webAudioRunning"] boolValue]);
        _normal.visible = YES; _stage = 154;
        [_normal evaluateJavaScript:@"liteAudio.close().then(()=>true)" completion:^(id value, BOOL success) {
            self.results[@"webAudioClosed"] = @(success && [value isEqual:@YES]);
        }];
    } else if (_stage == 154 && !_normal.audible) {
        _results[@"webAudioProtectionReleased"] = @([_results[@"webAudioClosed"] boolValue]);
        _stage = 150;
        [_normal evaluateJavaScript:@"document.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));true" completion:^(id value, BOOL success) {}];
    } else if (_stage == 150 && _normal.dirty) {
        _normal.visible = NO; [_normal freeze:YES]; [_normal discard];
        _results[@"pointerInteractionProtected"] = @(_normal.alive && !_normal.frozen);
        _normal.visible = YES; _normal.dirty = NO; _stage = 151;
        [_normal evaluateJavaScript:@"document.dispatchEvent(new KeyboardEvent('keydown',{key:'a',bubbles:true}));true" completion:^(id value, BOOL success) {}];
    } else if (_stage == 151 && _normal.dirty) {
        _results[@"keyboardInteractionProtected"] = @YES;
        _normal.dirty = NO; _stage = 152;
        [_normal evaluateJavaScript:@"document.dispatchEvent(new Event('change',{bubbles:true}));true" completion:^(id value, BOOL success) {}];
    } else if (_stage == 152 && _normal.dirty) {
        _results[@"changeInteractionProtected"] = @YES;
        _stage = 160;
        [_normal navigate:[_origin stringByAppendingString:@"storage?permissions-reset"]];
    } else if (_stage == 160 && !_normal.loading && [_normal.title isEqual:@"Lite storage test"]) {
        _results[@"interactionGuardResetOnNavigation"] = @(!_normal.dirty);
        [_normal evaluateJavaScript:MediaRequestScript completion:^(id value, BOOL success) {}]; _stage = 161;
    } else if (_stage == 161 && _window.attachedSheet) {
        BOOL origin = NO, camera = NO, microphone = NO;
        for (NSView *view in [self descendants:_window.attachedSheet.contentView]) {
            if (![view isKindOfClass:NSTextField.class]) continue;
            NSString *text = ((NSTextField *)view).stringValue;
            origin |= [text containsString:@"http://127.0.0.1:18743"];
            camera |= [text containsString:@"camera"]; microphone |= [text containsString:@"microphone"];
        }
        _results[@"combinedMediaExactOriginAndCapabilities"] = @(origin && camera && microphone);
        for (NSView *view in [self descendants:_window.attachedSheet.contentView])
            if ([view isKindOfClass:NSButton.class] && [((NSButton *)view).title isEqual:@"Deny"]) [(NSButton *)view performClick:nil];
        _stage = 162;
    } else if (_stage == 162 && !_window.attachedSheet) {
        _stage = 159;
        [_normal evaluateJavaScript:@"liteMediaResult" completion:^(id value, BOOL success) {
            self.results[@"combinedMediaDenied"] = @(success && [value[@"granted"] isEqual:@NO] && [value[@"error"] isEqual:@"NotAllowedError"] && !self.normal.capturing);
            [self.normal evaluateJavaScript:MediaRequestScript completion:^(id value, BOOL success) {}]; self.stage = 163;
        }];
    } else if (_stage == 163 && _window.attachedSheet) {
        for (NSView *view in [self descendants:_window.attachedSheet.contentView])
            if ([view isKindOfClass:NSButton.class] && [((NSButton *)view).title isEqual:@"Allow for this request"]) [(NSButton *)view performClick:nil];
        _stage = 164;
    } else if (_stage == 164 && !_window.attachedSheet) {
        _stage = 159;
        [_normal evaluateJavaScript:@"liteMediaResult" completion:^(id value, BOOL success) {
            self.results[@"combinedMediaGrantDetails"] = value ?: @{};
            self.results[@"combinedMediaGranted"] = @(success && [value[@"granted"] boolValue] && [value[@"live"] boolValue] && [value[@"kinds"] isEqual:@[@"audio", @"video"]]);
            self.stage = 165;
        }];
    } else if (_stage == 165 && _normal.capturing) {
        _normal.visible = NO; [_normal freeze:YES]; [_normal discard];
        _results[@"combinedMediaProtected"] = @(_normal.alive && !_normal.frozen && !_normal.dirty);
        _normal.visible = YES;
        [_normal evaluateJavaScript:@"liteMedia.getTracks().forEach(track=>track.stop());true" completion:^(id value, BOOL success) {}];
        _settledAt = NSDate.date.timeIntervalSince1970; _stage = 166;
    } else if (_stage == 166 && NSDate.date.timeIntervalSince1970 - _settledAt > 1) {
        _stage = 159;
        [_normal evaluateJavaScript:@"liteMedia.getTracks().every(track=>track.readyState==='ended')" completion:^(id value, BOOL success) {
            self.results[@"combinedMediaStopped"] = @(success && [value isEqual:@YES]);
            // Record engine source access separately from JS track state.
            // Only the engine can release Lite's conservative capture guard.
            self.results[@"combinedMediaCaptureAfterStop"] = @(self.normal.capturing);
            [self.normal evaluateJavaScript:MediaRequestScript completion:^(id value, BOOL success) {}]; self.stage = 167;
        }];
    } else if (_stage == 167 && _window.attachedSheet) {
        [_normal navigate:[_origin stringByAppendingString:@"second"]]; _stage = 168;
    } else if (_stage == 168 && !_normal.loading && [_normal.title isEqual:@"Second Page"]) {
        _results[@"combinedMediaNavigationCanceled"] = @(!_window.attachedSheet && !_normal.capturing);
        _browsersBeforeMediaClose = LTLivingBrowserCount();
        _mediaClosePage = [[LTPage alloc] initWithID:@"media-close" url:[_origin stringByAppendingString:@"storage"] context:_normalContext];
        _mediaClosePage.delegate = self; [_window.contentView addSubview:_mediaClosePage.container];
        [_mediaClosePage loadIfNeeded]; _stage = 169;
    } else if (_stage == 169 && !_mediaClosePage.loading && [_mediaClosePage.title isEqual:@"Lite storage test"]) {
        [_mediaClosePage evaluateJavaScript:MediaRequestScript completion:^(id value, BOOL success) {}]; _stage = 170;
    } else if (_stage == 170 && _window.attachedSheet) {
        [_mediaClosePage close]; _stage = 171;
    } else if (_stage == 171 && !_mediaClosePage.alive && !_window.attachedSheet) {
        _results[@"combinedMediaClosureCanceled"] = @(LTLivingBrowserCount() == _browsersBeforeMediaClose && _normal.alive);
        [_normal navigate:[_origin stringByAppendingString:@"storage?permissions"]]; _stage = 110;
    } else if (_stage == 110 && !_normal.loading && [_normal.title isEqual:@"Lite storage test"]) {
        _stage = 111;
        [_normal evaluateJavaScript:@"window.litePermission=null;Notification.requestPermission().then(r=>window.litePermission=r);true" completion:^(id value, BOOL success) {}];
        _settledAt = NSDate.date.timeIntervalSince1970;
    } else if (_stage == 111 && _window.attachedSheet) {
        BOOL origin = NO, capability = NO;
        for (NSView *view in [self descendants:_window.attachedSheet.contentView]) {
            if ([view isKindOfClass:NSTextField.class]) {
                NSString *text = ((NSTextField *)view).stringValue;
                origin |= [text containsString:@"http://127.0.0.1:18743"];
                capability |= [text containsString:@"notifications"];
            }
        }
        _results[@"permissionExactOriginAndCapability"] = @(origin && capability);
        for (NSView *view in [self descendants:_window.attachedSheet.contentView])
            if ([view isKindOfClass:NSButton.class] && [((NSButton *)view).title isEqual:@"Deny"]) [(NSButton *)view performClick:nil];
        _stage = 112;
    } else if (_stage == 112 && !_window.attachedSheet) {
        _stage = 113;
        [_normal evaluateJavaScript:@"window.litePermission" completion:^(id value, BOOL success) {
            self.results[@"permissionDenied"] = @(success && [value isEqual:@"denied"]);
            [self.normal revokePermissions]; self.stage = 114;
        }];
    } else if (_stage == 114 && !_normal.loading) {
        _stage = 115;
        [_normal evaluateJavaScript:@"Notification.requestPermission().then(r=>window.litePermission=r);true" completion:^(id value, BOOL success) {}];
    } else if (_stage == 115 && _window.attachedSheet) {
        for (NSView *view in [self descendants:_window.attachedSheet.contentView])
            if ([view isKindOfClass:NSButton.class] && [((NSButton *)view).title isEqual:@"Allow for this site"]) [(NSButton *)view performClick:nil];
        _stage = 116;
    } else if (_stage == 116 && !_window.attachedSheet) {
        _stage = 117;
        [_normal evaluateJavaScript:@"Notification.permission" completion:^(id value, BOOL success) {
            BOOL inspected = NO;
            for (NSDictionary *grant in self.normal.permissionGrants) inspected |= [grant[@"capabilities"] containsObject:@"notifications"];
            self.results[@"permissionGranted"] = @(success && [value isEqual:@"granted"] && inspected);
            self.results[@"permissionGrantedDetails"] = @{@"state": value ?: NSNull.null, @"grants": self.normal.permissionGrants};
            [self.normal revokePermissions]; self.stage = 118;
        }];
    } else if (_stage == 118 && !_normal.loading) {
        _stage = 119;
        [_normal evaluateJavaScript:@"Notification.permission" completion:^(id value, BOOL success) {
            self.results[@"permissionRevoked"] = @(success && ![value isEqual:@"granted"] && self.normal.permissionGrants.count == 0);
            self.settledAt = NSDate.date.timeIntervalSince1970;
            [self.normal evaluateJavaScript:@"Notification.requestPermission().then(r=>window.litePermission=r);true" completion:^(id value, BOOL success) {}];
        }];
    } else if (_stage == 119 && !_window.attachedSheet && NSDate.date.timeIntervalSince1970 - _settledAt > 5) {
        _results[@"permissionNavigationCanceled"] = @NO;
        [_normal navigate:[_origin stringByAppendingString:@"second"]]; _stage = 120;
    } else if (_stage == 119 && _window.attachedSheet) {
        [_normal navigate:[_origin stringByAppendingString:@"second"]];
        _stage = 120;
    } else if (_stage == 120 && !_normal.loading && [_normal.title isEqual:@"Second Page"]) {
        if (!_results[@"permissionNavigationCanceled"]) _results[@"permissionNavigationCanceled"] = @(!_window.attachedSheet && !_normal.permissionGrants.count);
        _stage = 121;
        [_normalContext clearCookiesAndCacheWithCompletion:^(BOOL success, NSString *message) {
            [self.normal navigate:[self.origin stringByAppendingString:@"auth-basic"]]; self.stage = 122;
        }];
    } else if (_stage == 122 && _window.attachedSheet) {
        [_normal navigate:[_origin stringByAppendingString:@"second"]]; _stage = 123;
    } else if (_stage == 123 && !_normal.loading && [_normal.title isEqual:@"Second Page"]) {
        _results[@"authenticationNavigationCanceled"] = @(!_window.attachedSheet);
        _browsersBeforeAuthenticationClose = LTLivingBrowserCount();
        _authenticationClosePage = [[LTPage alloc] initWithID:@"authentication-close" url:[_origin stringByAppendingString:@"auth-basic"] context:_normalContext];
        _authenticationClosePage.delegate = self;
        [_window.contentView addSubview:_authenticationClosePage.container];
        [_authenticationClosePage loadIfNeeded]; _stage = 124;
    } else if (_stage == 124 && _window.attachedSheet) {
        BOOL challenge = NO;
        for (NSView *view in [self descendants:_window.attachedSheet.contentView])
            challenge |= [view isKindOfClass:NSSecureTextField.class];
        _results[@"authenticationClosureChallengeShown"] = @(challenge);
        [_authenticationClosePage close]; _stage = 125;
    } else if (_stage == 125 && !_authenticationClosePage.alive && !_window.attachedSheet) {
        _stage = 126;
        [_normal evaluateJavaScript:@"document.title" completion:^(id value, BOOL success) {
            self.results[@"authenticationClosureCanceled"] = @(success && [value isEqual:@"Second Page"] &&
                [self.results[@"authenticationClosureChallengeShown"] boolValue] &&
                LTLivingBrowserCount() == self.browsersBeforeAuthenticationClose);
            self.stage = 127;
        }];
    } else if (_stage == 127) {
        [_privatePage close]; _stage = 130;
        _enduranceSamples = [NSMutableArray new];
        _benchmarkPages = [NSMutableArray new];
    } else if (_stage == 130 && !_privatePage.alive) {
        [self addBenchmarkPages:10]; _stage = 131;
    } else if (_stage == 131 && [self benchmarkReady]) {
        for (LTPage *page in _benchmarkPages) [page close];
        _settledAt = NSDate.date.timeIntervalSince1970; _stage = 132;
    } else if (_stage == 132 && LTLivingBrowserCount() == 1 && NSDate.date.timeIntervalSince1970 - _settledAt > 1) {
        [_enduranceSamples addObject:ResourceSample()];
        [_benchmarkPages removeAllObjects];
        if (++_enduranceCycle < 3) _stage = 130;
        else {
            _results[@"repeatedBrowsingCycles"] = @YES;
            _results[@"cycleCount"] = @(_enduranceCycle);
            _results[@"cycleSamples"] = _enduranceSamples;
            _results[@"cycleLivingBrowsers"] = @(LTLivingBrowserCount());
            _stage = 136;
            [_normal navigate:@"http://localhost:18743/storage"];
        }
    } else if (_stage == 136 && !_normal.loading && [[NSURL URLWithString:_normal.url].host isEqual:@"localhost"]) {
        _stage = 133; _settledAt = NSDate.date.timeIntervalSince1970;
        [_normal evaluateJavaScript:@"Notification.requestPermission().then(r=>window.litePermission=r);true" completion:^(id value, BOOL success) {}];
    } else if (_stage == 133 && _window.attachedSheet) {
        for (NSView *view in [self descendants:_window.attachedSheet.contentView])
            if ([view isKindOfClass:NSButton.class] && [((NSButton *)view).title isEqual:@"Allow for this site"]) [(NSButton *)view performClick:nil];
        _stage = 134;
    } else if (_stage == 134 && !_window.attachedSheet) {
        _stage = 135;
        [_normal evaluateJavaScript:@"Notification.permission" completion:^(id value, BOOL success) {
            self.results[@"permissionRestartSeeded"] = @(success && [value isEqual:@"granted"]);
            [self finish];
        }];
    } else if (_stage == 133 && NSDate.date.timeIntervalSince1970 - _settledAt > 5) {
        _results[@"permissionRestartSeeded"] = @NO; [self finish];
    } else if ((_stage == 201 || _stage == 202) && !_normal.loading && [_normal.title isEqual:@"Lite storage test"]) {
        NSInteger phase = _stage; _stage = 203;
        [_normal evaluateJavaScript:[NSString stringWithFormat:@"(async()=>({storage:await %@,permission:Notification.permission}))()", StorageCheckScript]
            completion:^(id value, BOOL success) {
                BOOL empty = success && [value[@"storage"] isKindOfClass:NSDictionary.class] && [value[@"storage"] count] == 6;
                if (empty) for (NSString *key in value[@"storage"]) empty &= [value[@"storage"][key] boolValue];
                self.results[phase == 201 ? @"siteStorageAbsentAfterRestart" : @"allSiteStorageAbsentAfterRestart"] = @(empty);
                self.restartPhase = phase;
                [self.normal navigate:@"http://localhost:18743/storage"]; self.stage = 204;
            }];
    } else if (_stage == 204 && !_normal.loading && [[NSURL URLWithString:_normal.url].host isEqual:@"localhost"]) {
        _stage = 206;
        [_normal evaluateJavaScript:@"Notification.permission" completion:^(id value, BOOL success) {
            self.results[self.restartPhase == 201 ? @"permissionPersistedAfterRestart" : @"allSitePermissionReset"] = @(success && ([value isEqual:@"granted"] == (self.restartPhase == 201)));
            if (self.restartPhase == 201) { [self.normal navigate:[self.origin stringByAppendingString:@"storage"]]; self.stage = 205; }
            else [self finish];
        }];
    } else if (_stage == 205 && !_normal.loading && [[NSURL URLWithString:_normal.url].host isEqual:@"127.0.0.1"]) {
        _stage = 206;
        [_normal evaluateJavaScript:StorageSeedScript completion:^(id value, BOOL success) {
            self.results[@"allSiteStorageSeeded"] = @(success && [value isEqual:@YES]); [self finish];
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
                       [self checkLoginCapture];
                     }];
}
- (void)page:(LTPage *)page submittedLogin:(NSDictionary *)login {
    _loginSubmissions++;
    _capturedExpectedLogin = page == _normal &&
        [login[@"origin"] isEqual:LTLoginOrigin(_normal.url)] &&
        [login[@"username"] isEqual:@"synthetic-capture"] &&
        [login[@"password"] isEqual:@"Synthetic-capture-only!"];
}
- (void)checkLoginCapture {
    // Runtime.evaluate supplies a browser user gesture; requestSubmit generates
    // the trusted submit event used by real clicks. No submitted value is logged.
    [_normal evaluateJavaScript:@"(()=>{const f=document.querySelector('form'),p=f.querySelector('[type=password]'),b=f.querySelector('button');f.querySelector('[name=username]').value='synthetic-capture';p.value='Synthetic-capture-only!';f.action='https://other.lite.invalid/';f.requestSubmit(b);f.action='/login';p.autocomplete='new-password';f.requestSubmit(b);p.autocomplete='current-password';p.style.display='none';f.requestSubmit(b);p.style.display='';b.setAttribute('formaction','https://other.lite.invalid/');f.requestSubmit(b);b.removeAttribute('formaction');f.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));return typeof window.__liteLoginSubmitted==='undefined';})()"
        completion:^(id value, BOOL success) {
            self.results[@"loginBridgeHidden"] = @(success && [value isEqual:@YES]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                self.results[@"loginSubmissionUnsafeRejected"] = @(self.loginSubmissions == 0);
                [self.normal evaluateJavaScript:@"document.querySelector('form').requestSubmit(document.querySelector('button'));true"
                    completion:^(id value, BOOL success) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                            self.results[@"loginSubmissionCaptured"] = @(success && self.loginSubmissions == 1 && self.capturedExpectedLogin);
                            [self performSelector:@selector(checkTaskManager) withObject:nil afterDelay:2.5];
                        });
                    }];
            });
        }];
}
- (void)checkPrivateLoginCapture {
    [_privatePage evaluateJavaScript:@"(()=>{document.body.innerHTML='<form><input name=username autocomplete=username value=synthetic-private><input type=password value=Synthetic-private-only><button>Sign in</button></form>';const f=document.querySelector('form');f.addEventListener('submit',e=>e.preventDefault());f.requestSubmit(f.querySelector('button'));return typeof window.__liteLoginSubmitted==='undefined';})()"
        completion:^(id value, BOOL success) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                self.results[@"loginSubmissionPrivateRejected"] = @(success && [value isEqual:@YES] && self.loginSubmissions == 1);
            });
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
    _results[@"normalTitle"] = _normal.title ?: @"";
    _results[@"normalURL"] = _normal.url ?: @"";
    _results[@"normalError"] = _normal.errorText ?: @"";
    _results[@"authPrompts"] = @(_authPrompts);
    NSMutableArray *sheetLabels = [NSMutableArray new];
    if (_window.attachedSheet) for (NSView *view in [self descendants:_window.attachedSheet.contentView]) {
        if ([view isKindOfClass:NSButton.class]) [sheetLabels addObject:((NSButton *)view).title];
        if ([view isKindOfClass:NSTextField.class] && !((NSTextField *)view).editable) [sheetLabels addObject:((NSTextField *)view).stringValue];
    }
    _results[@"pendingDialogLabels"] = sheetLabels;
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
    [_proxyPage close];
    [_downloadPage close];
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
    _lastDownload = download;
}
@end
void LTRunSmoke(NSString *origin, NSString *output) {
    running = [LTSmoke new];
    running.origin = origin;
    running.output = output;
    [running begin];
}

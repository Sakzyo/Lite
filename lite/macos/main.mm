#import "../model/LTLoginStore.h"
#import "../model/LTGitHub.h"
#import "../performance/LTPerformance.h"
#import "../tests/LTSmoke.h"
#import "../tests/LTNativeSmoke.h"
#import "LTFaviconCache.h"
#import "LTUI.h"
#import "LTWindow.h"
#import "LTShortcuts.h"
#import "LTTaskManager.h"
#import "LTUpdater.h"
#import "LTDownloadHistory.h"
#import "../model/LTWebsiteData.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#import <Cocoa/Cocoa.h>
#import <os/log.h>
#include <sys/file.h>
#include <fcntl.h>
static NSString *profileRoot;
static BOOL smokeTest = NO;
static BOOL testProfile = NO, websiteDataCleared = NO, relaunchAfterClear = NO;

@interface LTAppDelegate : NSObject <NSApplicationDelegate>
@property LTStore *store;
@property NSMutableArray<LTWindow *> *windows;
@property LTPerformance *performance;
@property LTFaviconCache *icons;
@property LTLoginStore *logins;
@property LTGitHub *github;
@property LTShortcuts *shortcuts;
@property LTTaskManager *taskManager;
@property id keyMonitor;
@property BOOL quitting;
@property BOOL confirmingQuit;
@property LTUpdater *updater;
@property LTDownloadHistory *downloads;
- (void)start;
- (void)quit;
@end
@interface LiteApplication : NSApplication <CefAppProtocol>
@property (nonatomic) BOOL handlingSendEvent;
@end
@implementation LiteApplication
- (BOOL)isHandlingSendEvent {
    return _handlingSendEvent;
}
- (void)sendEvent:(NSEvent *)event {
    CefScopedSendingEvent scope;
    [super sendEvent:event];
}
- (void)terminate:(id)sender {
    [(LTAppDelegate *)self.delegate quit];
}
@end
@implementation LTAppDelegate
- (void)start {
    _windows = [NSMutableArray new];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self buildMenu];
    if (smokeTest) {
        LTRunSmoke(@"http://127.0.0.1:18743/",
                   [profileRoot stringByAppendingPathComponent:@"smoke-results.json"]);
        return;
    }
    NSString *base = profileRoot;
    NSError *e = nil;
    _store = [[LTStore alloc] initWithPath:[base stringByAppendingPathComponent:@"Lite.sqlite"]
                                     error:&e];
    if (!_store) {
        NSString *path = [base stringByAppendingPathComponent:@"Lite.sqlite"];
        if ([LTStore recoveryAvailableAtPath:path]) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"Lite found a damaged profile";
            alert.informativeText = [NSString stringWithFormat:@"%@\n\nRestore the last known-good local backup? The damaged database and its transaction files will be preserved beside the profile. Recent changes after that backup may be missing.", e.localizedDescription];
            [alert addButtonWithTitle:@"Quit"];
            [alert addButtonWithTitle:@"Restore Backup"];
            if ([alert runModal] == NSAlertSecondButtonReturn) {
                NSString *preserved = nil;
                if ([LTStore recoverProfileAtPath:path preservedPath:&preserved error:&e])
                    _store = [[LTStore alloc] initWithPath:path error:&e];
                if (_store) LTAlert(nil, @"Profile restored", [@"Damaged originals were preserved at:\n" stringByAppendingString:preserved]);
            }
        }
    }
    if (!_store) {
        LTAlert(nil, @"Lite could not open your profile",
                e.localizedDescription
                    ?: @"The database was preserved. Restore a backup or choose a different "
                       @"profile directory.");
        CefQuitMessageLoop();
        return;
    }
    NSError *historyClearError = nil;
    if (websiteDataCleared) [_store clearHistorySince:0 error:&historyClearError];
    _updater = [LTUpdater new];
    if (!testProfile) [_updater start];
    _downloads = [[LTDownloadHistory alloc] initWithPath:[base stringByAppendingPathComponent:@"Downloads.json"] contextIdentifier:nil];
    _icons = [[LTFaviconCache alloc]
        initWithDirectory:[base stringByAppendingPathComponent:@"Favicons"]];
    _logins = [[LTLoginStore alloc] initWithProfilePath:base];
    _github = [[LTGitHub alloc] initWithStore:_store logins:_logins];
    _shortcuts = [[LTShortcuts alloc] initWithStore:_store menu:NSApp.mainMenu];
    _taskManager = [LTTaskManager new];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(warmIcons)
                                               name:LTStoreChanged
                                             object:_store];
    [self warmIcons];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(appCommand:)
                                               name:@"LTAppCommand"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(saveWindows)
                                               name:@"LTWindowsChanged"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(cancelQuit)
                                               name:@"LTQuitCanceled"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clearAllWebsiteData:)
        name:@"LTClearAllWebsiteData" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backupFailed:)
        name:LTStoreBackupFailed object:_store];
    NSArray *restore = [_store.profile.windows copy];
    if (!restore.count)
        [self newWindow:NO mini:NO state:nil];
    else
        for (NSDictionary *state in restore)
            [self newWindow:NO mini:NO state:state];
    _performance = [LTPerformance new];
    __weak typeof(self) weak = self;
    _github.openIDs = ^NSSet * {
        NSMutableSet *identifiers = [NSMutableSet new];
        for (LTWindow *window in weak.windows)
            for (LTPage *page in window.pages)
                if (page.alive) [identifiers addObject:page.identifier];
        return identifiers;
    };
    [_github start];
    _performance.pages = ^NSArray * {
      NSMutableArray *p = [NSMutableArray new];
      for (LTWindow *w in weak.windows)
          [p addObjectsFromArray:w.pages];
      return p;
    };
    _performance.mode = ^NSString * {
      return weak.store.profile.settings[@"performance"] ?: @"Efficient";
    };
    [_performance start];
    _keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
        handler:^NSEvent *(NSEvent *event) {
            // Chromium's editable content can consume native menu shortcuts. Route the
            // configured bindings before dispatching to the page, but leave panels and
            // the shortcut recorder to their own responders.
            if ([event.window.windowController isKindOfClass:LTWindow.class] &&
                !event.window.attachedSheet &&
                (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) &&
                [NSApp.mainMenu performKeyEquivalent:event])
                return nil;
            return event;
        }];
    [_windows.firstObject showOnboarding];
    if (_store.backupError) [self backupFailed:nil];
    if (websiteDataCleared) LTAlert(_windows.firstObject.window, historyClearError ? @"Website storage cleared; history deletion needs attention" : @"Website data cleared", historyClearError.localizedDescription ?: @"Cookies, HTTP cache, local storage, IndexedDB, service workers, Cache Storage, engine permissions and other Chromium profile storage were removed before the browser engine started. Bookmarks, organization and saved passwords were kept. Preserved damaged-profile copies remain untouched. Select a tab to load it again.");
    os_log_info(OS_LOG_DEFAULT, "Lite native browser started");
    NSString *start = NSProcessInfo.processInfo.environment[@"LITE_START_URL"];
    if (start.length)
        [_windows.firstObject openURL:start];
    if (testProfile && [NSProcessInfo.processInfo.arguments containsObject:@"--lite-native-smoke"])
        LTRunNativeSmoke(_windows.firstObject, [profileRoot stringByAppendingPathComponent:@"native-results.json"], ^{ [self finishQuit:YES]; });
}
- (void)warmIcons {
    [_icons prefetchNodes:_store.profile.nodes];
}
- (LTWindow *)newWindow:(BOOL)privateMode mini:(BOOL)mini state:(NSDictionary *)state {
    NSError *e = nil;
    LTStore *store = privateMode ? [[LTStore alloc] initWithPath:nil error:&e] : _store;
    if (websiteDataCleared && !privateMode) {
        NSMutableDictionary *deferred = [state mutableCopy] ?: [NSMutableDictionary new];
        deferred[@"deferPages"] = @YES;
        state = deferred;
    }
    LTWindow *w = [[LTWindow alloc] initWithStore:store
                                             mini:mini
                                          restore:state ?: @{}
                                            icons:_icons
                                           logins:_logins];
    if (!privateMode) [w setDownloadHistory:_downloads];
    w.github = privateMode ? nil : _github;
    [_windows addObject:w];
    __weak typeof(self) weak = self;
    w.didClose = ^(LTWindow *closed) {
      [weak.windows removeObject:closed];
      if (!weak.quitting)
          [weak saveWindows];
    };
    w.promote = ^(NSString *url, NSString *spaceID) {
      LTWindow *target = nil;
      for (LTWindow *candidate in weak.windows)
          if (!candidate.mini && !candidate.store.privateMode) {
              target = candidate;
              break;
          }
      if (!target)
          target = [weak newWindow:NO mini:NO state:@{@"space" : spaceID}];
      else {
          NSError *error = nil;
          [weak.store
              commit:^(LTProfile *p) {
                p.activeSpaceID = spaceID;
              }
               error:&error];
          [target performSelector:@selector(selectSpace:) withObject:spaceID];
      }
      [target openURL:url];
      [target.window makeKeyAndOrderFront:nil];
    };
    return w;
}
- (LTWindow *)current {
    for (LTWindow *w in _windows)
        if (w.window == NSApp.keyWindow || w.window == NSApp.mainWindow)
            return w;
    return _windows.lastObject;
}
- (void)action:(NSMenuItem *)item {
    NSString *c = item.representedObject;
    if ([c isEqual:@"checkUpdates"])
        [_updater checkForUpdates:item];
    else if ([c isEqual:@"newWindow"])
        [self newWindow:NO mini:NO state:nil];
    else if ([c isEqual:@"newPrivate"])
        [self newWindow:YES mini:NO state:nil];
    else {
        LTWindow *w = [self current];
        if (!w)
            w = [self newWindow:NO mini:NO state:nil];
        [w performCommand:c];
    }
}
- (void)appCommand:(NSNotification *)n {
    if ([n.object isEqual:@"shortcuts"])
        [_shortcuts present];
    else if ([n.object isEqual:@"taskManager"])
        [_taskManager present];
    else if ([n.object isEqual:@"newPrivate"])
        [self newWindow:YES mini:NO state:nil];
    else
        [self newWindow:NO mini:NO state:nil];
}
- (BOOL)saveWindows {
    if (!_store || _quitting)
        return YES;
    NSMutableArray *states = [NSMutableArray new];
    for (LTWindow *w in _windows)
        if (!w.mini && !w.store.privateMode)
            [states addObject:w.restorationState];
    NSError *e = nil;
    if (![_store
            commit:^(LTProfile *p) {
              p.windows = states;
            }
             error:&e]) {
        os_log_error(OS_LOG_DEFAULT, "Lite could not save window restoration metadata");
        return NO;
    }
    return YES;
}
- (void)quit {
    if (_quitting || _confirmingQuit)
        return;
    if (testProfile && [NSProcessInfo.processInfo.arguments containsObject:@"--lite-native-measure"]) {
        [self finishQuit:YES];
        return;
    }
    if (LTLivingBrowserCount() > 1) {
        _confirmingQuit = YES;
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Close all pages and quit Lite?";
        alert.informativeText = @"All windows, including popups and private windows, will close. Active downloads and capture will end, and unsaved website work will be lost. Cancel keeps every browsing session open. Tab addresses and supported scroll positions are saved; this engine cannot restore complete back/forward history after quit.";
        [alert addButtonWithTitle:@"Cancel"];
        [alert addButtonWithTitle:@"Close All and Quit"];
        if ([alert runModal] != NSAlertSecondButtonReturn) { _confirmingQuit = NO; return; }
        _confirmingQuit = NO;
        [self finishQuit:YES];
    } else [self finishQuit:NO];
}
- (void)finishQuit:(BOOL)confirmed {
    if (_quitting) return;
    _confirmingQuit = YES;
    NSArray<LTWindow *> *windows = [_windows copy];
    __block NSUInteger remaining = windows.count;
    void (^finish)(void) = ^{
        if (![self saveWindows]) {
            self.confirmingQuit = NO;
            relaunchAfterClear = NO;
            LTAlert([self current].window, @"Lite could not save this session", @"Every page remains open. Check available disk space and profile permissions, then try again.");
            return;
        }
        if (relaunchAfterClear) {
            NSError *error = nil;
            if (!LTRequestWebsiteDataClear(profileRoot, &error)) {
                self.confirmingQuit = NO;
                relaunchAfterClear = NO;
                LTAlert([self current].window, @"Could not schedule website-data deletion", error.localizedDescription);
                return;
            }
        }
        [self.downloads flush];
        self.confirmingQuit = NO;
        self.quitting = YES;
        [self.performance stop];
        [self.github stop];
        if (confirmed) LTCloseAllBrowsersConfirmed();
        else LTCloseAllBrowsers();
        LTQuitWhenBrowsersClose();
    };
    if (!remaining) { finish(); return; }
    for (LTWindow *window in windows) [window captureSessionStates:^{ if (--remaining == 0) finish(); }];
}
- (void)backupFailed:(NSNotification *)notification {
    if (_store.backupError) LTAlert([self current].window, @"The recovery backup could not be refreshed", _store.backupError.localizedDescription);
}
- (void)clearAllWebsiteData:(NSNotification *)notification {
    if (_quitting || _confirmingQuit) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Clear all website data and restart?";
    alert.informativeText = @"Lite must close every window to remove all Chromium website storage, including inactive sites, cookies, cache, local storage, IndexedDB, service workers, Cache Storage, permissions and HTTP credentials. History is cleared too. Downloads and capture will end; save any website work first. Bookmarks, organization and saved passwords are kept. Cancel leaves all sessions open.";
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Clear and Restart"];
    if ([alert runModal] != NSAlertSecondButtonReturn) return;
    relaunchAfterClear = YES;
    [self finishQuit:YES];
}
- (void)cancelQuit {
    _confirmingQuit = NO;
    if (_quitting) {
        _quitting = NO;
        [_performance start];
        [_github start];
    }
}
- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls)
        if (LTValidURL(url.absoluteString)) {
            LTWindow *w;
            if ([_store.profile.settings[@"externalMini"] boolValue])
                w = [self newWindow:NO mini:YES state:nil];
            else
                w = [self current] ?: [self newWindow:NO mini:NO state:nil];
            [w openURL:url.absoluteString];
        }
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {
    if (!flag)
        [self newWindow:NO mini:NO state:nil];
    return YES;
}
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    [self quit];
    return NSTerminateCancel;
}
- (void)buildMenu {
    NSMenu *main = [NSMenu new];
    NSApp.mainMenu = main;
    NSArray *menus = @[
        @[
            @"Lite", @[ @"About Lite", @"about", @"" ], @[ @"Check for Updates…", @"checkUpdates", @"" ], @[ @"Settings…", @"settings", @"," ],
            @[ @"-" ], @[ @"Hide Lite", @"hide", @"h" ], @[ @"Quit Lite", @"quit", @"q" ]
        ],
        @[
            @"File", @[ @"New Tab", @"newTab", @"t" ], @[ @"New Window", @"newWindow", @"n" ],
            @[ @"New Private Window", @"newPrivate", @"N" ],
            @[ @"Reopen Closed Tab", @"reopenTab", @"T" ], @[ @"Close Tab", @"closeTab", @"w" ],
            @[ @"-" ], @[ @"New Space…", @"newSpace", @"" ], @[ @"New Folder…", @"newFolder", @"" ],
            @[ @"New GitHub Live Folder…", @"githubFolder", @"" ],
            @[ @"-" ], @[ @"Save Page…", @"save", @"s" ], @[ @"Print…", @"print", @"p" ]
        ],
        @[
            @"Edit", @[ @"Undo", @"undo:", @"z" ], @[ @"Redo", @"redo:", @"Z" ], @[ @"-" ],
            @[ @"Cut", @"cut:", @"x" ], @[ @"Copy", @"copy:", @"c" ],
            @[ @"Paste", @"paste:", @"v" ], @[ @"Select All", @"selectAll:", @"a" ], @[ @"-" ],
            @[ @"Find in Page", @"find", @"f" ]
        ],
        @[
            @"View", @[ @"Toggle Sidebar", @"toggleSidebar", @"S" ],
            @[ @"Focus Address", @"address", @"l" ], @[ @"-" ], @[ @"Zoom In", @"zoomIn", @"+" ],
            @[ @"Zoom Out", @"zoomOut", @"-" ], @[ @"Actual Size", @"zoomReset", @"0" ], @[ @"-" ],
            @[ @"Split Right", @"splitRight", @"\\" ], @[ @"Split Down", @"splitDown", @"|" ],
            @[ @"Close Split", @"closeSplit", @"" ], @[ @"Swap Panes", @"swapSplit", @"" ],
            @[ @"Focus Other Pane", @"focusSplit", @"`" ], @[ @"-" ],
            @[ @"Enter Full Screen", @"fullScreen", @"" ],
            @[ @"Developer Tools", @"devTools", @"I" ],
            @[ @"Browser Task Manager", @"taskManager", @"" ],
            @[ @"Content Blocking…", @"contentBlocking", @"" ],
            @[ @"Keyboard Shortcuts…", @"shortcuts", @"" ]
        ],
        @[
            @"Navigate", @[ @"Back", @"back", @"[" ], @[ @"Forward", @"forward", @"]" ],
            @[ @"Reload", @"reload", @"r" ], @[ @"Pin / Unpin Tab", @"pinTab", @"d" ], @[ @"-" ],
            @[ @"Next Space", @"nextSpace", @"}" ], @[ @"Previous Space", @"previousSpace", @"{" ],
            @[ @"Next Tab", @"nextTab", @"]", @"option" ],
            @[ @"Previous Tab", @"previousTab", @"[", @"option" ]
        ],
        @[
            @"Library", @[ @"History", @"history", @"y" ], @[ @"Downloads", @"downloads", @"j" ],
            @[ @"-" ], @[ @"Save Login for This Site…", @"saveLogin", @"" ],
            @[ @"Fill Saved Login…", @"fillLogin", @"" ],
            @[ @"Open Apple Passwords", @"applePasswords", @"" ],
            @[ @"Manage Saved Logins…", @"passwords", @"" ],
            @[ @"Open Google Password Manager", @"googlePasswords", @"" ], @[ @"-" ],
            @[ @"Import from Arc…", @"importArc", @"" ],
            @[ @"Import Bookmarks…", @"importBookmarks", @"" ],
            @[ @"Clear Browsing Data…", @"clearData", @"" ]
        ],
        @[
            @"Window", @[ @"Minimize", @"performMiniaturize:", @"m" ],
            @[ @"Picture in Picture", @"pip", @"" ]
        ]
    ];
    for (NSArray *spec in menus) {
        NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:spec[0] action:nil keyEquivalent:@""];
        NSMenu *menu = [[NSMenu alloc] initWithTitle:spec[0]];
        root.submenu = menu;
        [main addItem:root];
        if ([spec[0] isEqual:@"Window"])
            NSApp.windowsMenu = menu;
        for (NSUInteger i = 1; i < spec.count; i++) {
            NSArray *s = spec[i];
            if ([s[0] isEqual:@"-"]) {
                [menu addItem:NSMenuItem.separatorItem];
                continue;
            }
            NSString *key = s[2];
            NSEventModifierFlags flags = NSEventModifierFlagCommand;
            if (key.length && ![key isEqual:key.lowercaseString]) {
                flags |= NSEventModifierFlagShift;
                key = key.lowercaseString;
            }
            if (s.count > 3)
                flags |= NSEventModifierFlagOption;
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:s[0]
                                                          action:@selector(action:)
                                                   keyEquivalent:key];
            item.keyEquivalentModifierMask = flags;
            item.target = self;
            item.representedObject = s[1];
            if ([s[1] hasSuffix:@":"]) {
                item.action = NSSelectorFromString(s[1]);
                item.target = nil;
            } else if ([s[1] isEqual:@"quit"]) {
                item.action = @selector(terminate:);
                item.target = NSApp;
            } else if ([s[1] isEqual:@"hide"]) {
                item.action = @selector(hide:);
                item.target = NSApp;
            } else if ([s[1] isEqual:@"about"]) {
                item.action = @selector(orderFrontStandardAboutPanel:);
                item.target = NSApp;
            }
            [menu addItem:item];
        }
    }
    NSMenu *services = [NSMenu new];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Services" action:nil keyEquivalent:@""];
    item.submenu = services;
    [main.itemArray.firstObject.submenu insertItem:item atIndex:2];
    NSApp.servicesMenu = services;
}
@end
class BrowserApp : public CefApp, public CefBrowserProcessHandler {
  public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
        return this;
    }
    void OnBeforeCommandLineProcessing(const CefString &type,
                                       CefRefPtr<CefCommandLine> line) override {
        if (type.empty()) {
            line->AppendSwitch("disable-background-networking");
            line->AppendSwitch("disable-component-update");
            line->AppendSwitch("disable-default-apps");
            line->AppendSwitch("no-first-run");
            // Route HTTP/proxy challenges to Lite's CEF callback and native sheet.
            line->AppendSwitch("disable-chrome-login-prompt");
        }
    }

  private:
    IMPLEMENT_REFCOUNTING(BrowserApp);
};
int main(int argc, char **argv) {
    @autoreleasepool {
        CefScopedLibraryLoader library;
        if (!library.LoadInMain())
            return 1;
        [LiteApplication sharedApplication];
        NSString *base =
            NSProcessInfo.processInfo.environment[@"LITE_PROFILE_DIR"]
                ?: [NSHomeDirectory()
                       stringByAppendingPathComponent:@"Library/Application Support/Lite"];
        for (int i = 1; i < argc; i++) {
            NSString *arg = @(argv[i]);
            if ([arg hasPrefix:@"--lite-test-profile="]) {
                base = [arg substringFromIndex:20];
                testProfile = YES;
            }
            if ([arg isEqual:@"--lite-smoke"])
                smokeTest = YES;
        }
        profileRoot = base;
        NSError *directoryError = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions:@0700} error:&directoryError]) return 1;
        int profileLock = open([base stringByAppendingPathComponent:@".Lite.profile.lock"].fileSystemRepresentation,
            O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
        if (profileLock < 0 || flock(profileLock, LOCK_EX | LOCK_NB) != 0) {
            if (profileLock >= 0) close(profileLock);
            LTAlert(nil, @"This Lite profile is already open", @"Use the existing Lite window or choose a separate profile. No website data was changed.");
            return 1;
        }
        NSError *clearError = nil;
        if (!LTPerformPendingWebsiteDataClear(base, &websiteDataCleared, &clearError)) {
            LTAlert(nil, @"Website-data deletion could not finish", clearError.localizedDescription ?: @"The pending reset was preserved. Resolve the file error and reopen Lite to retry. Chromium was not started.");
            return 1;
        }
        CefSettings settings;
        CefString(&settings.root_cache_path) =
            [base stringByAppendingPathComponent:@"Chromium"].UTF8String;
        CefString(&settings.cache_path) =
            [base stringByAppendingPathComponent:@"Chromium/Default"].UTF8String;
        settings.persist_session_cookies = true;
        settings.log_severity = LOGSEVERITY_DISABLE;
        if (!CefInitialize(CefMainArgs(argc, argv), settings, new BrowserApp, nullptr))
            return CefGetExitCode();
        LTAppDelegate *delegate = [LTAppDelegate new];
        NSApp.delegate = delegate;
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t termination = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM,
                                                               0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(termination, ^{
          [delegate quit];
        });
        dispatch_resume(termination);
        [delegate performSelectorOnMainThread:@selector(start) withObject:nil waitUntilDone:NO];
        CefRunMessageLoop();
        [delegate.icons shutdown];
        if (delegate.keyMonitor) [NSEvent removeMonitor:delegate.keyMonitor];
        dispatch_source_cancel(termination);
        NSApp.delegate = nil;
        delegate = nil;
        LTStopBrowserTaskMonitoring();
        CefShutdown();
        close(profileLock);
        if (relaunchAfterClear) {
            NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"-n", NSBundle.mainBundle.bundlePath, nil];
            if (testProfile) {
                [arguments addObjectsFromArray:@[@"--args", [@"--lite-test-profile=" stringByAppendingString:profileRoot]]];
                if ([NSProcessInfo.processInfo.arguments containsObject:@"--use-mock-keychain"]) [arguments addObject:@"--use-mock-keychain"];
            }
            [NSTask launchedTaskWithLaunchPath:@"/usr/bin/open" arguments:arguments];
        }
        return 0;
    }
}

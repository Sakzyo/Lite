#import "LTEngine.h"
#import "LTContentBlocker.h"
#import "../model/LTLoginStore.h"
#include "LTYouTubeFilter.h"
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_cookie.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_ssl_status.h"
#include "include/cef_task.h"
#include "include/cef_task_manager.h"
#include "include/wrapper/cef_closure_task.h"
#include <map>
#include <set>
#include <atomic>
#include <memory>
#include <cmath>
#import <CoreServices/CoreServices.h>

static NSString *N(const CefString &s) {
    return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @"";
}
static CefString C(NSString *s) {
    return CefString(s.UTF8String ?: "");
}
static NSString *WebOrigin(NSString *url) {
    NSURLComponents *components = [NSURLComponents componentsWithString:url];
    if (!components.host.length || ![@[@"http", @"https"] containsObject:components.scheme.lowercaseString]) return nil;
    components.user = nil; components.password = nil; components.path = @"";
    components.query = nil; components.fragment = nil;
    return components.URL.absoluteString;
}
static NSString *DownloadPath(NSString *directory, NSString *suggested) {
    NSString *name = suggested.lastPathComponent.length ? suggested.lastPathComponent : @"Download";
    NSString *path = [directory stringByAppendingPathComponent:name];
    for (NSUInteger index = 1; [NSFileManager.defaultManager fileExistsAtPath:path] && index <= 1000; ++index) {
        NSString *stem = [name stringByDeletingPathExtension], *extension = name.pathExtension;
        NSString *unique = [NSString stringWithFormat:@"%@ (%lu)%@%@", stem, (unsigned long)index, extension.length ? @"." : @"", extension];
        path = [directory stringByAppendingPathComponent:unique];
    }
    return [NSFileManager.defaultManager fileExistsAtPath:path] ? nil : path;
}
static std::map<int, CefRefPtr<CefBrowser>> browsers;
static void CancelBrowserRequests(CefRefPtr<CefBrowser> browser);
static bool quitting = false;
static CefRefPtr<CefTaskManager> taskManager;
static CefRefPtr<CefTaskManager> TaskManager() {
    if (!taskManager) taskManager = CefTaskManager::GetTaskManager();
    return taskManager;
}
void LTStopBrowserTaskMonitoring(void) { taskManager = nullptr; }
NSArray<NSDictionary *> *LTBrowserTasks(void) {
    NSMutableArray *rows = [NSMutableArray new];
    auto manager = TaskManager();
    CefTaskManager::TaskIdList identifiers;
    if (!manager || !manager->GetTaskIdsList(identifiers))
        return rows;
    for (auto identifier : identifiers) {
        CefTaskInfo info;
        if (manager->GetTaskInfo(identifier, info))
            [rows addObject:@{@"id": @(identifier), @"title": N(CefString(&info.title)),
                              @"cpu": @(info.cpu_usage), @"memory": @(info.memory),
                              @"gpu": @(info.gpu_memory), @"killable": @(info.is_killable),
                              @"browser": @(info.type == CEF_TASK_TYPE_BROWSER)}];
    }
    return rows;
}
BOOL LTEndBrowserTask(NSNumber *identifier) {
    auto manager = TaskManager();
    CefTaskInfo info;
    return manager && manager->GetTaskInfo(identifier.longLongValue, info) &&
           info.is_killable && info.type != CEF_TASK_TYPE_BROWSER &&
           manager->KillTask(identifier.longLongValue);
}
NSUInteger LTLivingBrowserCount(void) {
    return browsers.size();
}
void LTCloseAllBrowsers(void) {
    auto copy = browsers;
    for (auto &pair : copy)
        pair.second->GetHost()->CloseBrowser(false);
}
void LTCloseAllBrowsersConfirmed(void) {
    auto copy = browsers;
    for (auto &pair : copy) {
        CancelBrowserRequests(pair.second);
        pair.second->GetHost()->CloseBrowser(true);
    }
}
void LTQuitWhenBrowsersClose(void) {
    quitting = true;
    if (browsers.empty())
        CefQuitMessageLoop();
}

class Completion : public CefCompletionCallback {
  public:
    explicit Completion(void (^done)(void)) : done_(done) {}
    void OnComplete() override { done_(); }
  private:
    void (^done_)(void);
    IMPLEMENT_REFCOUNTING(Completion);
};
class CookiesDeleted : public CefDeleteCookiesCallback {
  public:
    explicit CookiesDeleted(void (^done)(BOOL)) : done_(done) {}
    void OnComplete(int count) override { done_(count >= 0); }
  private:
    void (^done_)(BOOL);
    IMPLEMENT_REFCOUNTING(CookiesDeleted);
};
static CefRefPtr<CefRequestContextHandler> BlockingContext(LTBlockingPolicy *policy);
static void UpdateYouTubeGuard(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                              LTBlockingPolicy *policy) {
    if (!frame || !LTIsYouTubeURL(N(frame->GetURL()))) return;
    auto main = browser->GetMainFrame();
    BOOL enabled = main && [policy enabledForURL:N(main->GetURL())] &&
                          [policy enabledForURL:N(frame->GetURL())];
    NSString *script = enabled ? [[LTContentBlocker shared] youtubeScriptForURL:N(frame->GetURL())] :
        @"window.__liteYouTubeAds?.setEnabled(false);";
    if (script.length) frame->ExecuteJavaScript(C(script), frame->GetURL(), 0);
}
@interface LTBrowserContext () {
  @public
    CefRefPtr<CefRequestContext> _context;
    LTBlockingPolicy *_blocking;
    BOOL _privateMode;
    NSString *_identifier;
}
@end
@implementation LTBrowserContext
- (instancetype)initPrivate:(BOOL)privateMode {
    if ((self = [super init])) {
        _privateMode = privateMode;
        _identifier = privateMode ? NSUUID.UUID.UUIDString : @"regular";
        [LTContentBlocker shared]; // Compile once on the UI thread, before requests begin.
        _blocking = [LTBlockingPolicy new];
        if (privateMode) {
            CefRequestContextSettings settings;
            _context = CefRequestContext::CreateContext(settings, BlockingContext(_blocking));
        } else
            _context = CefRequestContext::CreateContext(CefRequestContext::GetGlobalContext(), BlockingContext(_blocking));
    }
    return self;
}
- (NSString *)contextIdentifier { return _identifier; }
- (void)closeAllBrowsersConfirmed {
    auto copy = browsers;
    for (auto &entry : copy) if (entry.second->GetHost()->GetRequestContext()->IsSame(_context)) {
        CancelBrowserRequests(entry.second);
        entry.second->GetHost()->CloseBrowser(true);
    }
}
- (BOOL)configureFixtureProxyForTesting {
    if (!_privateMode || ![NSProcessInfo.processInfo.arguments containsObject:@"--lite-smoke"]) return NO;
    auto value = CefValue::Create();
    auto proxy = CefDictionaryValue::Create();
    proxy->SetString("mode", "fixed_servers");
    proxy->SetString("server", "http://127.0.0.1:18743");
    proxy->SetString("bypass_list", "<-loopback>");
    value->SetDictionary(proxy);
    CefString error;
    return _context->SetPreference("proxy", value, error);
}
- (void)updateBlockingPreferences:(NSDictionary *)preferences {
    [_blocking updatePreferences:preferences];
    for (auto &entry : browsers) {
        auto browser = entry.second;
        if (!browser->GetHost()->GetRequestContext()->IsSame(_context)) continue;
        std::vector<CefString> frames;
        browser->GetFrameIdentifiers(frames);
        for (const auto &identifier : frames)
            UpdateYouTubeGuard(browser, browser->GetFrameByIdentifier(identifier), _blocking);
    }
}
- (void)clearData {
    [self clearCookiesAndCacheWithCompletion:^(BOOL success, NSString *message) {}];
}
- (void)clearCookiesAndCacheWithCompletion:(void (^)(BOOL, NSString *))completion {
    __block NSInteger pending = 4;
    __block BOOL success = YES;
    void (^done)(BOOL) = ^(BOOL ok) {
        success &= ok;
        if (--pending == 0) completion(success, success ? @"Cookies, HTTP cache, certificate exceptions and HTTP authentication credentials cleared." : @"Cookie deletion failed. Other selected data was cleared.");
    };
    if (!_context->GetCookieManager(nullptr)->DeleteCookies("", "", new CookiesDeleted(done))) done(NO);
    _context->ClearHttpCache(new Completion(^{ done(YES); }));
    _context->ClearCertificateExceptions(new Completion(^{ done(YES); }));
    _context->ClearHttpAuthCredentials(new Completion(^{ done(YES); }));
}
@end

struct BlockingState {
    std::atomic<NSUInteger> count{0};
    std::atomic<unsigned> generation{0};
};
@interface LTPage () {
  @public
    CefRefPtr<CefBrowser> _browser;
    LTBrowserContext *_context;
    std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> _downloads;
    NSMutableDictionary<NSNumber *, NSDictionary *> *_downloadRecords;
    BOOL _discarding;
    BOOL _capturingSession;
    NSMutableArray<NSDictionary *> *_permissionGrants;
    NSMutableSet<NSString *> *_permissionOrigins;
    std::shared_ptr<BlockingState> _blockingState;
}
- (void)didClose;
- (void)restoreScroll;
@end
static bool CreatePopup(CefWindowInfo &info, CefRefPtr<CefClient> &client, LTBrowserContext *context);

static NSString *BlockingResourceType(cef_resource_type_t type) {
    switch (type) {
        case RT_MAIN_FRAME: return @"main_frame";
        case RT_SUB_FRAME: return @"sub_frame";
        case RT_STYLESHEET: return @"stylesheet";
        case RT_SCRIPT: case RT_WORKER: case RT_SHARED_WORKER: case RT_SERVICE_WORKER: return @"script";
        case RT_IMAGE: case RT_FAVICON: return @"image";
        case RT_FONT_RESOURCE: return @"font";
        case RT_OBJECT: return @"object";
        case RT_MEDIA: return @"media";
        case RT_XHR: return @"xmlhttprequest";
        case RT_PING: return @"ping";
        default: return @"other";
    }
}
class BlockingRequest : public CefResourceRequestHandler {
  public:
    BlockingRequest(LTBlockingPolicy *policy, const CefString &initiator,
                    std::shared_ptr<BlockingState> state)
        : policy_(policy), initiator_(N(initiator)), state_(state), generation_(state ? state->generation.load() : 0) {}
    cef_return_value_t OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                                            CefRefPtr<CefRequest> request, CefRefPtr<CefCallback>) override {
        @autoreleasepool {
            NSString *url = N(request->GetURL());
            auto main = browser ? browser->GetMainFrame() : nullptr;
            NSString *top = request->GetResourceType() == RT_MAIN_FRAME ? url : main ? N(main->GetURL()) : initiator_;
            if ([policy_ enabledForURL:top] && [[LTContentBlocker shared] blocksURL:url
                    initiator:initiator_ type:BlockingResourceType(request->GetResourceType())
                    method:N(request->GetMethod())]) {
                if (state_ && generation_ == state_->generation.load()) ++state_->count;
                return RV_CANCEL;
            }
        }
        return RV_CONTINUE;
    }
    CefRefPtr<CefResponseFilter> GetResourceResponseFilter(CefRefPtr<CefBrowser> browser,
            CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
            CefRefPtr<CefResponse> response) override {
        @autoreleasepool {
            NSString *url = N(request->GetURL());
            auto main = browser ? browser->GetMainFrame() : nullptr;
            NSString *top = request->GetResourceType() == RT_MAIN_FRAME ? url :
                main ? N(main->GetURL()) : initiator_;
            if ([policy_ enabledForURL:top] && [policy_ enabledForURL:url] &&
                LTFilterYouTubeResponse(url, BlockingResourceType(request->GetResourceType()),
                                        N(response->GetMimeType())))
                return new LTYouTubeFilter;
        }
        return nullptr;
    }
  private:
    LTBlockingPolicy *__strong policy_;
    NSString *__strong initiator_;
    std::shared_ptr<BlockingState> state_;
    unsigned generation_;
    IMPLEMENT_REFCOUNTING(BlockingRequest);
};
class BlockingContextHandler : public CefRequestContextHandler {
  public:
    explicit BlockingContextHandler(LTBlockingPolicy *policy) : policy_(policy) {}
    CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
        CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>, bool, bool,
        const CefString &initiator, bool &) override {
        // Service-worker requests can have no browser/frame. Use their initiating
        // origin for site policy, and do not attribute them to an arbitrary tab.
        return new BlockingRequest(policy_, initiator, nullptr);
    }
  private:
    LTBlockingPolicy *__strong policy_;
    IMPLEMENT_REFCOUNTING(BlockingContextHandler);
};
static CefRefPtr<CefRequestContextHandler> BlockingContext(LTBlockingPolicy *policy) {
    return new BlockingContextHandler(policy);
}
class SaveSource : public CefStringVisitor {
  public:
    explicit SaveSource(NSURL *url) : url_(url) {}
    void Visit(const CefString &text) override {
        [N(text) writeToURL:url_ atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

  private:
    NSURL *__strong url_;
    IMPLEMENT_REFCOUNTING(SaveSource);
};
static int NextDevToolsID() { static int sequence = 20000; return ++sequence; }
class Evaluation : public CefDevToolsMessageObserver {
  public:
    explicit Evaluation(void (^completion)(id, BOOL), bool javascript = true)
        : completion_(completion), javascript_(javascript) {}
    CefRefPtr<CefRegistration> registration;
    int message_id = 0;
    void Complete(id value, BOOL success) {
        if (finished_) return;
        finished_ = true;
        CefRefPtr<Evaluation> hold(this);
        auto completion = completion_;
        completion_ = nil;
        registration = nullptr;
        completion(value, success);
    }
    void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int id, bool success, const void *result,
                                size_t length) override {
        if (id != message_id) return;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:result length:length] options:0 error:nil];
        Complete(javascript_ ? j[@"result"][@"value"] : j, success && !j[@"exceptionDetails"]);
    }
    void OnDevToolsAgentDetached(CefRefPtr<CefBrowser>) override { Complete(nil, NO); }
  private:
    void (^completion_)(id, BOOL);
    bool javascript_, finished_ = false;
    IMPLEMENT_REFCOUNTING(Evaluation);
};
static void DevTools(CefRefPtr<CefBrowser> browser, NSString *method,
                     CefRefPtr<CefDictionaryValue> params, void (^completion)(id, BOOL), bool javascript = false) {
    if (!browser) { completion(nil, NO); return; }
    CefRefPtr<Evaluation> observer = new Evaluation(completion, javascript);
    observer->message_id = NextDevToolsID();
    observer->registration = browser->GetHost()->AddDevToolsMessageObserver(observer);
    // CEF may replace a requested ID after an auto-numbered method; observe
    // the actual assigned ID rather than losing the response to that method.
    observer->message_id = browser->GetHost()->ExecuteDevToolsMethod(observer->message_id, C(method), params);
    if (!observer->message_id) observer->Complete(nil, NO);
    else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        observer->Complete(nil, NO);
    });
}
@interface LTRequestPrompt : NSObject
@property NSAlert *alert;
@property (copy) void (^cancel)(void);
@property BOOL resolved;
@property BOOL unload;
@end
@implementation LTRequestPrompt
@end
static NSArray<NSString *> *PermissionNames(uint32_t bits, BOOL media) {
    NSArray *names = media ? @[@"microphone", @"camera", @"screen audio", @"screen video"] :
        @[@"augmented reality", @"camera pan, tilt and zoom", @"camera", @"captured surface control",
          @"clipboard", @"top-level storage access", @"disk quota", @"local fonts", @"location",
          @"hand tracking", @"identity provider", @"idle detection", @"microphone", @"MIDI system-exclusive messages",
          @"multiple downloads", @"notifications", @"keyboard lock", @"pointer lock", @"protected media identifier",
          @"protocol handler registration", @"storage access", @"virtual reality", @"web app installation",
          @"window management", @"file system access", @"local network access", @"local network", @"loopback network", @"sensors"];
    NSMutableArray *result = [NSMutableArray new];
    for (unsigned i = 0; i < 32; ++i) if (bits & (1u << i))
        [result addObject:i < names.count ? names[i] : [NSString stringWithFormat:@"unsupported capability 0x%08x", 1u << i]];
    return result;
}
static void ResetOriginPermissions(LTBrowserContext *context, NSString *origin) {
    // Only settings corresponding to capabilities Lite can grant are touched.
    for (auto type : {CEF_CONTENT_SETTING_TYPE_GEOLOCATION, CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS,
        CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA,
        CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE, CEF_CONTENT_SETTING_TYPE_MIDI_SYSEX,
        CEF_CONTENT_SETTING_TYPE_AUTOMATIC_DOWNLOADS, CEF_CONTENT_SETTING_TYPE_SENSORS,
        CEF_CONTENT_SETTING_TYPE_STORAGE_ACCESS})
        context->_context->SetContentSetting(C(origin), C(origin), type, CEF_CONTENT_SETTING_VALUE_DEFAULT);
}
class IconCallback : public CefDownloadImageCallback {
  public:
    explicit IconCallback(LTPage *page) : page_(page), url_(page.url) {}
    void OnDownloadImageFinished(const CefString &, int, CefRefPtr<CefImage> image) override {
        if (!image)
            return;
        int w = 0, h = 0;
        auto binary = image->GetAsPNG(1, true, w, h);
        if (!binary)
            return;
        NSMutableData *d = [NSMutableData dataWithLength:binary->GetSize()];
        binary->GetData(d.mutableBytes, d.length, 0);
        LTPage *p = page_;
        if (!p || ![p.url isEqual:url_])
            return;
        p.favicon = [[NSImage alloc] initWithData:d];
        [p.delegate pageChanged:p];
    }

  private:
    __weak LTPage *page_;
    NSString *url_;
    IMPLEMENT_REFCOUNTING(IconCallback);
};
// DevTools is a standalone Chromium window: it has no LTPage or page policy.
class DevToolsClient : public CefClient, public CefLifeSpanHandler {
  public:
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        browsers[browser->GetIdentifier()] = browser;
        browser->GetHost()->SetAccessibilityState(STATE_ENABLED);
    }
    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        browsers.erase(browser->GetIdentifier());
        if (quitting && browsers.empty()) CefQuitMessageLoop();
    }
  private:
    IMPLEMENT_REFCOUNTING(DevToolsClient);
};
class Client : public CefClient,
               public CefLifeSpanHandler,
               public CefDisplayHandler,
               public CefLoadHandler,
               public CefRequestHandler,
               public CefPermissionHandler,
               public CefDownloadHandler,
               public CefFocusHandler,
               public CefJSDialogHandler {
  public:
    explicit Client(LTPage *p) : page_(p), blocking_(p ? p->_context->_blocking : nil),
        blockingState_(p ? p->_blockingState : std::make_shared<BlockingState>()) {}
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override {
        return this;
    }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override {
        return this;
    }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override {
        return this;
    }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override {
        return this;
    }
    CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
        CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>, bool, bool,
        const CefString &initiator, bool &) override {
        return new BlockingRequest(blocking_, initiator, blockingState_);
    }
    bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefRequest>, bool, bool) override {
        CancelRequests(frame->IsMain());
        if (frame->IsMain()) { ++blockingState_->generation; blockingState_->count = 0; }
        return false;
    }
    void InjectCosmetics(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame) {
        UpdateYouTubeGuard(browser, frame, blocking_);
        auto main = browser->GetMainFrame();
        if (!main || ![blocking_ cosmeticEnabledForURL:N(main->GetURL())]) return;
        NSString *script = [[LTContentBlocker shared] cosmeticScriptForURL:N(frame->GetURL())];
        if (script.length) frame->ExecuteJavaScript(C(script), frame->GetURL(), 0);
    }
    void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int) override {
        InjectCosmetics(browser, frame);
        if (frame->IsMain()) [page_ restoreScroll];
    }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
        return this;
    }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override {
        return this;
    }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override {
        return this;
    }
    CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override {
        return this;
    }
    bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser>, const CefString &, bool,
                              CefRefPtr<CefJSDialogCallback> callback) override {
        LTPage *p = page_;
        if (p && p->_discarding) {
            p.closing = NO;
            p.keepAwake = YES;
            p->_discarding = NO;
            callback->Continue(false, "");
            [p.delegate pageCloseCanceled:p];
            return true;
        }
        if (!p || !p.container.window || p.container.window.attachedSheet) {
            if (p) { p.closing = NO; [p.delegate pageCloseCanceled:p]; }
            callback->Continue(false, ""); return true;
        }
        uint64_t identifier = ++requestSequence_;
        LTRequestPrompt *prompt = [LTRequestPrompt new];
        prompt.alert = [NSAlert new];
        prompt.unload = YES;
        prompt.alert.messageText = @"Leave this page?";
        prompt.alert.informativeText = @"This website reports unsaved changes. Leaving may discard them.";
        [prompt.alert addButtonWithTitle:@"Stay"]; [prompt.alert addButtonWithTitle:@"Leave"];
        prompt.cancel = ^{ p.closing = NO; callback->Continue(false, ""); [p.delegate pageCloseCanceled:p]; };
        prompts_[identifier] = prompt;
        CefRefPtr<Client> hold(this);
        [prompt.alert beginSheetModalForWindow:p.container.window completionHandler:^(NSModalResponse result) {
            if (prompt.resolved) return;
            prompt.resolved = YES; prompt.cancel = nil; hold->prompts_.erase(identifier);
            BOOL leave = result == NSAlertSecondButtonReturn;
            if (!leave) {
                p.closing = NO; quitting = false;
                [p.delegate pageCloseCanceled:p];
                [NSNotificationCenter.defaultCenter postNotificationName:@"LTQuitCanceled" object:nil];
            }
            callback->Continue(leave, "");
        }];
        return true;
    }
    void OnResetDialogState(CefRefPtr<CefBrowser>) override {
        auto pending = prompts_;
        for (auto &entry : pending) {
            LTRequestPrompt *prompt = entry.second;
            if (!prompt.unload || prompt.resolved) continue;
            prompts_.erase(entry.first); prompt.resolved = YES;
            if (prompt.cancel) prompt.cancel(); prompt.cancel = nil;
            if (prompt.alert.window.sheetParent)
                [prompt.alert.window.sheetParent endSheet:prompt.alert.window returnCode:NSAlertFirstButtonReturn];
        }
    }

    void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
        browsers[b->GetIdentifier()] = b;
        LTPage *p = page_;
        if (p)
            p->_browser = b;
        b->GetHost()->SetAccessibilityState(STATE_ENABLED);
    }
    bool DoClose(CefRefPtr<CefBrowser> b) override {
        // Tear down only this native child view, not the shared Lite window.
        if (!page_)
            return false;
        NSView *view = (__bridge NSView *)b->GetHost()->GetWindowHandle();
        [view removeFromSuperview];
        return true;
    }
    void OnBeforeClose(CefRefPtr<CefBrowser> b) override {
        CancelRequests();
        browsers.erase(b->GetIdentifier());
        LTPage *p = page_;
        if (p && p->_browser && p->_browser->IsSame(b))
            [p didClose];
        if (quitting && browsers.empty())
            CefQuitMessageLoop();
    }
    bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString &,
                       const CefString &, WindowOpenDisposition, bool gesture,
                       const CefPopupFeatures &, CefWindowInfo &info, CefRefPtr<CefClient> &client,
                       CefBrowserSettings &, CefRefPtr<CefDictionaryValue> &, bool *) override {
        LTPage *p = page_;
        return !gesture || !p || !CreatePopup(info, client, p->_context);
    }
    bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString &url,
                          WindowOpenDisposition, bool) override {
        LTPage *p = page_;
        [p.delegate page:p openURL:N(url)];
        return true;
    }
    void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> f,
                         const CefString &url) override {
        if (f->IsMain()) {
            LTPage *p = page_;
            if (![p.url isEqual:N(url)])
                p.favicon = nil;
            p.url = N(url);
            p.errorText = @"";
            p.secure = NO;
            [p.delegate pageChanged:p];
        }
    }
    void OnLoadStart(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, TransitionType) override {
        if (frame->IsMain()) {
            LTPage *p = page_;
            p.dirty = NO;
            audio_frames_.clear();
            pip_frames_.clear();
            p.audible = NO;
            p.pictureInPicture = NO;
        }
    }
    void OnTitleChange(CefRefPtr<CefBrowser>, const CefString &title) override {
        LTPage *p = page_;
        p.title = N(title);
        [p.delegate pageChanged:p];
    }
    void OnFaviconURLChange(CefRefPtr<CefBrowser> b, const std::vector<CefString> &urls) override {
        if (!urls.empty())
            b->GetHost()->DownloadImage(urls[0], true, 32, false, new IconCallback(page_));
    }
    bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t, const CefString &,
                          const CefString &, int) override {
        return true;
    }
    void OnMediaAccessChange(CefRefPtr<CefBrowser>, bool video, bool audio) override {
        LTPage *p = page_;
        p.capturing = video || audio;
        [p.delegate pageChanged:p];
    }
    void OnLoadingStateChange(CefRefPtr<CefBrowser> b, bool loading, bool back,
                              bool forward) override {
        LTPage *p = page_;
        p.loading = loading;
        p.canBack = back;
        p.canForward = forward;
        auto entry = b->GetHost()->GetVisibleNavigationEntry();
        auto ssl = entry ? entry->GetSSLStatus() : nullptr;
        p.secure = ssl && ssl->IsSecureConnection() && ssl->GetCertStatus() == 0;
        [p.delegate pageChanged:p];
    }
    void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code,
                     const CefString &, const CefString &) override {
        if (!frame->IsMain() || code == ERR_ABORTED)
            return;
        LTPage *p = page_;
        p.errorText = [NSString
            stringWithFormat:
                @"Page could not load (%d). Check the address or connection, then reload.",
                (int)code];
        [p.delegate pageChanged:p];
    }
    void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus, int,
                                   const CefString &) override {
        CancelRequests();
        LTPage *p = page_;
        p.errorText = @"This tab stopped responding. Reload to restore it.";
        [p.delegate pageChanged:p];
    }
    void OnGotFocus(CefRefPtr<CefBrowser>) override {
        LTPage *p = page_;
        [NSNotificationCenter.defaultCenter postNotificationName:@"LTPageFocused" object:p];
    }
    void CancelRequests(bool resetGrants = true) {
        ++requestGeneration_;
        auto pending = prompts_;
        prompts_.clear();
        for (auto &entry : pending) {
            LTRequestPrompt *prompt = entry.second;
            if (prompt.resolved) continue;
            prompt.resolved = YES;
            if (prompt.cancel) prompt.cancel();
            prompt.cancel = nil;
            if (prompt.alert.window.sheetParent)
                [prompt.alert.window.sheetParent endSheet:prompt.alert.window returnCode:NSAlertFirstButtonReturn];
        }
        LTPage *p = page_;
        if (p && resetGrants) {
            [p->_permissionGrants removeAllObjects];
            [p->_permissionOrigins removeAllObjects];
        }
    }
    void PermissionPrompt(uint64_t identifier, NSString *origin, uint32_t permissions, BOOL media,
                          BOOL supported, void (^answer)(BOOL)) {
        LTPage *p = page_;
        if (!p || p.closing || !p.container.window || p.container.window.attachedSheet ||
            p->_permissionOrigins.count >= 64 || p->_permissionGrants.count >= 64) { answer(NO); return; }
        NSArray *names = PermissionNames(permissions, media);
        [p->_permissionOrigins addObject:origin];
        LTRequestPrompt *prompt = [LTRequestPrompt new];
        prompt.alert = [NSAlert new];
        prompt.alert.messageText = supported ? @"Website permission" : @"Website request denied";
        prompt.alert.informativeText = [NSString stringWithFormat:@"%@\n\nRequested: %@.\n\n%@", origin,
            [names componentsJoinedByString:@", "], supported ?
            (media ? @"Allow this capture request. macOS may require separate permission. Revoke in Site Information; reload stops active capture." :
            @"Saved for this exact origin until revoked in Site Information. Same-origin tabs share this permission. Private permissions end with the private browsing context.") :
            @"Lite cannot safely provide every requested capability. The entire request is denied."];
        [prompt.alert addButtonWithTitle:supported ? @"Deny" : @"OK"];
        if (supported) [prompt.alert addButtonWithTitle:media ? @"Allow for this request" : @"Allow for this site"];
        prompt.cancel = ^{ answer(NO); };
        prompts_[identifier] = prompt;
        CefRefPtr<Client> hold(this);
        [prompt.alert beginSheetModalForWindow:p.container.window completionHandler:^(NSModalResponse result) {
            if (prompt.resolved) return;
            prompt.resolved = YES;
            prompt.cancel = nil;
            hold->prompts_.erase(identifier);
            BOOL allowed = supported && result == NSAlertSecondButtonReturn && p.alive && !p.closing;
            if (allowed && media) {
                NSIndexSet *duplicates = [p->_permissionGrants indexesOfObjectsPassingTest:^BOOL(NSDictionary *grant, NSUInteger index, BOOL *stop) {
                    return [grant[@"origin"] isEqual:origin] && [grant[@"capabilities"] isEqual:names];
                }];
                [p->_permissionGrants removeObjectsAtIndexes:duplicates];
                if (p->_permissionGrants.count < 64) [p->_permissionGrants addObject:@{@"origin": origin, @"capabilities": names,
                    @"lifetime": @"This capture session; reload to stop capture"}];
            }
            answer(allowed);
        }];
    }
    bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                        const CefString &origin, uint32_t permissions,
                                        CefRefPtr<CefMediaAccessCallback> callback) override {
        // Screen capture needs a source chooser, which Alloy does not provide here.
        uint32_t supported = CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE | CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE;
        PermissionPrompt(++requestSequence_, N(origin), permissions, YES,
            permissions && !(permissions & ~supported), ^(BOOL allow) {
                if (allow) callback->Continue(permissions); else callback->Cancel();
            });
        return true;
    }
    bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t identifier, const CefString &origin,
                                uint32_t permissions, CefRefPtr<CefPermissionPromptCallback> callback) override {
        uint32_t supported = CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_MIC_STREAM |
            CEF_PERMISSION_TYPE_CLIPBOARD | CEF_PERMISSION_TYPE_GEOLOCATION | CEF_PERMISSION_TYPE_MIDI_SYSEX |
            CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS | CEF_PERMISSION_TYPE_NOTIFICATIONS |
            CEF_PERMISSION_TYPE_STORAGE_ACCESS | CEF_PERMISSION_TYPE_SENSORS;
        PermissionPrompt(identifier, N(origin), permissions, NO, permissions && !(permissions & ~supported),
            ^(BOOL allow) { callback->Continue(allow ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY); });
        return true;
    }
    void OnDismissPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t identifier,
                                    cef_permission_request_result_t) override {
        auto found = prompts_.find(identifier);
        if (found == prompts_.end()) return;
        LTRequestPrompt *prompt = found->second;
        prompts_.erase(found);
        prompt.resolved = YES;
        prompt.cancel = nil; // CEF already canceled this request; never call its callback again.
        if (prompt.alert.window.sheetParent)
            [prompt.alert.window.sheetParent endSheet:prompt.alert.window returnCode:NSAlertFirstButtonReturn];
    }
    bool GetAuthCredentials(CefRefPtr<CefBrowser>, const CefString &origin, bool proxy,
                            const CefString &host, int port, const CefString &realm,
                            const CefString &scheme, CefRefPtr<CefAuthCallback> callback) override {
        NSString *method = N(scheme).lowercaseString;
        if (![@[@"basic", @"digest"] containsObject:method]) return false;
        unsigned generation = requestGeneration_.load();
        NSString *requestOrigin = WebOrigin(N(origin)) ?: @"", *server = N(host), *challenge = N(realm);
        CefRefPtr<Client> hold(this);
        dispatch_async(dispatch_get_main_queue(), ^{
            LTPage *p = hold->page_;
            if (!p || !p.alive || p.closing || generation != hold->requestGeneration_.load() ||
                !p.container.window || p.container.window.attachedSheet) { callback->Cancel(); return; }
            uint64_t identifier = ++hold->requestSequence_;
            LTRequestPrompt *prompt = [LTRequestPrompt new];
            prompt.alert = [NSAlert new];
            prompt.alert.messageText = proxy ? @"Proxy authentication" : @"Website authentication";
            prompt.alert.informativeText = [NSString stringWithFormat:@"%@:%d\n%@\nRealm: %@\n%@ authentication. Credentials are used only for this challenge and Chromium's session cache.",
                server, port, requestOrigin, challenge, method.uppercaseString];
            NSTextField *username = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 42, 340, 24)];
            username.placeholderString = @"Username"; username.accessibilityLabel = @"Authentication username";
            NSSecureTextField *password = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 6, 340, 24)];
            password.placeholderString = @"Password"; password.accessibilityLabel = @"Authentication password";
            NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 72)];
            [form addSubview:username]; [form addSubview:password];
            prompt.alert.accessoryView = form;
            [prompt.alert addButtonWithTitle:@"Cancel"]; [prompt.alert addButtonWithTitle:@"Sign In"];
            prompt.cancel = ^{ password.stringValue = @""; callback->Cancel(); };
            hold->prompts_[identifier] = prompt;
            [prompt.alert beginSheetModalForWindow:p.container.window completionHandler:^(NSModalResponse result) {
                if (prompt.resolved) return;
                prompt.resolved = YES; prompt.cancel = nil;
                hold->prompts_.erase(identifier);
                NSString *secret = password.stringValue; password.stringValue = @"";
                if (result == NSAlertSecondButtonReturn && p.alive && !p.closing &&
                    generation == hold->requestGeneration_.load()) callback->Continue(C(username.stringValue), C(secret));
                else callback->Cancel();
            }];
            [prompt.alert.window makeFirstResponder:username];
        });
        return true;
    }
    bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem>,
                          const CefString &suggested,
                          CefRefPtr<CefBeforeDownloadCallback> cb) override {
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--lite-smoke"]) {
            for (NSString *argument in NSProcessInfo.processInfo.arguments) {
                if (![argument hasPrefix:@"--lite-test-profile="]) continue;
                NSString *directory = [[argument substringFromIndex:20] stringByAppendingPathComponent:@"Downloads"];
                [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *path = DownloadPath(directory, N(suggested));
                if (path) cb->Continue(C(path), false);
                return true;
            }
        }
        NSString *path = DownloadPath([NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"], N(suggested));
        if (path) cb->Continue(C(path), true);
        return true;
    }
    void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> d,
                           CefRefPtr<CefDownloadItemCallback> cb) override {
        LTPage *p = page_;
        if (!p || !d->IsValid()) return;
        if (d->IsInProgress() || d->IsInterrupted()) p->_downloads[d->GetId()] = cb;
        else p->_downloads.erase(d->GetId());
        if (d->IsInProgress()) download_ids_.insert(d->GetId());
        else download_ids_.erase(d->GetId());
        p.downloading = !download_ids_.empty();
        auto reason = d->GetInterruptReason();
        NSString *failure = @"";
        switch (reason) {
            case CEF_DOWNLOAD_INTERRUPT_REASON_NONE: break;
            case CEF_DOWNLOAD_INTERRUPT_REASON_FILE_NO_SPACE: failure = @"The disk is full."; break;
            case CEF_DOWNLOAD_INTERRUPT_REASON_FILE_ACCESS_DENIED: failure = @"The destination is not writable."; break;
            case CEF_DOWNLOAD_INTERRUPT_REASON_NETWORK_DISCONNECTED: failure = @"The network connection was lost."; break;
            case CEF_DOWNLOAD_INTERRUPT_REASON_NETWORK_TIMEOUT: failure = @"The connection timed out."; break;
            case CEF_DOWNLOAD_INTERRUPT_REASON_SERVER_CERT_PROBLEM: failure = @"The server certificate could not be verified."; break;
            case CEF_DOWNLOAD_INTERRUPT_REASON_USER_CANCELED: failure = @"Canceled."; break;
            case CEF_DOWNLOAD_INTERRUPT_REASON_USER_SHUTDOWN: failure = @"Interrupted when the browser closed."; break;
            default: failure = [NSString stringWithFormat:@"Chromium interrupted the download (reason %d).", reason]; break;
        }
        BOOL quarantine = NO;
        NSString *securityError = @"";
        if (d->IsComplete() && !d->GetFullPath().empty()) {
            NSURL *file = [NSURL fileURLWithPath:N(d->GetFullPath())];
            NSDictionary *existing = nil;
            [file getResourceValue:&existing forKey:NSURLQuarantinePropertiesKey error:nil];
            if (existing.count) quarantine = YES;
            else {
                NSError *error = nil;
                NSDictionary *metadata = @{(__bridge NSString *)kLSQuarantineAgentNameKey: @"Lite",
                    (__bridge NSString *)kLSQuarantineTypeKey: (__bridge NSString *)kLSQuarantineTypeWebDownload,
                    (__bridge NSString *)kLSQuarantineDataURLKey: N(d->GetURL()),
                    (__bridge NSString *)kLSQuarantineOriginURLKey: p.url};
                [file setResourceValue:metadata forKey:NSURLQuarantinePropertiesKey error:&error];
                existing = nil;
                [file getResourceValue:&existing forKey:NSURLQuarantinePropertiesKey error:nil];
                quarantine = existing.count > 0;
                if (!quarantine) securityError = error.localizedDescription ?: @"Download quarantine metadata could not be verified.";
            }
        }
        BOOL resume = d->IsInterrupted() && (reason == CEF_DOWNLOAD_INTERRUPT_REASON_NETWORK_FAILED ||
            reason == CEF_DOWNLOAD_INTERRUPT_REASON_NETWORK_TIMEOUT || reason == CEF_DOWNLOAD_INTERRUPT_REASON_NETWORK_DISCONNECTED ||
            reason == CEF_DOWNLOAD_INTERRUPT_REASON_NETWORK_SERVER_DOWN || reason == CEF_DOWNLOAD_INTERRUPT_REASON_FILE_NO_SPACE);
        NSString *status = d->IsComplete() ? @"complete" : d->IsCanceled() ? @"canceled" :
            d->IsInterrupted() ? @"interrupted" : d->IsPaused() ? @"paused" : @"active";
        NSDictionary *record = @{@"id": @(d->GetId()), @"page": p.identifier,
            @"name": N(d->GetSuggestedFileName()), @"path": N(d->GetFullPath()), @"url": N(d->GetURL()),
            @"percent": @(d->GetPercentComplete()), @"received": @(d->GetReceivedBytes()), @"total": @(d->GetTotalBytes()),
            @"complete": @(d->IsComplete()), @"active": @(d->IsInProgress()), @"paused": @(d->IsPaused()),
            @"canceled": @(d->IsCanceled()), @"interrupted": @(d->IsInterrupted()), @"canResume": @(resume),
            @"status": status, @"reason": failure, @"reasonCode": @(reason), @"time": @(NSDate.date.timeIntervalSince1970),
            @"quarantined": @(quarantine), @"securityError": securityError};
        if (d->IsInProgress() || resume) p->_downloadRecords[@(d->GetId())] = record;
        else { [p->_downloadRecords removeObjectForKey:@(d->GetId())]; p->_downloads.erase(d->GetId()); }
        // Interrupted retries are bounded independently of active transfers.
        if (p->_downloadRecords.count > 100) for (NSNumber *identifier in [p->_downloadRecords.allKeys copy]) {
            if (p->_downloadRecords.count <= 100) break;
            if ([p->_downloadRecords[identifier][@"active"] boolValue]) continue;
            p->_downloads.erase(identifier.unsignedIntValue);
            [p->_downloadRecords removeObjectForKey:identifier];
        }
        [NSNotificationCenter.defaultCenter postNotificationName:@"LTDownloadChanged" object:p userInfo:record];
        [p.delegate page:p downloadChanged:record];
    }
    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                  CefProcessId source,
                                  CefRefPtr<CefProcessMessage> message) override {
        if (source == PID_RENDERER && message->GetName() == "LiteCosmeticReady") {
            InjectCosmetics(browser, frame);
            return true;
        }
        if (source == PID_RENDERER && message->GetName() == "LiteLoginSubmitted") {
            LTPage *p = page_;
            auto args = message->GetArgumentList();
            if (!p || p->_context->_privateMode || !frame->IsMain() || args->GetSize() != 4) return true;
            for (size_t i = 0; i < 4; i++) if (args->GetType(i) != VTYPE_STRING) return true;
            NSString *origin = LTLoginOrigin(N(frame->GetURL()));
            NSString *username = N(args->GetString(1)), *password = N(args->GetString(2));
            auto entry = browser->GetHost()->GetVisibleNavigationEntry();
            auto ssl = entry ? entry->GetSSLStatus() : nullptr;
            BOOL secure = ssl && ssl->IsSecureConnection() && ssl->GetCertStatus() == 0;
            if (!origin || ![origin isEqual:N(args->GetString(0))] ||
                ![origin isEqual:N(args->GetString(3))] ||
                ![origin isEqual:LTLoginOrigin(p.url)] ||
                (!secure && ![origin hasPrefix:@"http://"]) ||
                !password.length || password.length > 16384 || username.length > 1024) return true;
            if ([p.delegate respondsToSelector:@selector(page:submittedLogin:)])
                [p.delegate page:p submittedLogin:@{@"origin": origin, @"username": username, @"password": password}];
            return true;
        }
        if (source != PID_RENDERER || message->GetName() != "LiteLifecycle")
            return false;
        auto args = message->GetArgumentList();
        LTPage *p = page_;
        if (args->GetSize() != 2 || args->GetType(0) != VTYPE_INT || args->GetType(1) != VTYPE_BOOL) return true;
        int flag = args->GetInt(0);
        if (flag == 1)
            p.dirty = YES;
        if (flag == 2) {
            if (args->GetBool(1))
                audio_frames_.insert(frame->GetIdentifier());
            else
                audio_frames_.erase(frame->GetIdentifier());
            p.audible = !audio_frames_.empty();
        }
        if (flag == 3) {
            if (args->GetBool(1))
                pip_frames_.insert(frame->GetIdentifier());
            else
                pip_frames_.erase(frame->GetIdentifier());
            p.pictureInPicture = !pip_frames_.empty();
        }
        [p.delegate pageChanged:p];
        return true;
    }

  private:
    __weak LTPage *page_;
    LTBlockingPolicy *__strong blocking_;
    std::shared_ptr<BlockingState> blockingState_;
    std::set<CefString> audio_frames_, pip_frames_;
    std::set<uint32_t> download_ids_;
    std::map<uint64_t, LTRequestPrompt *__strong> prompts_;
    uint64_t requestSequence_ = 1ull << 63;
    std::atomic<unsigned> requestGeneration_{0};
    IMPLEMENT_REFCOUNTING(Client);
};
static void CancelBrowserRequests(CefRefPtr<CefBrowser> browser) {
    if (auto client = dynamic_cast<Client *>(browser->GetHost()->GetClient().get())) client->CancelRequests();
}
@implementation LTPage
- (instancetype)initWithID:(NSString *)identifier
                       url:(NSString *)url
                   context:(LTBrowserContext *)context {
    if ((self = [super init])) {
        _blockingState = std::make_shared<BlockingState>();
        _permissionGrants = [NSMutableArray new];
        _permissionOrigins = [NSMutableSet new];
        _downloadRecords = [NSMutableDictionary new];
        _identifier = identifier;
        _url = url;
        _title = @"New Tab";
        _errorText = @"";
        _context = context;
        _container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
        _container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _lastVisible = NSDate.date.timeIntervalSince1970;
    }
    return self;
}
- (BOOL)alive {
    return _browser != nullptr;
}
- (NSUInteger)blockedRequests { return _blockingState->count.load(); }
- (BOOL)privateMode { return _context->_privateMode; }
- (NSString *)contextIdentifier { return _context->_identifier; }
- (NSArray<NSDictionary *> *)permissionGrants {
    NSMutableArray *grants = [_permissionGrants mutableCopy];
    NSMutableSet *origins = [NSMutableSet new];
    for (NSString *origin in _permissionOrigins) [origins addObject:WebOrigin(origin) ?: origin];
    NSString *current = WebOrigin(_url);
    if (current) [origins addObject:current];
    struct { cef_content_setting_types_t type; NSString *name; } settings[] = {
        {CEF_CONTENT_SETTING_TYPE_GEOLOCATION, @"location"}, {CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS, @"notifications"},
        {CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC, @"microphone"}, {CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA, @"camera"},
        {CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE, @"clipboard"}, {CEF_CONTENT_SETTING_TYPE_MIDI_SYSEX, @"MIDI system-exclusive messages"},
        {CEF_CONTENT_SETTING_TYPE_AUTOMATIC_DOWNLOADS, @"multiple downloads"}, {CEF_CONTENT_SETTING_TYPE_SENSORS, @"sensors"},
        {CEF_CONTENT_SETTING_TYPE_STORAGE_ACCESS, @"storage access"}};
    for (NSString *origin in origins) for (auto setting : settings)
        if (_context->_context->GetContentSetting(C(origin), C(origin), setting.type) == CEF_CONTENT_SETTING_VALUE_ALLOW &&
            _context->_context->GetContentSetting("", "", setting.type) != CEF_CONTENT_SETTING_VALUE_ALLOW)
            [grants addObject:@{@"origin": origin, @"capabilities": @[setting.name],
                @"lifetime": self.privateMode ? @"Until revoked or this private context closes" : @"Until revoked; shared across same-origin tabs"}];
    return grants;
}
- (void)revokePermissions {
    NSMutableSet *origins = [NSMutableSet new];
    for (NSString *origin in _permissionOrigins) [origins addObject:WebOrigin(origin) ?: origin];
    NSString *current = WebOrigin(_url);
    if (current) [origins addObject:current];
    for (NSDictionary *grant in _permissionGrants) [origins addObject:grant[@"origin"]];
    for (NSString *origin in origins) ResetOriginPermissions(_context, origin);
    if (_browser) static_cast<Client *>(_browser->GetHost()->GetClient().get())->CancelRequests();
    // Reload releases existing capture streams and geolocation watchers as well as grants.
    if (_browser) [self reload];
}
- (void)clearSiteDataWithCompletion:(void (^)(BOOL, NSString *))completion {
    NSString *origin = WebOrigin(_url);
    if (!_browser || !origin) { completion(NO, @"Open an HTTP or HTTPS page before clearing its website data."); return; }
    auto browser = _browser;
    auto parameters = CefDictionaryValue::Create();
    parameters->SetString("origin", C(origin));
    parameters->SetString("storageTypes", "all");
    ResetOriginPermissions(_context, origin);
    static_cast<Client *>(browser->GetHost()->GetClient().get())->CancelRequests();
    // CDP removes engine-managed IndexedDB, local storage, service workers,
    // Cache Storage, cookies, file systems and storage buckets for this origin.
    DevTools(browser, @"Storage.clearDataForOrigin", parameters, ^(id result, BOOL success) {
        if (!success) { completion(NO, @"Chromium could not finish clearing this origin. Keep the page open and try again."); return; }
        auto storage = CefDictionaryValue::Create(), identifier = CefDictionaryValue::Create();
        identifier->SetString("securityOrigin", C(origin));
        identifier->SetBool("isLocalStorage", false);
        storage->SetDictionary("storageId", identifier);
        DevTools(browser, @"DOMStorage.clear", storage, ^(id result, BOOL cleared) {
            if (!cleared) { completion(NO, @"Persistent storage was cleared, but Chromium could not clear this page's session storage. Close this site's pages and try again."); return; }
            self->_context->_context->ClearHttpCache(new Completion(^{
                completion(YES, @"Website storage and cookies for this origin were cleared. The shared HTTP cache was cleared. Reload open pages to drop any in-memory data.");
            }));
        });
    });
}
- (void)captureSessionState:(void (^)(void))completion {
    if (!_browser || _loading) { self.sessionState = nil; completion(); return; }
    auto entry = _browser->GetHost()->GetVisibleNavigationEntry();
    if (!entry || entry->HasPostData()) { self.sessionState = nil; completion(); return; }
    NSString *url = [_url copy];
    auto browser = _browser;
    // Layout metrics come from the engine rather than page-overridable JS globals.
    DevTools(browser, @"Page.getLayoutMetrics", nullptr, ^(id value, BOOL success) {
        NSDictionary *viewport = [value isKindOfClass:NSDictionary.class] ? value[@"cssLayoutViewport"] : nil;
        double x = [viewport[@"pageX"] doubleValue], y = [viewport[@"pageY"] doubleValue];
        if (success && self->_browser && self->_browser->IsSame(browser) && [self.url isEqual:url] &&
            std::isfinite(x) && std::isfinite(y) && x >= 0 && y >= 0 && x <= 1e7 && y <= 1e7)
            self.sessionState = @{@"url": url, @"scrollX": @(x), @"scrollY": @(y)};
        completion();
    });
}
- (void)restoreScroll {
    NSDictionary *state = _sessionState;
    if (!_browser || ![state[@"url"] isEqual:_url]) return;
    id x = state[@"scrollX"], y = state[@"scrollY"];
    if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class] ||
        !std::isfinite([x doubleValue]) || !std::isfinite([y doubleValue]) ||
        [x doubleValue] < 0 || [y doubleValue] < 0 || [x doubleValue] > 1e7 || [y doubleValue] > 1e7) return;
    _sessionState = nil;
    [self evaluateJavaScript:[NSString stringWithFormat:@"window.scrollTo(%f,%f);true", [x doubleValue], [y doubleValue]] completion:^(id value, BOOL success) {}];
}
- (void)loadIfNeeded {
    if (_browser || _closing)
        return;
    CefWindowInfo window;
    window.SetAsChild(
        (__bridge void *)_container,
        CefRect(0, 0, MAX(1, _container.bounds.size.width), MAX(1, _container.bounds.size.height)));
    window.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserSettings settings;
    settings.background_color = CefColorSetARGB(255, 250, 250, 250);
    auto extra = CefDictionaryValue::Create();
    extra->SetBool("liteSaveLogins", !_context->_privateMode);
    _browser = CefBrowserHost::CreateBrowserSync(window, new Client(self), C(_url), settings,
                                                 extra, _context->_context);
    if (_browser) {
        NSView *view = (__bridge NSView *)_browser->GetHost()->GetWindowHandle();
        view.frame = _container.bounds;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    } else {
        self.errorText = @"Chromium could not create this page.";
        [_delegate pageChanged:self];
    }
}
- (void)navigate:(NSString *)url {
    self.sessionState = nil;
    self.url = url;
    [self freeze:NO];
    [self loadIfNeeded];
    if (_browser)
        _browser->GetMainFrame()->LoadURL(C(url));
}
- (void)back {
    if (_browser)
        _browser->GoBack();
}
- (void)forward {
    if (_browser)
        _browser->GoForward();
}
- (void)reload {
    self.errorText = @"";
    [self loadIfNeeded];
    if (_browser)
        _browser->Reload();
}
- (void)stop {
    if (_browser)
        _browser->StopLoad();
}
- (void)focus {
    if (_browser)
        _browser->GetHost()->SetFocus(true);
}
- (void)close {
    if (_browser) {
        static_cast<Client *>(_browser->GetHost()->GetClient().get())->CancelRequests();
        _closing = YES;
        _browser->GetHost()->CloseBrowser(false);
    }
}
- (void)closeConfirmed {
    if (_browser) {
        static_cast<Client *>(_browser->GetHost()->GetClient().get())->CancelRequests();
        _closing = YES;
        _browser->GetHost()->CloseBrowser(true);
    }
}
- (void)discard {
    if (!_browser || _capturingSession || _closing || _visible || _loading || _dirty || _audible ||
        _capturing || _downloading || _pictureInPicture || _keepAwake) return;
    auto entry = _browser->GetHost()->GetVisibleNavigationEntry();
    // CEF exposes history enumeration but no import/serialization mechanism.
    // Keep navigable and POST sessions intact; never replay requests to fake a stack.
    if (_browser->CanGoBack() || _browser->CanGoForward() || !entry || entry->HasPostData()) {
        [self freeze:YES];
        return;
    }
    _capturingSession = YES;
    NSString *url = [_url copy];
    [self evaluateJavaScript:@"history.length === 1 && history.state === null && sessionStorage.length === 0"
        completion:^(id value, BOOL success) {
            if (!success || ![value isEqual:@YES] || ![self.url isEqual:url]) { self->_capturingSession = NO; return; }
            [self captureSessionState:^{
                self->_capturingSession = NO;
                if (!self->_browser || ![self.url isEqual:url] || self.visible || self.loading || self.dirty ||
                    self.audible || self.capturing || self.downloading || self.pictureInPicture || self.keepAwake ||
                    ![self.sessionState[@"url"] isEqual:url]) return;
                auto current = self->_browser->GetHost()->GetVisibleNavigationEntry();
                if (!current || current->HasPostData() || self->_browser->CanGoBack() || self->_browser->CanGoForward()) return;
                self->_discarding = YES;
                [self close];
            }];
        }];
}
- (void)didClose {
    _browser = nullptr;
    _downloads.clear();
    for (NSDictionary *record in _downloadRecords.allValues) {
        NSMutableDictionary *interrupted = [record mutableCopy];
        interrupted[@"active"] = @NO; interrupted[@"paused"] = @NO; interrupted[@"canResume"] = @NO;
        interrupted[@"interrupted"] = @YES; interrupted[@"status"] = @"interrupted";
        interrupted[@"reasonCode"] = @(CEF_DOWNLOAD_INTERRUPT_REASON_USER_SHUTDOWN);
        interrupted[@"reason"] = @"The owning page closed. Start the download again from its website.";
        [NSNotificationCenter.defaultCenter postNotificationName:@"LTDownloadChanged" object:self userInfo:interrupted];
        [_delegate page:self downloadChanged:interrupted];
    }
    [_downloadRecords removeAllObjects];
    _downloading = NO;
    _capturingSession = NO;
    _closing = NO;
    _discarding = NO;
    _frozen = NO;
    [_delegate pageClosed:self];
}
- (void)setVisible:(BOOL)visible {
    _visible = visible;
    _container.hidden = !visible;
    if (visible) {
        _lastVisible = NSDate.date.timeIntervalSince1970;
        [self freeze:NO];
    }
}
- (void)freeze:(BOOL)freeze {
    if (!_browser || _frozen == freeze)
        return;
    if (freeze && (_visible || _dirty || _audible || _capturing || _downloading ||
                   _pictureInPicture || _keepAwake))
        return;
    auto params = CefDictionaryValue::Create();
    params->SetString("state", freeze ? "frozen" : "active");
    _browser->GetHost()->ExecuteDevToolsMethod(NextDevToolsID(), "Page.setWebLifecycleState", params);
    _frozen = freeze;
}
- (void)find:(NSString *)text forward:(BOOL)forward next:(BOOL)next {
    if (_browser)
        _browser->GetHost()->Find(C(text), forward, false, next);
}
- (void)stopFinding {
    if (_browser)
        _browser->GetHost()->StopFinding(true);
}
- (void)zoom:(double)delta {
    if (_browser)
        _browser->GetHost()->SetZoomLevel(_browser->GetHost()->GetZoomLevel() + delta);
}
- (void)resetZoom {
    if (_browser)
        _browser->GetHost()->SetZoomLevel(0);
}
- (void)print {
    if (_browser)
        _browser->GetHost()->Print();
}
- (void)save {
    if (!_browser)
        return;
    NSSavePanel *p = [NSSavePanel savePanel];
    p.nameFieldStringValue = @"Page.html";
    p.message = @"Save the page's HTML source. Linked images and scripts remain online.";
    [p beginSheetModalForWindow:_container.window
              completionHandler:^(NSModalResponse r) {
                if (r == NSModalResponseOK && self->_browser)
                    self->_browser->GetMainFrame()->GetSource(new SaveSource(p.URL));
              }];
}
- (void)showDevTools {
    if (_browser) {
        CefWindowInfo info;
        CefBrowserSettings settings;
        _browser->GetHost()->ShowDevTools(info, new DevToolsClient, settings, CefPoint());
    }
}
- (BOOL)hasDevTools {
    return _browser && _browser->GetHost()->HasDevTools();
}
- (void)closeDevTools {
    if (_browser) _browser->GetHost()->CloseDevTools();
}
- (void)toggleMute {
    if (_browser)
        _browser->GetHost()->SetAudioMuted(!_browser->GetHost()->IsAudioMuted());
}
- (void)script:(NSString *)script {
    if (!_browser)
        return;
    auto p = CefDictionaryValue::Create();
    p->SetString("expression", C(script));
    p->SetBool("userGesture", true);
    _browser->GetHost()->ExecuteDevToolsMethod(NextDevToolsID(), "Runtime.evaluate", p);
}
- (void)togglePlayback {
    [self script:@"(()=>{const m=[...document.querySelectorAll('video,audio')];const "
                 @"playing=m.some(v=>!v.paused);for(const v of m){if(playing)v.pause();else "
                 @"v.play().catch(()=>{});}})()"];
}
- (void)enterPictureInPicture {
    [self script:@"(()=>{const "
                 @"v=[...document.querySelectorAll('video')].find(v=>v.readyState>0&&!v."
                 @"disablePictureInPicture);if(v&&document.pictureInPictureEnabled)v."
                 @"requestPictureInPicture().catch(()=>{});})()"];
}
- (void)downloadAction:(NSString *)action identifier:(NSInteger)identifier {
    auto it = _downloads.find((uint32_t)identifier);
    if (it == _downloads.end())
        return;
    if ([action isEqual:@"cancel"])
        it->second->Cancel();
    if ([action isEqual:@"pause"])
        it->second->Pause();
    if ([action isEqual:@"resume"])
        it->second->Resume();
}
- (void)evaluateForTesting:(NSString *)expression completion:(void (^)(id, BOOL))completion {
    [self evaluateJavaScript:expression completion:completion];
}
- (void)evaluateJavaScript:(NSString *)expression completion:(void (^)(id, BOOL))completion {
    if (!_browser) {
        completion(nil, NO);
        return;
    }
    auto params = CefDictionaryValue::Create();
    params->SetString("expression", C(expression));
    params->SetBool("returnByValue", true);
    params->SetBool("awaitPromise", true);
    params->SetBool("userGesture", true);
    DevTools(_browser, @"Runtime.evaluate", params, completion, true);
}
@end

// Popup windows keep Chromium's original opener and request context intact,
// which is required by sign-in flows using window.open / postMessage.
@interface LTPopup : NSWindowController <NSWindowDelegate, LTPageDelegate>
@property LTPage *page;
@end
static NSMutableArray<LTPopup *> *popups;
@implementation LTPopup
- (void)pageChanged:(LTPage *)page {
    NSString *origin = WebOrigin(page.url) ?: [NSURL URLWithString:page.url].scheme ?: @"Popup";
    self.window.title = [NSString stringWithFormat:@"Lite%@ — %@ — %@", page.privateMode ? @" Private" : @"",
        origin, page.secure ? @"Secure connection" : @"Not secure"];
    self.window.accessibilityLabel = self.window.title;
}
- (void)pageClosed:(LTPage *)page {
    [self.window close];
    [popups removeObject:self];
}
- (void)pageCloseCanceled:(LTPage *)page {
}
- (BOOL)windowShouldClose:(NSWindow *)window {
    if (_page.alive) {
        [_page close];
        return NO;
    }
    return YES;
}
- (void)page:(LTPage *)page openURL:(NSString *)url {
    [page navigate:url];
}
- (void)page:(LTPage *)page downloadChanged:(NSDictionary *)download {
}
@end
static bool CreatePopup(CefWindowInfo &info, CefRefPtr<CefClient> &client, LTBrowserContext *context) {
    if (!popups)
        popups = [NSMutableArray new];
    if (popups.count >= 10)
        return false;
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 640)
                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                              NSWindowStyleMaskResizable
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    window.releasedWhenClosed = NO;
    window.title = @"Lite — Popup";
    LTPopup *popup = [[LTPopup alloc] initWithWindow:window];
    LTPage *page = [[LTPage alloc] initWithID:NSUUID.UUID.UUIDString
                                          url:@"about:blank"
                                      context:context];
    popup.page = page;
    page.delegate = popup;
    page.keepAwake = YES;
    window.delegate = popup;
    window.contentView = page.container;
    [popups addObject:popup];
    info.SetAsChild((__bridge void *)page.container, CefRect(0, 0, 760, 640));
    client = new Client(page);
    [window center];
    [window makeKeyAndOrderFront:nil];
    return true;
}

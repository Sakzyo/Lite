#import "LTEngine.h"
#import "LTContentBlocker.h"
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

static NSString *N(const CefString &s) {
    return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @"";
}
static CefString C(NSString *s) {
    return CefString(s.UTF8String ?: "");
}
static std::map<int, CefRefPtr<CefBrowser>> browsers;
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
void LTQuitWhenBrowsersClose(void) {
    quitting = true;
    if (browsers.empty())
        CefQuitMessageLoop();
}

static CefRefPtr<CefRequestContextHandler> BlockingContext(LTBlockingPolicy *policy);
@interface LTBrowserContext () {
  @public
    CefRefPtr<CefRequestContext> _context;
    LTBlockingPolicy *_blocking;
}
@end
@implementation LTBrowserContext
- (instancetype)initPrivate:(BOOL)privateMode {
    if ((self = [super init])) {
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
- (void)updateBlockingPreferences:(NSDictionary *)preferences {
    [_blocking updatePreferences:preferences];
}
- (void)clearData {
    _context->GetCookieManager(nullptr)->DeleteCookies("", "", nullptr);
    _context->ClearHttpCache(nullptr);
    _context->ClearCertificateExceptions(nullptr);
    _context->ClearHttpAuthCredentials(nullptr);
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
    BOOL _discarding;
    std::shared_ptr<BlockingState> _blockingState;
}
- (void)didClose;
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
class Evaluation : public CefDevToolsMessageObserver {
  public:
    explicit Evaluation(void (^completion)(id, BOOL)) : completion_(completion) {}
    CefRefPtr<CefRegistration> registration;
    int message_id = 0;
    void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int id, bool success, const void *result,
                                size_t length) override {
        if (id != message_id)
            return;
        CefRefPtr<Evaluation> hold(this);
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:result
                                                                                 length:length]
                                                          options:0
                                                            error:nil];
        completion_(j[@"result"][@"value"], success && !j[@"exceptionDetails"]);
        registration = nullptr;
    }

  private:
    void (^completion_)(id, BOOL);
    IMPLEMENT_REFCOUNTING(Evaluation);
};
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
    explicit Client(LTPage *p) : page_(p), blocking_(p->_context->_blocking), blockingState_(p->_blockingState) {}
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
        if (frame->IsMain()) { ++blockingState_->generation; blockingState_->count = 0; }
        return false;
    }
    void InjectCosmetics(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame) {
        auto main = browser->GetMainFrame();
        if (!main || ![blocking_ cosmeticEnabledForURL:N(main->GetURL())]) return;
        NSString *script = [[LTContentBlocker shared] cosmeticScriptForURL:N(frame->GetURL())];
        if (script.length) frame->ExecuteJavaScript(C(script), frame->GetURL(), 0);
    }
    void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int) override {
        InjectCosmetics(browser, frame);
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
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Leave this page?";
        alert.informativeText = @"This website reports unsaved changes. Leaving may discard them.";
        [alert addButtonWithTitle:@"Stay"];
        [alert addButtonWithTitle:@"Leave"];
        if (!p.container.window) {
            callback->Continue(false, "");
            return true;
        }
        [alert beginSheetModalForWindow:p.container.window
                      completionHandler:^(NSModalResponse result) {
                        BOOL leave = result == NSAlertSecondButtonReturn;
                        if (!leave) {
                            p.closing = NO;
                            quitting = false;
                            [p.delegate pageCloseCanceled:p];
                            [NSNotificationCenter.defaultCenter
                                postNotificationName:@"LTQuitCanceled"
                                              object:nil];
                        }
                        callback->Continue(leave, "");
                      }];
        return true;
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
        LTPage *p = page_;
        p.errorText = @"This tab stopped responding. Reload to restore it.";
        [p.delegate pageChanged:p];
    }
    void OnGotFocus(CefRefPtr<CefBrowser>) override {
        LTPage *p = page_;
        [NSNotificationCenter.defaultCenter postNotificationName:@"LTPageFocused" object:p];
    }
    bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                        const CefString &origin, uint32_t permissions,
                                        CefRefPtr<CefMediaAccessCallback> callback) override {
        LTPage *p = page_;
        NSAlert *a = [NSAlert new];
        a.messageText = @"Allow camera or microphone access?";
        a.informativeText =
            [NSString stringWithFormat:@"%@ requests access to %@%@.", N(origin),
                                       (permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE)
                                           ? @"your camera "
                                           : @"",
                                       (permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE)
                                           ? @"your microphone"
                                           : @"screen capture"];
        [a addButtonWithTitle:@"Deny"];
        [a addButtonWithTitle:@"Allow for this request"];
        if (!p.container.window) {
            callback->Cancel();
            return true;
        }
        [a beginSheetModalForWindow:p.container.window
                  completionHandler:^(NSModalResponse r) {
                    callback->Continue(r == NSAlertSecondButtonReturn ? permissions : 0);
                  }];
        return true;
    }
    bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t, const CefString &origin,
                                uint32_t permissions,
                                CefRefPtr<CefPermissionPromptCallback> callback) override {
        LTPage *p = page_;
        NSAlert *a = [NSAlert new];
        a.messageText = @"Website permission";
        a.informativeText = [NSString
            stringWithFormat:@"%@ requests %@. Allow only if you trust this site.", N(origin),
                             permissions == CEF_PERMISSION_TYPE_GEOLOCATION ? @"your location"
                             : permissions == CEF_PERMISSION_TYPE_NOTIFICATIONS
                                 ? @"notifications"
                                 : @"an additional browser capability"];
        [a addButtonWithTitle:@"Deny"];
        [a addButtonWithTitle:@"Allow once"];
        if (!p.container.window) {
            callback->Continue(CEF_PERMISSION_RESULT_DENY);
            return true;
        }
        [a beginSheetModalForWindow:p.container.window
                  completionHandler:^(NSModalResponse r) {
                    callback->Continue(r == NSAlertSecondButtonReturn ? CEF_PERMISSION_RESULT_ACCEPT
                                                                      : CEF_PERMISSION_RESULT_DENY);
                  }];
        return true;
    }
    bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem>,
                          const CefString &suggested,
                          CefRefPtr<CefBeforeDownloadCallback> cb) override {
        cb->Continue(
            C([NSHomeDirectory()
                stringByAppendingPathComponent:
                    [@"Downloads" stringByAppendingPathComponent:N(suggested).lastPathComponent]]),
            true);
        return true;
    }
    void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> d,
                           CefRefPtr<CefDownloadItemCallback> cb) override {
        LTPage *p = page_;
        if (!p)
            return;
        p->_downloads[d->GetId()] = cb;
        if (d->IsInProgress())
            download_ids_.insert(d->GetId());
        else
            download_ids_.erase(d->GetId());
        p.downloading = !download_ids_.empty();
        [p.delegate page:p
            downloadChanged:@{
                @"id" : @(d->GetId()),
                @"page" : p.identifier,
                @"name" : N(d->GetSuggestedFileName()),
                @"path" : N(d->GetFullPath()),
                @"percent" : @(d->GetPercentComplete()),
                @"complete" : @(d->IsComplete()),
                @"active" : @(d->IsInProgress()),
                @"paused" : @(d->IsPaused()),
                @"canceled" : @(d->IsCanceled())
            }];
    }
    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                  CefProcessId source,
                                  CefRefPtr<CefProcessMessage> message) override {
        if (source == PID_RENDERER && message->GetName() == "LiteCosmeticReady") {
            InjectCosmetics(browser, frame);
            return true;
        }
        if (source != PID_RENDERER || message->GetName() != "LiteLifecycle")
            return false;
        auto args = message->GetArgumentList();
        LTPage *p = page_;
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
    IMPLEMENT_REFCOUNTING(Client);
};
@implementation LTPage
- (instancetype)initWithID:(NSString *)identifier
                       url:(NSString *)url
                   context:(LTBrowserContext *)context {
    if ((self = [super init])) {
        _blockingState = std::make_shared<BlockingState>();
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
    _browser = CefBrowserHost::CreateBrowserSync(window, new Client(self), C(_url), settings,
                                                 nullptr, _context->_context);
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
        _closing = YES;
        _browser->GetHost()->CloseBrowser(false);
    }
}
- (void)discard {
    _discarding = YES;
    [self close];
}
- (void)didClose {
    _browser = nullptr;
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
    _browser->GetHost()->ExecuteDevToolsMethod(0, "Page.setWebLifecycleState", params);
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
        _browser->GetHost()->ShowDevTools(info, new Client(nil), settings, CefPoint());
    }
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
    _browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", p);
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
    static int sequence = 20000;
    CefRefPtr<Evaluation> observer = new Evaluation(completion);
    observer->message_id = ++sequence;
    observer->registration = _browser->GetHost()->AddDevToolsMessageObserver(observer);
    auto params = CefDictionaryValue::Create();
    params->SetString("expression", C(expression));
    params->SetBool("returnByValue", true);
    params->SetBool("awaitPromise", true);
    params->SetBool("userGesture", true);
    _browser->GetHost()->ExecuteDevToolsMethod(observer->message_id, "Runtime.evaluate", params);
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
    self.window.title =
        [NSString stringWithFormat:@"Lite — %@", [NSURL URLWithString:page.url].host ?: @"Popup"];
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

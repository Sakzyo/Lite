#include "include/cef_app.h"
#include "include/cef_process_message.h"
#include "include/cef_sandbox_mac.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_library_loader.h"
#include "LTLoginCapture.h"
#include <set>

// This unprivileged renderer callback only raises conservative lifecycle guards.
// It cannot navigate, read native files, grant permissions, or mutate Lite data.
class Lifecycle : public CefV8Handler {
  public:
    bool Execute(const CefString &, CefRefPtr<CefV8Value>, const CefV8ValueList &args,
                 CefRefPtr<CefV8Value> &, CefString &) override {
        if (args.size() != 2 || !args[0]->IsInt() || !args[1]->IsBool())
            return true;
        auto m = CefProcessMessage::Create("LiteLifecycle");
        m->GetArgumentList()->SetInt(0, args[0]->GetIntValue());
        m->GetArgumentList()->SetBool(1, args[1]->GetBoolValue());
        CefV8Context::GetCurrentContext()->GetFrame()->SendProcessMessage(PID_BROWSER, m);
        return true;
    }

  private:
    IMPLEMENT_REFCOUNTING(Lifecycle);
};
class LoginSubmission : public CefV8Handler {
  public:
    bool Execute(const CefString &, CefRefPtr<CefV8Value>, const CefV8ValueList &args,
                 CefRefPtr<CefV8Value> &, CefString &) override {
        auto frame = CefV8Context::GetCurrentContext()->GetFrame();
        if (!frame->IsMain() || args.size() != 4) return true;
        for (const auto &arg : args) if (!arg->IsString()) return true;
        if (args[0]->GetStringValue().length() > 2048 || args[1]->GetStringValue().length() > 1024 ||
            args[2]->GetStringValue().length() > 16384 || args[3]->GetStringValue().length() > 2048) return true;
        auto message = CefProcessMessage::Create("LiteLoginSubmitted");
        for (size_t i = 0; i < args.size(); i++) message->GetArgumentList()->SetString(i, args[i]->GetStringValue());
        frame->SendProcessMessage(PID_BROWSER, message);
        return true;
    }
  private:
    IMPLEMENT_REFCOUNTING(LoginSubmission);
};
class RenderApp : public CefApp, public CefRenderProcessHandler {
  public:
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
        return this;
    }
    void OnBrowserCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDictionaryValue> extra) override {
        if (extra && extra->GetBool("liteSaveLogins")) loginBrowsers_.insert(browser->GetIdentifier());
    }
    void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
        loginBrowsers_.erase(browser->GetIdentifier());
    }
    void OnContextReleased(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefV8Context>) override {
        for (int flag : {2, 3}) {
            auto message = CefProcessMessage::Create("LiteLifecycle");
            message->GetArgumentList()->SetInt(0, flag);
            message->GetArgumentList()->SetBool(1, false);
            frame->SendProcessMessage(PID_BROWSER, message);
        }
    }
    void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefV8Context> context) override {
        if (frame->IsMain() && loginBrowsers_.count(browser->GetIdentifier())) {
            context->GetGlobal()->SetValue("__liteLoginSubmitted",
                CefV8Value::CreateFunction("__liteLoginSubmitted", new LoginSubmission), V8_PROPERTY_ATTRIBUTE_NONE);
            frame->ExecuteJavaScript(std::string("(") + LTLoginCaptureScript +
                ")(window.__liteLoginSubmitted);delete window.__liteLoginSubmitted;", frame->GetURL(), 0);
        }
        frame->SendProcessMessage(PID_BROWSER, CefProcessMessage::Create("LiteCosmeticReady"));
        context->GetGlobal()->SetValue(
            "__liteLifecycle", CefV8Value::CreateFunction("__liteLifecycle", new Lifecycle),
            static_cast<cef_v8_propertyattribute_t>(V8_PROPERTY_ATTRIBUTE_READONLY |
                                                    V8_PROPERTY_ATTRIBUTE_DONTENUM |
                                                    V8_PROPERTY_ATTRIBUTE_DONTDELETE));
        frame->ExecuteJavaScript(R"JS((()=>{const send=window.__liteLifecycle;
      for(const event of ['input','change','pointerdown','keydown'])
        addEventListener(event,()=>send(1,true),{capture:true,once:true});
      const audioContexts=new Set();
      const media=()=>{let playing=false;for(const reference of audioContexts){const context=reference.deref();
        if(!context||context.state==='closed')audioContexts.delete(reference);else playing ||= context.state==='running';}
        send(2,playing||[...document.querySelectorAll('audio,video')].some(v=>!v.paused&&!v.ended));};
      for(const name of ['AudioContext','webkitAudioContext']){const Native=window[name];if(!Native)continue;
        window[name]=new Proxy(Native,{construct(target,args,newTarget){const context=Reflect.construct(target,args,newTarget);
          audioContexts.add(new WeakRef(context));context.addEventListener('statechange',media);media();return context}});}
      for(const e of ['play','pause','ended'])addEventListener(e,media,true);
      addEventListener('enterpictureinpicture',()=>send(3,true),true);
      addEventListener('leavepictureinpicture',()=>send(3,false),true);
    })())JS",
                                 frame->GetURL(), 0);
    }

  private:
    std::set<int> loginBrowsers_;
    IMPLEMENT_REFCOUNTING(RenderApp);
};
int main(int argc, char **argv) {
    CefScopedSandboxContext sandbox;
    if (!sandbox.Initialize(argc, argv))
        return 1;
    CefScopedLibraryLoader library;
    if (!library.LoadInHelper())
        return 1;
    return CefExecuteProcess(CefMainArgs(argc, argv), new RenderApp, nullptr);
}

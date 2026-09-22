#include "include/cef_app.h"
#include "include/cef_process_message.h"
#include "include/cef_sandbox_mac.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_library_loader.h"

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
class RenderApp : public CefApp, public CefRenderProcessHandler {
  public:
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
        return this;
    }
    void OnContextCreated(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefV8Context> context) override {
        context->GetGlobal()->SetValue(
            "__liteLifecycle", CefV8Value::CreateFunction("__liteLifecycle", new Lifecycle),
            static_cast<cef_v8_propertyattribute_t>(V8_PROPERTY_ATTRIBUTE_READONLY |
                                                    V8_PROPERTY_ATTRIBUTE_DONTENUM |
                                                    V8_PROPERTY_ATTRIBUTE_DONTDELETE));
        frame->ExecuteJavaScript(R"JS((()=>{const send=window.__liteLifecycle;
      addEventListener('input',()=>send(1,true),{capture:true,once:true});
      const media=()=>send(2,[...document.querySelectorAll('audio,video')].some(v=>!v.paused&&!v.ended));
      for(const e of ['play','pause','ended'])addEventListener(e,media,true);
      addEventListener('enterpictureinpicture',()=>send(3,true),true);
      addEventListener('leavepictureinpicture',()=>send(3,false),true);
    })())JS",
                                 frame->GetURL(), 0);
    }

  private:
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

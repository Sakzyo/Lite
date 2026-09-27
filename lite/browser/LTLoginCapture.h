#pragma once
// Installed only in a regular window's main frame. The native callback is kept
// in this closure, not exposed as a page-accessible password-store API.
static const char *LTLoginCaptureScript = R"JS((send)=>{
  const visible=e=>e.getClientRects().length&&!e.disabled&&!e.readOnly;
  let last=0;
  addEventListener('submit',event=>{
    if(!event.isTrusted||!navigator.userActivation.isActive||Date.now()-last<2000)return;
    const form=event.target;
    if(!(form instanceof HTMLFormElement))return;
    const origin=location.origin;
    const local=['localhost','127.0.0.1','[::1]'].includes(location.hostname);
    if(location.protocol!=='https:'&&!(local&&location.protocol==='http:'))return;
    const action=new URL(event.submitter?.hasAttribute('formaction')?event.submitter.formAction:(form.action||location.href),location.href);
    if(action.origin!==origin||action.username||action.password)return;
    const passwords=[...form.querySelectorAll('input[type=password]')].filter(visible);
    if(passwords.length!==1||passwords[0].autocomplete==='new-password')return;
    const p=passwords[0];
    const inputs=[...form.querySelectorAll('input')].filter(e=>visible(e)&&['text','email'].includes(e.type));
    const u=inputs.find(e=>e.autocomplete==='username')||inputs.find(e=>e.type==='email')||inputs[0];
    const username=u?.value||'',password=p.value;
    if(!password.length||password.length>16384||username.length>1024)return;
    last=Date.now();
    send(origin,username,password,action.origin);
  },true);
})JS";

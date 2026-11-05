#pragma once
// Runs in each frame's main world before any page script. The native callback
// stays in this closure, so no global exists for a page to call or detect. Every
// builtin is captured here and nothing page-defined is called: a page that patches
// prototypes must not be able to reach the callback or fake a protection signal.
// Strict mode hides these functions from stack-trace inspection.
static const char *LTLifecycleObserverScript = R"JS((send)=>{'use strict';
  const {apply,construct}=Reflect,getter=(type,name)=>Object.getOwnPropertyDescriptor(type.prototype,name).get;
  const listen=EventTarget.prototype.addEventListener,select=Document.prototype.querySelectorAll;
  const listLength=getter(NodeList,'length'),paused=getter(HTMLMediaElement,'paused'),ended=getter(HTMLMediaElement,'ended');
  const contextState=getter(BaseAudioContext,'state'),deref=WeakRef.prototype.deref,Reference=WeakRef;
  const pageNavigator=navigator,activation=getter(Navigator,'userActivation'),hasBeenActive=getter(UserActivation,'hasBeenActive');
  const inputType=getter(InputEvent,'inputType');
  const on=(target,type,listener)=>apply(listen,target,[type,listener,true]);
  // element.click() raises trusted input and change events, so those also need a
  // real user gesture. Paste and drop may arrive without one, and script cannot fake them.
  const pasted=event=>{try{const kind=apply(inputType,event,[]);return kind==='insertFromPaste'||kind==='insertFromDrop'}catch{return false}};
  const edited=event=>apply(hasBeenActive,apply(activation,pageNavigator,[]),[])||pasted(event);
  const watch=(type,genuine)=>{let reported=false;on(window,type,event=>{
    if(reported||!event.isTrusted||!genuine(event))return;reported=true;send(1,true)})};
  watch('pointerdown',()=>true);watch('keydown',()=>true);watch('input',edited);watch('change',edited);
  const contexts={__proto__:null};let contextCount=0;
  // A failed check counts as not playing, so it cannot leave a stale protection flag.
  const playing=element=>{try{return !apply(paused,element,[])&&!apply(ended,element,[])}catch{return false}};
  const media=()=>{let active=false,kept=0;
    for(let i=0;i<contextCount;i++){const reference=contexts[i],context=apply(deref,reference,[]);
      const state=context?apply(contextState,context,[]):'closed';
      if(state!=='closed'){contexts[kept++]=reference;active||=state==='running'}}
    contextCount=kept;
    const elements=apply(select,document,['audio,video']),length=apply(listLength,elements,[]);
    for(let i=0;i<length&&!active;i++)active=playing(elements[i]);
    send(2,active)};
  for(const name of ['AudioContext','webkitAudioContext']){const Native=window[name];if(!Native)continue;
    window[name]=new Proxy(Native,{__proto__:null,construct(target,args,newTarget){const context=construct(target,args,newTarget);
      contexts[contextCount++]=new Reference(context);apply(listen,context,['statechange',media]);media();return context}});}
  for(const type of ['play','pause','ended'])on(window,type,media);
  const picture=active=>event=>{if(event.isTrusted)send(3,active)};
  on(window,'enterpictureinpicture',picture(true));on(window,'leavepictureinpicture',picture(false));
})JS";

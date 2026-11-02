document.documentElement.dataset.liteExtension = 'content';
chrome.runtime.sendMessage({ping: true}, reply => {
  document.documentElement.dataset.liteExtension = reply && reply.pong === 'lite' && reply.tab > 0 ? 'worker' : 'no-reply';
});

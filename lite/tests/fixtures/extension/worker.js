chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (!message.ping) return;
  chrome.storage.local.set({pinged: true}).then(() => reply({pong: 'lite', tab: sender.tab ? sender.tab.id : -1}));
  return true;
});

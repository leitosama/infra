// Applies a PAC the same way rNeomy/proxy-switcher (v3, data/panel/proxy.js, proxy.pac(),
// "Inline" mode) does, and records chrome.proxy.onProxyError.
const errors = [];
chrome.proxy.onProxyError.addListener(e => errors.push(e));
self.applyPac = async data => {
  errors.length = 0;
  await chrome.proxy.settings.set({value: {mode: 'pac_script', pacScript: {mandatory: true, data}}});
  return (await chrome.proxy.settings.get({})).value.mode;
};
self.getErrors = () => errors;

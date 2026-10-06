# pac-chrome-test

Loads a PAC file into real Chromium the same way the
[Proxy Switcher](https://github.com/rNeomy/proxy-switcher) extension (v3) does in "Inline" mode:
`chrome.proxy.settings.set({value: {mode: 'pac_script', pacScript: {mandatory: true, data}}})`,
then reads `chrome.proxy.onProxyError`. Exits non-zero on `ERR_PAC_SCRIPT_FAILED`.

Needs `playwright` and Chromium (`PLAYWRIGHT_BROWSERS_PATH`).

```
node pac-chrome-test/run.js proxy.pac            # as is
node pac-chrome-test/run.js proxy.pac --oneline  # newlines collapsed, as inline configs do
node pac-chrome-test/run.js proxy.pac http://1.2.3.4/ http://example.com/   # custom urls
```

Default urls are IP literals so nothing depends on DNS: one outside the lists (goes to the
proxy, `ERR_PROXY_CONNECTION_FAILED` is expected when nothing listens) and one private.

`sw.js` mirrors `v3/data/panel/proxy.js` (`proxy.pac()`) from Proxy Switcher.

#!/usr/bin/env node
// Load a PAC into real Chromium through the Proxy Switcher "inline" code path.
//   node pac-chrome-test/run.js proxy.pac [--oneline] [url ...]
// Needs playwright + Chromium (PLAYWRIGHT_BROWSERS_PATH). Exit code 1 on PAC errors.
// Default urls are IP literals: one outside the lists (should hit the proxy) and one private.
const path = require('path');
const fs = require('fs');
let pw;
try { pw = require('playwright'); } catch (e) { pw = require(path.join(process.execPath, '../../lib/node_modules/playwright')); }

const args = process.argv.slice(2);
const oneline = args.includes('--oneline');
const [file, ...rest] = args.filter(a => !a.startsWith('--'));
const urls = rest.length ? rest : ['http://1.2.3.4:8765/', 'http://10.255.255.1:8765/'];

(async () => {
  let data = fs.readFileSync(file, 'utf8');
  if (oneline) data = data.replace(/\r?\n/g, ' ');
  const ext = __dirname;
  const profile = fs.mkdtempSync(path.join(require('os').tmpdir(), 'pac-chrome-'));
  const ctx = await pw.chromium.launchPersistentContext(profile, {
    headless: false,
    args: ['--headless=new', '--no-sandbox', `--disable-extensions-except=${ext}`, `--load-extension=${ext}`]
  });
  let [sw] = ctx.serviceWorkers();
  if (!sw) sw = await ctx.waitForEvent('serviceworker');
  console.log('mode:', await sw.evaluate(d => self.applyPac(d), data));
  const page = await ctx.newPage();
  for (const u of urls) {
    const r = await page.goto(u, {timeout: 8000}).then(r => 'HTTP ' + r.status(), e => e.message.split('\n')[0]);
    console.log(u, '->', r);
  }
  const errors = await sw.evaluate(() => self.getErrors());
  const pacErrors = errors.filter(e => /PAC_SCRIPT|MANDATORY/.test(e.error));
  console.log('proxy errors:', JSON.stringify(errors));
  await ctx.close();
  fs.rmSync(profile, {recursive: true, force: true});
  if (pacErrors.length) { console.error('FAIL: PAC script failed in Chromium'); process.exit(1); }
  console.log('OK: PAC loaded and evaluated');
})().catch(e => { console.error('FAIL', e.message); process.exit(1); });

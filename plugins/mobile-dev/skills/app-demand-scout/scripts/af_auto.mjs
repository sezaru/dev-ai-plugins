#!/usr/bin/env node
//
// af_auto.mjs — "kinda automatic" AppFigures keyword-demand via a logged-in browser session.
//
// Automates the manual Flow B end-to-end against AppFigures' internal API, reusing your
// already-authenticated dashboard session over the Chrome DevTools Protocol — no API credits,
// no PAT. It resolves a competitor app, tracks your seed keywords against it, polls until the
// data populates, reads real Popularity + Competitiveness, then cleans up (untracks keywords +
// removes the competitor) so your keyword slots are freed.
//
// Reverse-engineered internal calls (from dashboard HARs):
//   resolve : POST /api/appbase/products            (find product_id by store id)
//   add     : PUT  /api/account/competitors/{id}    {"product_id":id,"tier":"high_tier"}
//   track   : POST /api/keywords                    {"keyword":k,"relationships":[{product_id,country}]}
//   read    : GET  /api/aso?group_by=keyword&products=id&countries=xx...
//   untrack : DELETE /api/keywords/{id}             (headers: X-Requested-With, X-ST)
//   remove  : DELETE /api/account/competitors/{id}
// The X-ST session token is read from the page's storage at runtime.
//
// PREREQ: a Chromium running with --remote-debugging-port=9222, logged into appfigures.com
// on a plan that shows Keyword Popularity (Monitor+ / trial). Launch e.g.:
//   chromium --remote-debugging-port=9222 --user-data-dir=/tmp/af-cdp-profile https://appfigures.com
//
// USAGE:
//   NODE_PATH=/path/to/node_modules node af_auto.mjs \
//     --store-id 573916946 --country us \
//     --keywords "pill reminder,medication reminder simple,caregiver medication" \
//     [--product-id 214104401] [--seeds seeds.txt] [--keep] [--cdp http://127.0.0.1:9222] \
//     [--out results.csv]
//
// --product-id skips resolution (pass AppFigures' internal id, e.g. from a report URL).
// --keep leaves the competitor + keywords tracked (no cleanup).

import { chromium } from 'playwright-core';
import { readFileSync, writeFileSync } from 'node:fs';

// -- args --
const argv = process.argv.slice(2);
const opt = (name, def = null) => { const i = argv.indexOf('--' + name); return i >= 0 ? argv[i + 1] : def; };
const flag = (name) => argv.includes('--' + name);

const cdp = opt('cdp', 'http://127.0.0.1:9222');
const country = (opt('country', 'us')).toLowerCase();
const storeId = opt('store-id');
const productIdArg = opt('product-id') ? Number(opt('product-id')) : null;
const keep = flag('keep');
const out = opt('out');
let keywords = (opt('keywords') || '').split(',').map(s => s.trim()).filter(Boolean);
if (opt('seeds')) {
  keywords = readFileSync(opt('seeds'), 'utf8').split('\n').map(s => s.trim())
    .filter(s => s && !s.startsWith('#'));
}
if (!keywords.length) { console.error('No keywords. Pass --keywords "a,b,c" or --seeds file.'); process.exit(1); }
if (!storeId && !productIdArg) { console.error('Pass --store-id <appStoreId> or --product-id <appfiguresId>.'); process.exit(1); }

// -- the whole flow runs in the page (same-origin fetch = session cookies + X-ST) --
async function run() {
  const browser = await chromium.connectOverCDP(cdp);
  const ctx = browser.contexts()[0];
  const page = ctx.pages().find(p => p.url().includes('appfigures.com')) || ctx.pages().at(-1);
  if (!page) { console.error('No appfigures.com tab open in the debugged chromium.'); process.exit(1); }

  // grab X-ST token from storage
  const tok = await page.evaluate(() => {
    const test = v => (typeof v === 'string' && /^st_[a-z0-9]+/i.test(v)) ? v : null;
    for (const store of [localStorage, sessionStorage])
      for (let i = 0; i < store.length; i++) {
        const v = store.getItem(store.key(i));
        if (test(v)) return v;
        try { const o = JSON.parse(v); for (const k in o) if (test(o[k])) return o[k]; } catch {}
      }
    for (const m of document.querySelectorAll('meta')) if (test(m.getAttribute('content'))) return m.getAttribute('content');
    for (const k of Object.keys(window)) { try { if (test(window[k])) return window[k]; } catch {} }
    return null;
  });
  if (!tok) { console.error('Could not find X-ST token — is the session logged in?'); process.exit(1); }
  console.error('session token ok');

  const result = await page.evaluate(async ({ storeId, productIdArg, country, keywords, keep, tok }) => {
    const H = { accept: 'application/json', 'x-requested-with': 'XMLHttpRequest', 'x-st': tok };
    const call = async (method, path, body, ct) => {
      const headers = { ...H }; if (ct) headers['content-type'] = ct;
      const r = await fetch(path, { method, headers, body });
      let data = null; try { data = await r.json(); } catch {}
      return { status: r.status, data };
    };
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const log = [];

    // 1) resolve store id -> appfigures product_id
    let productId = productIdArg;
    if (!productId) {
      const q = JSON.stringify(['and', null, ['and', ['or',
        ['match', 'sku', String(storeId)],
        ['match', 'stores_id', String(storeId)],
        ['match', 'stores_id', Number(storeId)],
        ['match', 'product_id', Number(storeId)]
      ], ['match', 'active', ['or', true, false]]]]);
      const res = await call('POST',
        '/api/appbase/products?fields=product_id%2Cname%2Cstorefronts&count=25&page=1',
        'q=' + encodeURIComponent(q), 'application/x-www-form-urlencoded');
      const first = (res.data && res.data.results || [])[0];
      if (!first) return { log: [...log, 'RESOLVE FAILED for store id ' + storeId + ' — pass --product-id'], error: true };
      productId = first.product_id;
      log.push(`resolved ${storeId} -> product_id ${productId} (${first.name || ''})`);
    }

    // 2) add competitor
    const add = await call('PUT', '/api/account/competitors/' + productId,
      JSON.stringify({ product_id: productId, tier: 'high_tier' }), 'application/json');
    log.push('add competitor ' + productId + ' -> ' + add.status);

    // 3) track keywords
    let tracked = 0;
    for (const kw of keywords) {
      const t = await call('POST', '/api/keywords',
        JSON.stringify({ keyword: kw, relationships: [{ product_id: productId, country: country.toUpperCase() }] }),
        'application/json');
      if (t.status >= 200 && t.status < 300) tracked++;
    }
    log.push(`tracked ${tracked}/${keywords.length} keywords`);

    // 4) poll /api/aso until competitiveness populates (that = computed; popularity may be a real floor)
    const asoUrl = `/api/aso?group_by=keyword&products=${productId}&countries=${country}` +
      `&device=handheld&granularity=hourly&normalize=true&time_zone=utc&page=1`;
    const wanted = new Set(keywords.map(k => k.toLowerCase()));
    let rows = [];
    // Poll on POPULARITY (the demand signal) — it populates fast, whereas competitiveness
    // stays null forever for keywords the app doesn't rank for. Grace polls let comp catch up.
    let grace = 0;
    for (let i = 0; i < 14; i++) {
      const r = await call('GET', asoUrl);
      rows = (r.data && r.data.results || [])
        .filter(x => wanted.has(decodeURIComponent(x.keyword_term || '').toLowerCase()));
      const noPop = rows.filter(x => x.popularity == null).length;
      const noComp = rows.filter(x => x.competitiveness == null).length;
      log.push(`poll ${i + 1}: ${rows.length}/${keywords.length} present, ${noPop} no-popularity, ${noComp} no-competitiveness`);
      if (rows.length >= keywords.length && noPop === 0) {
        if (noComp === 0 || grace >= 2) break; // popularity in; give comp up to 2 grace polls
        grace++;
      }
      await sleep(15000);
    }
    const data = rows.map(x => ({
      keyword: decodeURIComponent(x.keyword_term || ''),
      popularity: x.popularity, competitiveness: x.competitiveness,
      position: x.position, num_apps: x.num_apps
    })).sort((a, b) => (b.popularity || 0) - (a.popularity || 0));

    // 5) cleanup (unless --keep)
    if (!keep) {
      const kwList = await call('GET', '/api/keywords');
      const mine = (kwList.data || []).filter(k => (k.relationships || []).some(r => r.product_id === productId));
      let del = 0;
      for (const k of mine) { const d = await call('DELETE', '/api/keywords/' + k.id); if (d.status >= 200 && d.status < 300) del++; }
      const dc = await call('DELETE', '/api/account/competitors/' + productId);
      log.push(`cleanup: removed ${del} keywords, competitor -> ${dc.status}`);
    } else {
      log.push('kept tracked (--keep)');
    }

    return { log, data, productId };
  }, { storeId, productIdArg, country, keywords, keep, tok });

  await browser.close();

  console.error('\n' + result.log.join('\n'));
  if (result.error) process.exit(1);

  console.log(`\n=== ${country.toUpperCase()} demand (product ${result.productId}) ===`);
  console.log('pop  comp  apps  keyword');
  for (const r of result.data)
    console.log(`${String(r.popularity ?? '-').padStart(3)}  ${String(r.competitiveness ?? '-').padStart(4)}  ${String(r.num_apps ?? '-').padStart(4)}  ${r.keyword}`);

  if (out) {
    const csv = 'keyword,popularity,competitiveness,num_apps,position\n' +
      result.data.map(r => [JSON.stringify(r.keyword), r.popularity, r.competitiveness, r.num_apps, r.position].join(',')).join('\n');
    writeFileSync(out, csv + '\n');
    console.error('CSV -> ' + out);
  }
}

run().catch(e => { console.error('FATAL', e.message); process.exit(1); });

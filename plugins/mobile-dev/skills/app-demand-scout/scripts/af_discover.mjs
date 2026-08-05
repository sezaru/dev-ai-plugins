#!/usr/bin/env node
//
// af_discover.mjs — DISCOVER new markets (not validate an idea you already have).
//
// Inverts the skill: instead of "given app/keyword X, is there demand?", it asks
// "given a SPACE, what real demand is out there with beatable incumbents?" — and lets
// the data nominate the markets. It drives your logged-in AppFigures dashboard session
// over the Chrome DevTools Protocol (no API credits, no PAT, no keyword tracking):
//
//   1. seed keyword(s) -> /api/unified-apps/search  -> the real incumbent apps + download/revenue estimates
//   2. each incumbent  -> /api/aso/products-snapshot/keywords?sort=-popularity (paginated)
//                         -> EVERY keyword it ranks for, pre-scored with popularity + competitiveness
//   3. aggregate across apps (cross-app frequency = relevance), filter junk, score
//                         gap = high popularity (real demand) x low competitiveness (weak defense)
//   4. (optional --enrich) re-search the top terms -> leaders' download/revenue estimates
//                         -> "big demand, but BEATABLE incumbents?"
//   5. emit ranked candidate-keyword CSV + a clustering prompt; the SKILL (LLM) clusters
//      survivors into candidate markets, applies the 2026 kill-filters, and picks which to
//      review-mine for the actual wedge.
//
// These are DEMAND TERMS, not the wedge — and "app ranks for keyword" != "that is its market"
// (Medisafe ranks for "alarm"). Cross-app frequency + competitiveness + the estimate check are
// what separate signal from noise; review_miner.exs still supplies the product insight.
//
// Confirmed internal endpoints (credit-free, no tracking; reverse-engineered from the dashboard):
//   search   : GET  /api/unified-apps/search?expand=unified-app-intelligence-metadata-minimal,estimates&q=<term>&count=20&page=1
//              -> results[].{id, downloads_estimate.value, revenue_estimate.value,
//                            unified_app_intelligence_metadata_minimal.{name, member_product_ids[]}}
//   keywords : GET  /api/aso/products-snapshot/keywords?countries=US&products=<pid>&sort=-popularity&count=25&page=N&device=handheld&group_by=keyword,product
//              -> results[].{keyword_term, popularity, competitiveness, num_apps_in_keyword}
//   resolve  : POST /api/appbase/products  (store id -> product_id)
// The X-ST session token is read from the page at runtime.
//
// PREREQ: Chromium with --remote-debugging-port=9222, logged into appfigures.com on a plan
// that shows Keyword Popularity (Monitor+ / trial). See af_auto.mjs header for the launch line.
//
// USAGE (give it at least ONE seed source):
//   node af_discover.mjs --seed-keywords "medication reminder,pill tracker" --country us \
//     --top-apps 8 --pages 4 --enrich 20 --out candidates.csv --llm-prompt discover.md
//   node af_discover.mjs --seed-apps 573916946,631377773 --pages 6 --out candidates.csv
//   node af_discover.mjs --product-ids 214104401 --pages 8

import { chromium } from 'playwright-core';
import { readFileSync, writeFileSync } from 'node:fs';

const argv = process.argv.slice(2);
const opt = (name, def = null) => { const i = argv.indexOf('--' + name); return i >= 0 ? argv[i + 1] : def; };
const flag = (name) => argv.includes('--' + name);
const list = (s) => (s || '').split(',').map(x => x.trim()).filter(Boolean);

const cdp = opt('cdp', 'http://127.0.0.1:9222');
const country = opt('country', 'us').toLowerCase();
let seedKeywords = list(opt('seed-keywords'));
const seedStoreIds = list(opt('seed-apps'));
const productIds = list(opt('product-ids')).map(Number);
// Discovery ledger: product_ids already mined in a past run (BP incumbents, etc.). Excluded
// before keyword-fetching so a later run doesn't re-surface an already-covered market. Accepts
// a comma list and/or --exclude-file (one product_id per line).
let excludeApps = list(opt('exclude-apps')).map(Number);
if (opt('exclude-file')) excludeApps = excludeApps.concat(
  readFileSync(opt('exclude-file'), 'utf8').split('\n').map(s => s.trim()).filter(s => s && !s.startsWith('#')).map(Number));
excludeApps = [...new Set(excludeApps.filter(Boolean))];
if (opt('seeds')) seedKeywords = seedKeywords.concat(
  readFileSync(opt('seeds'), 'utf8').split('\n').map(s => s.trim()).filter(s => s && !s.startsWith('#')));
const topApps = Number(opt('top-apps', '8'));
const pages = Number(opt('pages', '4'));
// position = the source app's organic rank for the term. Low rank = the app genuinely
// COMPETES on the term (its real market); high rank = it merely appears in Apple's index
// against a giant brand term (noise: "starbucks", "fortnite"). This is the key noise filter.
const maxPosition = Number(opt('max-position', '30'));
const minLen = Number(opt('min-len', '3'));
const minWords = Number(opt('min-words', '1'));
const allowNonLatin = flag('allow-nonlatin');
const enrichN = Number(opt('enrich', '20'));
const out = opt('out');
const llmPrompt = opt('llm-prompt');

if (!seedKeywords.length && !seedStoreIds.length && !productIds.length) {
  console.error('Give at least one seed source: --seed-keywords "a,b" / --seed-apps id,id / --product-ids pid,pid');
  process.exit(1);
}

function getToken(page) {
  return page.evaluate(() => {
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
}

async function run() {
  const browser = await chromium.connectOverCDP(cdp);
  const ctx = browser.contexts()[0];
  const page = ctx.pages().find(p => p.url().includes('appfigures.com')) || ctx.pages().at(-1);
  if (!page) { console.error('No appfigures.com tab open in the debugged chromium.'); process.exit(1); }
  // The X-ST token (window.afReqToken) is only set on main-app pages (/reports/*, /account/*),
  // not the /_start/ app-profile mini-app. Land on a stable one before reading it.
  let tok = await getToken(page);
  if (!tok) {
    await page.goto('https://appfigures.com/reports/competitors', { waitUntil: 'networkidle', timeout: 25000 }).catch(() => {});
    await page.waitForTimeout(2500);
    tok = await getToken(page);
  }
  if (!tok) { console.error('Could not find X-ST token — is the session logged in on appfigures.com?'); process.exit(1); }
  console.error('session token ok');

  // ---- gather: apps + their ranked keywords (all in-page, same-origin session) ----
  const gathered = await page.evaluate(async (args) => {
    const { seedKeywords, seedStoreIds, productIds, country, topApps, pages, tok, excludeApps } = args;
    const excludeSet = new Set(excludeApps);
    const H = { accept: 'application/json', 'x-requested-with': 'XMLHttpRequest', 'x-st': tok };
    const jget = async (path) => { const r = await fetch(path, { headers: H }); let d = null; try { d = await r.json(); } catch {} return { status: r.status, d }; };
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const log = [];

    // app map: product_id -> { name, downloads, revenue }
    const apps = new Map();
    const addApp = (pid, name, dl, rev) => {
      if (!pid || excludeSet.has(pid)) return; // ledger: skip already-mined incumbents
      const cur = apps.get(pid) || { product_id: pid, name: name || null, downloads: dl ?? null, revenue: rev ?? null };
      if (name && !cur.name) cur.name = name;
      if (dl != null && cur.downloads == null) cur.downloads = dl;
      if (rev != null && cur.revenue == null) cur.revenue = rev;
      apps.set(pid, cur);
    };

    // 1) seed keywords -> incumbent apps (by download estimate)
    for (const kw of seedKeywords) {
      const url = '/api/unified-apps/search?expand=unified-app-intelligence-metadata-minimal%2Cestimates' +
        '&precision=4&q=' + encodeURIComponent(kw) + '&count=20&page=1';
      const { status, d } = await jget(url);
      const results = (d && d.results) || [];
      log.push(`search "${kw}" -> ${status}, ${results.length} apps`);
      results
        .map(r => ({
          dl: r.downloads_estimate && r.downloads_estimate.value,
          rev: r.revenue_estimate && r.revenue_estimate.value,
          meta: r.unified_app_intelligence_metadata_minimal || {}
        }))
        .sort((a, b) => (b.dl || 0) - (a.dl || 0))
        .slice(0, topApps)
        .forEach(r => (r.meta.member_product_ids || []).forEach(pid => addApp(pid, r.meta.name, r.dl, r.rev)));
    }

    // 2) seed store ids -> product_id
    for (const sid of seedStoreIds) {
      const q = JSON.stringify(['and', null, ['and', ['or',
        ['match', 'stores_id', String(sid)], ['match', 'stores_id', Number(sid)]],
        ['match', 'active', ['or', true, false]]]]);
      const r = await fetch('/api/appbase/products?fields=product_id%2Cname&count=5&page=1',
        { method: 'POST', headers: { ...H, 'content-type': 'application/x-www-form-urlencoded' }, body: 'q=' + encodeURIComponent(q) });
      const d = await r.json().catch(() => null);
      const first = (d && d.results || [])[0];
      if (first) { addApp(first.product_id, first.name); log.push(`resolve app ${sid} -> ${first.product_id}`); }
      else log.push(`resolve app ${sid} -> NOT FOUND`);
    }

    // 3) explicit product ids
    for (const pid of productIds) addApp(pid, null);

    if (!apps.size) return { log: [...log, 'no apps resolved'], apps: [], rows: [] };

    // 4) each app -> every keyword it ranks for (paginated, sorted by popularity)
    const rows = [];
    for (const app of apps.values()) {
      let got = 0;
      for (let p = 1; p <= pages; p++) {
        const url = `/api/aso/products-snapshot/keywords?countries=${country.toUpperCase()}` +
          `&products=${app.product_id}&sort=-popularity&count=25&page=${p}&device=handheld&group_by=keyword%2Cproduct`;
        const { status, d } = await jget(url);
        const rs = (d && d.results) || [];
        if (status !== 200) { log.push(`kw ${app.product_id} p${p} -> ${status}`); break; }
        for (const x of rs) {
          const pr = (x.products && x.products[app.product_id]) || {};
          rows.push({
            product_id: app.product_id,
            keyword: decodeURIComponent(x.keyword_term || ''),
            popularity: x.popularity, competitiveness: x.competitiveness,
            num_apps: x.num_apps_in_keyword,
            position: pr.position ?? null,
            importance: pr.importance != null ? Number(pr.importance) : null
          });
        }
        got += rs.length;
        if (rs.length < 25) break; // last page
      }
      log.push(`app ${app.product_id} (${app.name || '?'}) -> ${got} keyword rows`);
      await sleep(150);
    }
    return { log, apps: [...apps.values()], rows };
  }, { seedKeywords, seedStoreIds, productIds, country, topApps, pages, tok, excludeApps });
  if (excludeApps.length) console.error(`ledger: excluding ${excludeApps.length} already-mined app(s)`);

  console.error('\n' + gathered.log.join('\n'));
  if (!gathered.rows.length) { console.error('No keyword rows gathered.'); await browser.close(); process.exit(1); }

  // ---- aggregate + filter + score (node side) ----
  const latinBad = /[^ -ɏ]/; // any char outside basic/extended latin
  const byKw = new Map();
  let dropped = { pos: 0, junk: 0 };
  for (const r of gathered.rows) {
    const term = (r.keyword || '').trim();
    const low = term.toLowerCase();
    if (term.length < minLen) { dropped.junk++; continue; }
    if (term.split(/\s+/).length < minWords) { dropped.junk++; continue; }
    if (!allowNonLatin && latinBad.test(term)) { dropped.junk++; continue; }
    if (!/[a-z]/i.test(term)) { dropped.junk++; continue; } // must contain a letter
    // KEEP only terms the source app genuinely ranks for (real market), not every indexed word.
    if (r.position == null || r.position > maxPosition) { dropped.pos++; continue; }
    const cur = byKw.get(low) || { term, popMax: 0, compMin: null, numApps: 0, apps: new Set(), bestPos: null, impMax: null };
    if ((r.popularity || 0) > cur.popMax) cur.popMax = r.popularity || 0;
    if (r.competitiveness != null) cur.compMin = cur.compMin == null ? r.competitiveness : Math.min(cur.compMin, r.competitiveness);
    cur.numApps = Math.max(cur.numApps, r.num_apps || 0);
    cur.bestPos = cur.bestPos == null ? r.position : Math.min(cur.bestPos, r.position);
    if (r.importance != null) cur.impMax = Math.max(cur.impMax ?? 0, r.importance);
    cur.apps.add(r.product_id);
    byKw.set(low, cur);
  }
  console.error(`filtered: kept ${byKw.size} terms; dropped ${dropped.pos} off-market (rank > ${maxPosition}) + ${dropped.junk} junk`);
  let cands = [...byKw.values()].map(c => {
    const openness = (100 - (c.compMin == null ? 100 : c.compMin)) / 100; // 1 = wide open
    const gap = Math.round(c.popMax * (0.5 + 0.5 * openness)); // demand, discounted when walled
    return { keyword: c.term, popularity: c.popMax, competitiveness: c.compMin, num_apps: c.numApps,
      apps_ranking: c.apps.size, best_position: c.bestPos, importance: c.impMax != null ? Math.round(c.impMax) : null, gap_score: gap };
  });
  // Rank: opportunity first, then cross-app relevance (multiple incumbents rank for it), then demand
  cands.sort((a, b) => b.gap_score - a.gap_score || b.apps_ranking - a.apps_ranking || b.popularity - a.popularity);

  // ---- optional enrichment: leaders' download/revenue estimate for the top terms ----
  if (enrichN > 0) {
    const terms = cands.slice(0, enrichN).map(c => c.keyword);
    const enr = await page.evaluate(async ({ terms, tok }) => {
      const H = { accept: 'application/json', 'x-requested-with': 'XMLHttpRequest', 'x-st': tok };
      const sleep = ms => new Promise(r => setTimeout(r, ms));
      const outMap = {};
      for (const t of terms) {
        try {
          const r = await fetch('/api/unified-apps/search?expand=unified-app-intelligence-metadata-minimal%2Cestimates' +
            '&precision=4&q=' + encodeURIComponent(t) + '&count=10&page=1', { headers: H });
          const d = await r.json();
          const res = (d && d.results) || [];
          const dls = res.map(x => x.downloads_estimate && x.downloads_estimate.value).filter(v => v != null);
          const revs = res.map(x => x.revenue_estimate && x.revenue_estimate.value).filter(v => v != null);
          outMap[t] = { leader_downloads: dls.length ? Math.max(...dls) : null, leader_revenue: revs.length ? Math.max(...revs) : null, ranked_apps: res.length };
        } catch { outMap[t] = { leader_downloads: null, leader_revenue: null, ranked_apps: null }; }
        await sleep(120);
      }
      return outMap;
    }, { terms, tok });
    cands = cands.map(c => ({ ...c, ...(enr[c.keyword] || {}) }));
  }

  await browser.close();

  // ---- output ----
  console.log(`\n--- apps mined (record product_ids in the discovery ledger for --exclude-apps) ---`);
  console.log(gathered.apps.map(a => `${a.product_id} ${a.name || '?'}`).join('\n'));
  console.log(`\n=== ${country.toUpperCase()} candidate markets — ${cands.length} terms from ${gathered.apps.length} apps ===`);
  console.log('gap  pop  comp  rank  ranked  keyword' + (enrichN > 0 ? '   [leaderDL/leaderRev]' : ''));
  for (const c of cands.slice(0, 40)) {
    const est = enrichN > 0 ? `   [${c.leader_downloads ?? '-'}/${c.leader_revenue ?? '-'}]` : '';
    console.log(
      `${String(c.gap_score).padStart(3)}  ${String(c.popularity).padStart(3)}  ${String(c.competitiveness ?? '-').padStart(4)}  ` +
      `${String(c.best_position ?? '-').padStart(4)}  ${String(c.apps_ranking).padStart(6)}  ${c.keyword}${est}`);
  }

  if (out) {
    const cols = ['keyword', 'popularity', 'competitiveness', 'num_apps', 'apps_ranking', 'best_position', 'importance', 'gap_score']
      .concat(enrichN > 0 ? ['leader_downloads', 'leader_revenue', 'ranked_apps'] : []);
    const csv = cols.join(',') + '\n' +
      cands.map(c => cols.map(k => k === 'keyword' ? JSON.stringify(c[k]) : (c[k] ?? '')).join(',')).join('\n');
    writeFileSync(out, csv + '\n');
    console.error('CSV -> ' + out + ` (${cands.length} rows)`);
  }

  if (llmPrompt) {
    const top = cands.slice(0, 60);
    const table = top.map(c => `${c.keyword} | pop ${c.popularity} | comp ${c.competitiveness ?? '-'} | best-rank ${c.best_position ?? '-'} | ranked-by ${c.apps_ranking} of ${gathered.apps.length}` +
      (enrichN > 0 ? ` | leaderDL ${c.leader_downloads ?? '-'} | leaderRev ${c.leader_revenue ?? '-'}` : '')).join('\n');
    const prompt = `# Candidate-market clustering — ${country.toUpperCase()}

Source apps (incumbents mined): ${gathered.apps.map(a => `${a.name || a.product_id} (dl≈${a.downloads ?? '?'}, rev≈${a.revenue ?? '?'})`).join('; ')}

Below are keyword candidates the incumbents genuinely RANK for (organic rank ≤ ${maxPosition} —
so these are terms they compete on, not every word Apple indexes them against). Each has REAL
Apple Search Ads popularity (0–100 = demand) and competitiveness (0–100 = how walled), plus
best-rank (best organic position any source app holds), how many source apps rank for it
(cross-app relevance), and — if enriched — the leader's download/revenue estimate.

${table}

Your job (this is DISCOVERY, not validation):
1. CLUSTER these terms into 4–8 candidate MARKETS (a market = a coherent job-to-be-done,
   not a single keyword). Name each.
2. For each market, judge OPPORTUNITY = real demand (high popularity on the head term)
   AND beatable defense (competitiveness not maxed; leader downloads/revenue modest, not
   a funded giant). Flag STRONG-walled markets to avoid.
3. STRIP noise: single-letter/brand/foreign terms, and terms whose popularity is an
   artifact of a tangential giant ranking for them (an app ranking for a word ≠ that word
   being its market).
4. Apply the 2026 kill-filters (defensibility, Apple-purge/4.3 risk, willingness-to-pay
   incl. the B2B2C "free" trap, niche-narrowing).
5. Output the 2–3 MOST PROMISING candidate markets to take into review_miner.exs (mine the
   named incumbents' 1–3★ reviews) to find the actual WEDGE. For each, say WHY it survived
   and what the likely wedge is.
`;
    writeFileSync(llmPrompt, prompt);
    console.error('LLM prompt -> ' + llmPrompt);
  }
}

run().catch(e => { console.error('FATAL', e.message); process.exit(1); });

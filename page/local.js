// Handelsplan 2026 — losse versie voor Chrome. Alles draait in je browser:
// opslag in Chrome (IndexedDB), Claude en koersen rechtstreeks met jouw eigen sleutels.
// Vervangt claude.use(...) door lokale onderdelen; de pagina zelf is dezelfde als op de server.
(function () {
  "use strict";
  const DBNAME = "handelsplan-2026", STORE = "docs", NS = "hp2026:";
  const SEED = JSON.parse(document.getElementById("hp-seed").textContent);
  const TZ = "Europe/Amsterdam";
  const API = "https://api.anthropic.com/v1/messages";
  const PRICE_SYMBOLS = { gold: "XAU/USD", silver: "XAG/USD", usdjpy: "USD/JPY", crcl: "CRCL", mags: "MAGS" };
  const META = { mags: { label: "Mag 7-mand (ETF MAGS)", group: "Jouw posities", pillar: "sentiment", prefix: "$", suffix: "", decimals: 2 } };
  const MACRO_KEYS = ["us10y", "us2y", "us30y", "realYield10", "breakeven10", "curve", "fedFunds", "wti", "brent", "dxy", "vix",
    "spx", "ndx", "kospi", "kospiDay", "cpiYoY", "coreCpi", "ppiYoY", "nfp3m", "unrate", "claims", "sahm", "hySpread",
    "pcDefault", "netLiq", "cape", "marginDebt", "top10"];
  const SIGNED = new Set(["curve", "kospiDay", "spxDD", "nfp3m", "netLiqChg"]);

  // ---------------- kleine hulpjes ----------------
  const clone = (o) => JSON.parse(JSON.stringify(o));
  const kvGet = (k, d = null) => { try { const v = localStorage.getItem(NS + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } };
  const kvSet = (k, v) => { try { if (v == null) localStorage.removeItem(NS + k); else localStorage.setItem(NS + k, JSON.stringify(v)); } catch (e) {} };
  const key = (name) => kvGet("key:" + name, "");
  const nf = (v, d) => new Intl.NumberFormat("nl-NL", { minimumFractionDigits: d, maximumFractionDigits: d }).format(Math.abs(v));
  const fmt = (it, v) => (typeof v !== "number" || !isFinite(v)) ? "–" :
    (v < 0 ? "−" : (SIGNED.has(it.key) && v > 0 ? "+" : "")) + (it.prefix || "") + nf(v, it.decimals ?? 2) + (it.suffix || "");
  const stamp = () => new Intl.DateTimeFormat("nl-NL", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: TZ }).format(new Date());
  const today = () => new Intl.DateTimeFormat("nl-NL", { weekday: "long", day: "numeric", month: "long", year: "numeric", timeZone: TZ }).format(new Date());
  const nowISO = () => new Date().toISOString();
  const colOf = (path) => { const p = path.split("/").filter(Boolean); if (p.length < 2 || p.length % 2) throw { code: "invalid_argument", message: "Ongeldig pad: " + path }; return p.slice(0, -1).join("/"); };
  const merge = (a, b) => { for (const [k, v] of Object.entries(b)) { if (v && typeof v === "object" && !Array.isArray(v) && a[k] && typeof a[k] === "object" && !Array.isArray(a[k])) merge(a[k], v); else a[k] = v; } return a; };

  // ---------------- opslag: IndexedDB, anders localStorage, anders alleen geheugen ----------------
  let mode = "idb";
  const mem = new Map();
  const req = (r) => new Promise((res, rej) => { r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
  let dbp = null;
  function idb() {
    if (!dbp) dbp = new Promise((res, rej) => {
      let r; try { r = indexedDB.open(DBNAME, 1); } catch (e) { rej(e); return; }
      r.onupgradeneeded = () => r.result.createObjectStore(STORE);
      r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); r.onblocked = () => rej(new Error("blocked"));
    });
    return dbp;
  }
  const quota = (e) => (e && e.name === "QuotaExceededError") ? { code: "quota_exceeded" } : { code: "unavailable", message: String(e && e.message || e) };
  async function rawGet(path) {
    if (mode === "idb") { const d = await idb(); return req(d.transaction(STORE).objectStore(STORE).get(path)); }
    if (mode === "ls") { try { const v = localStorage.getItem(NS + "doc:" + path); return v ? JSON.parse(v) : undefined; } catch (e) { return undefined; } }
    return mem.get(path);
  }
  async function rawPut(path, rec) {
    if (mode === "idb") {
      const d = await idb(); const t = d.transaction(STORE, "readwrite"); t.objectStore(STORE).put(rec, path);
      return new Promise((res, rej) => { t.oncomplete = () => res(); t.onerror = () => rej(quota(t.error)); t.onabort = () => rej(quota(t.error)); });
    }
    if (mode === "ls") { try { localStorage.setItem(NS + "doc:" + path, JSON.stringify(rec)); return; } catch (e) { throw quota(e); } }
    mem.set(path, rec);
  }
  async function rawAll() {
    if (mode === "idb") {
      const d = await idb(); const st = d.transaction(STORE).objectStore(STORE);
      const [keys, vals] = await Promise.all([req(st.getAllKeys()), req(st.getAll())]);
      return keys.map((k, i) => [k, vals[i]]);
    }
    if (mode === "ls") {
      const out = [];
      for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k && k.startsWith(NS + "doc:")) out.push([k.slice(NS.length + 4), JSON.parse(localStorage.getItem(k))]); }
      return out;
    }
    return [...mem.entries()];
  }
  async function rawClear() {
    if (mode === "idb") { const d = await idb(); const t = d.transaction(STORE, "readwrite"); t.objectStore(STORE).clear(); return new Promise((res, rej) => { t.oncomplete = res; t.onerror = () => rej(t.error); }); }
    if (mode === "ls") { for (const [p] of await rawAll()) localStorage.removeItem(NS + "doc:" + p); return; }
    mem.clear();
  }
  const getDoc = async (path) => { const r = await rawGet(path); return r ? r.data : null; };
  async function setDoc(path, data) { await rawPut(path, { col: colOf(path), data: clone(data), updated: Date.now() }); changed(path); }

  // ---------------- meldingen aan de pagina bij wijzigingen (ook tussen tabbladen) ----------------
  const listeners = new Set();
  let bc = null; try { bc = new BroadcastChannel(DBNAME); bc.onmessage = (ev) => fire(ev.data && ev.data.path); } catch (e) {}
  function fire(path) { if (!path) return; let col = ""; try { col = colOf(path); } catch (e) {} listeners.forEach((l) => { if (l.path === path || l.col === col) l.run(); }); }
  function changed(path) { fire(path); try { bc && bc.postMessage({ path }); } catch (e) {} }

  // ---------------- het db-onderdeel (zelfde vorm als in de Claude-app en op de server) ----------------
  const snap = (id, exists, data) => ({ id, exists, data: () => data, metadata: { fromCache: false, hasPendingWrites: false } });
  const newId = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
  function docRef(path) {
    const id = path.split("/").pop();
    return {
      id, path,
      get: async () => { const d = await getDoc(path); return snap(id, d != null, d); },
      set: async (d) => setDoc(path, d),
      update: async (d) => { const cur = await getDoc(path); if (cur == null) throw { code: "invalid_argument", message: "Document bestaat niet" }; await setDoc(path, merge(cur, clone(d))); },
      delete: async () => {},
      onSnapshot(next, err) {
        const run = async () => { try { const d = await getDoc(path); next(snap(id, d != null, d)); } catch (e) { err && err(e); } };
        const l = { path, run }; listeners.add(l); run(); return () => listeners.delete(l);
      },
    };
  }
  function query(col, order, dir, lim) {
    const fetchQ = async () => {
      let docs = (await rawAll()).filter(([, r]) => r && r.col === col).map(([p, r]) => ({ id: p.split("/").pop(), data: r.data }));
      if (order) docs.sort((a, b) => { const x = a.data[order], y = b.data[order]; if (x == null) return 1; if (y == null) return -1; return String(x) < String(y) ? -1 : String(x) > String(y) ? 1 : 0; });
      else docs.sort((a, b) => a.id < b.id ? -1 : 1);
      if (order && dir === "desc") docs.reverse();
      docs = docs.slice(0, lim || 100).map((d) => snap(d.id, true, d.data));
      return { docs, size: docs.length, empty: !docs.length, docChanges: () => [], metadata: { fromCache: false, hasPendingWrites: false } };
    };
    const q = {
      where: () => q,
      orderBy: (f, d) => query(col, f, d || "asc", lim),
      limit: (n) => query(col, order, dir, n),
      get: fetchQ,
      onSnapshot(next, err) {
        const run = async () => { try { next(await fetchQ()); } catch (e) { err && err(e); } };
        const l = { col, run }; listeners.add(l); run(); return () => listeners.delete(l);
      },
      doc: (id) => docRef(col + "/" + (id || newId())),
      add: async (d) => { const r = docRef(col + "/" + newId()); await r.set(d); return r; },
      path: col,
    };
    return q;
  }
  const db = { doc: docRef, collection: (p) => query(p.replace(/^\/|\/$/g, ""), "", "asc", 100) };

  // ---------------- startgegevens en nieuwe onderdelen (zelfde regels als app/patch.py) ----------------
  function applyPatch(plan, market, P) {
    let n = 0;
    if (plan) {
      if (!plan.macro) { plan.macro = clone(P.macro); n++; }
      else if (!plan.macro.cycle && P.macro && P.macro.cycle) { plan.macro.cycle = clone(P.macro.cycle); n++; }
      plan.triggers = plan.triggers || [];
      const have = new Set(plan.triggers.map((t) => t.id));
      for (const t of P.triggersAdd || []) if (!have.has(t.id)) { plan.triggers.push(clone(t)); n++; }
      for (const t of plan.triggers) {
        const p = (P.triggerPatch || {})[t.id]; if (!p) continue;
        for (const [k, v] of Object.entries(p)) { if (k === "unit") { if (t.unit === "k" && v === "Δk") t.unit = v; } else if (!t[k]) t[k] = v; }
      }
      plan.sources = plan.sources || [];
      const urls = new Set(plan.sources.map((s) => s.url));
      for (const s of P.sourcesAdd || []) if (!urls.has(s.url)) plan.sources.push(s);
    }
    if (market) {
      market.items = market.items || [];
      const keys = new Set(market.items.map((i) => i.key));
      for (const it of P.itemsAdd || []) if (!keys.has(it.key)) { market.items.push(clone(it)); n++; }
      for (const it of market.items) { const pil = (P.itemPillars || {})[it.key]; if (pil && !it.pillar) it.pillar = pil; }
    }
    return n;
  }
  async function prepare() {
    try { await idb(); } catch (e) { try { localStorage.setItem(NS + "test", "1"); localStorage.removeItem(NS + "test"); mode = "ls"; } catch (e2) { mode = "mem"; } }
    if (await getDoc("plan/current") == null) {
      for (const [p, d] of Object.entries(SEED.docs)) if (await getDoc(p) == null) await rawPut(p, { col: colOf(p), data: d, updated: Date.now() });
    } else {
      const plan = await getDoc("plan/current"), market = await getDoc("market/latest");
      const before = JSON.stringify([plan, market]);
      applyPatch(plan, market, SEED.patch);
      if (JSON.stringify([plan, market]) !== before) { await setDoc("plan/current", plan); if (market) await setDoc("market/latest", market); }
    }
    try { if (navigator.storage && navigator.storage.persist) kvSet("persisted", await navigator.storage.persist()); } catch (e) {}
  }
  const ready = prepare();

  // ---------------- Claude, rechtstreeks met je eigen sleutel ----------------
  function addUsage(model, u) {
    if (!u) return; const all = kvGet("usage", {}); const m = all[model] || { input: 0, output: 0, searches: 0 };
    m.input += u.input_tokens || 0; m.output += u.output_tokens || 0; m.searches += (u.server_tool_use && u.server_tool_use.web_search_requests) || 0;
    all[model] = m; kvSet("usage", all);
  }
  async function claude(body, signal) {
    const k = key("anthropic"); if (!k) throw { code: "not_declared" };
    let r;
    try {
      r = await fetch(API, { method: "POST", signal, headers: { "content-type": "application/json", "x-api-key": k, "anthropic-version": "2023-06-01", "anthropic-dangerous-direct-browser-access": "true" }, body: JSON.stringify(body) });
    } catch (e) { throw { code: e && e.name === "AbortError" ? "cancelled" : "upstream_error", message: "Claude is niet bereikbaar. Controleer je internetverbinding." }; }
    if (r.status === 429 || r.status === 529) throw { code: "rate_limited" };
    let data = {}; try { data = await r.json(); } catch (e) {}
    if (r.status === 401 || r.status === 403) throw { code: "upstream_error", message: "Je Claude-sleutel wordt niet geaccepteerd. Plak hem opnieuw onder Uitleg." };
    if (r.status === 413) throw { code: "prompt_too_large" };
    if (!r.ok) throw { code: "upstream_error", message: "Claude gaf een fout: " + ((data.error && data.error.message) || r.status) };
    addUsage(body.model, data.usage);
    return data;
  }
  const textOf = (data) => (data.content || []).filter((b) => b.type === "text").map((b) => b.text).join("");
  async function sample(input, opts = {}) {
    const prompt = typeof input === "string" ? input : input.map((m) => m.content).join("\n\n");
    const model = opts.modelTier === "complex" ? (kvGet("modelComplex") || "claude-opus-5-5") : (kvGet("model") || "claude-sonnet-5-5");
    const data = await claude({ model, max_tokens: 6000, messages: [{ role: "user", content: prompt }] }, opts.signal);
    const text = textOf(data);
    opts.onText && opts.onText({ text, delta: text });
    return { text, truncated: data.stop_reason === "max_tokens", modelTierApplied: opts.modelTier || "default" };
  }
  const parseJSON = (text) => {
    const tryParse = (s) => { try { return JSON.parse(s); } catch (e) { return undefined; } };
    let v = tryParse(text.trim());
    if (v === undefined) { const m = text.match(/```(?:json)?\s*([\s\S]*?)```/); if (m) v = tryParse(m[1]); }
    if (v === undefined) { const a = text.search(/[\[{]/), b = Math.max(text.lastIndexOf("}"), text.lastIndexOf("]")); if (a >= 0 && b > a) v = tryParse(text.slice(a, b + 1)); }
    return v;
  };
  sample.json = async (input, opts) => { const { text } = await sample(input, opts); const v = parseJSON(text); if (v === undefined) throw { code: "invalid_json", text }; return v; };
  sample.limits = async () => ({ maxPromptBytes: 262144 });

  // ---------------- koersen: Twelve Data (goud, zilver, yen, CRCL, MAGS) en CoinGecko (bitcoin) ----------------
  let lastPriceCall = 0;
  async function refreshPrices() {
    await ready;
    const out = { at: nowISO(), updated: [], errors: [] };
    if (Date.now() - lastPriceCall < 65000) { out.errors.push("Even wachten: Twelve Data staat gratis 8 verzoeken per minuut toe."); return out; }
    lastPriceCall = Date.now();
    const doc = (await getDoc("market/latest")) || { items: [] };
    const items = new Map(doc.items.map((i) => [i.key, i]));
    const ensure = (k) => { if (!items.has(k)) items.set(k, Object.assign({ key: k, value: null, change: "", asOf: "", src: "" }, META[k] || { label: k, pillar: "", prefix: "", suffix: "", decimals: 2 })); return items.get(k); };
    const tdKey = key("twelvedata");
    if (tdKey) {
      try {
        const syms = Object.values(PRICE_SYMBOLS);
        const r = await fetch("https://api.twelvedata.com/quote?symbol=" + encodeURIComponent(syms.join(",")) + "&apikey=" + encodeURIComponent(tdKey));
        const j = await r.json();
        if (j.status === "error") throw new Error(j.message || "fout");
        for (const [k, s] of Object.entries(PRICE_SYMBOLS)) {
          const q = syms.length > 1 ? j[s] : j;
          const v = q ? parseFloat(q.close) : NaN;
          if (!q || q.status === "error" || !isFinite(v)) { out.errors.push(s + ": " + ((q && q.message) || "geen koers")); continue; }
          const pc = parseFloat(q.percent_change), it = ensure(k);
          Object.assign(it, { value: v, asOf: stamp(), src: "Twelve Data", display: null, change: isFinite(pc) ? "vs slot: " + (pc > 0 ? "+" : pc < 0 ? "−" : "") + nf(pc, 1) + "%" : "" });
          out.updated.push(k);
        }
      } catch (e) { out.errors.push("Twelve Data: " + (e instanceof TypeError ? "niet bereikbaar vanuit de browser of geen internet" : (e.message || e))); }
    } else out.errors.push("Geen Twelve Data-sleutel ingesteld");
    try {
      const r = await fetch("https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd&include_24hr_change=true");
      const j = await r.json(); const v = j && j.bitcoin && j.bitcoin.usd;
      if (typeof v === "number") {
        const c = j.bitcoin.usd_24h_change || 0;
        Object.assign(ensure("btc"), { value: v, asOf: stamp(), src: "CoinGecko", display: null, change: "24u: " + (c > 0 ? "+" : c < 0 ? "−" : "") + nf(c, 1) + "%" });
        out.updated.push("btc");
      }
    } catch (e) { out.errors.push("CoinGecko (bitcoin) niet bereikbaar"); }
    if (out.updated.length) {
      doc.items = [...items.values()]; doc.updatedAt = nowISO(); doc.updatedBy = "Automatisch (in je browser)";
      await setDoc("market/latest", doc);
    }
    kvSet("lastPrices", out);
    window.dispatchEvent(new Event("hp-local"));
    return out;
  }
  function autoPrices() {
    if (!key("twelvedata") || document.hidden) return;
    const last = kvGet("lastPrices"); if (!last || Date.now() - new Date(last.at).getTime() > 30 * 60000) refreshPrices();
  }
  ready.then(() => { setTimeout(autoPrices, 1500); setInterval(autoPrices, 5 * 60000); document.addEventListener("visibilitychange", autoPrices); });

  // ---------------- macrocijfers: Claude zoekt ze online op, jij kiest wat je overneemt ----------------
  async function findMacro() {
    await ready;
    const doc = (await getDoc("market/latest")) || { items: [] };
    const items = doc.items.filter((i) => MACRO_KEYS.includes(i.key));
    const unit = (i) => [i.prefix, i.suffix].filter(Boolean).join(" ").trim() || "getal";
    const prompt = `Je werkt de cijfers bij van het persoonlijke handelsplan van Floris (educatief gebruik). Vandaag is het ${today()}.
Zoek met web search de NIEUWSTE gepubliceerde waarde van de cijfers hieronder. Gebruik betrouwbare bronnen: FRED, U.S. Treasury, BLS, Federal Reserve, CNBC, Reuters, Bloomberg, MarketWatch, Yahoo Finance, Multpl, FINRA.
Regels:
- Neem een cijfer alleen op als je het in een bron hebt gezien en het nieuwer is dan de huidige datum of duidelijk anders. Laat het anders weg; liever weglaten dan gokken.
- Gebruik precies dezelfde eenheid als hieronder: procenten als getal (4.12 betekent 4,12%), 'k' = duizenden, '$ mld' = miljarden dollars, '$ bln' = biljoenen dollars, 'pp' = procentpunten.
- asOf: korte Nederlandse datum van het cijfer, bijvoorbeeld "16 okt" of "sep" voor maandcijfers. src: korte bronnaam.
Antwoord met ALLEEN dit JSON-object, zonder uitleg ervoor of erna:
{"items":[{"key":"us10y","value":4.98,"asOf":"16 okt","src":"CNBC"}],"note":"korte opmerking, optioneel"}

CIJFERS (key | omschrijving | huidige waarde | eenheid | datum huidige waarde):
${items.map((i) => `${i.key} | ${i.label} | ${i.value} | ${unit(i)} | ${i.asOf || "?"}`).join("\n")}`;
    const model = kvGet("model") || "claude-sonnet-5-5";
    let messages = [{ role: "user", content: prompt }], data, texts = [];
    for (let round = 0; round < 4; round++) {
      try {
        data = await claude({ model, max_tokens: 4000, messages, tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 10 }] });
      } catch (e) {
        if (e && /web search/i.test(e.message || "")) throw { code: "upstream_error", message: "Web search staat uit voor je Claude-account (Console → instellingen)." };
        throw e;
      }
      texts.push(textOf(data));
      if (data.stop_reason !== "pause_turn") break;
      messages = [messages[0], { role: "assistant", content: data.content }];
    }
    const res = parseJSON(texts[texts.length - 1]) || parseJSON(texts.join("\n"));
    if (!res || !Array.isArray(res.items)) throw { code: "invalid_json", message: "Claude gaf geen bruikbare cijfers terug. Probeer het opnieuw." };
    const byKey = new Map(items.map((i) => [i.key, i])), rows = [], seen = new Set();
    for (const x of res.items) {
      const it = x && byKey.get(x.key), v = x && Number(x.value);
      if (!it || !isFinite(v) || seen.has(x.key)) continue;
      seen.add(x.key);
      const old = typeof it.value === "number" ? it.value : null;
      if (old === v && (x.asOf || "") === (it.asOf || "")) continue;
      const odd = old != null && !SIGNED.has(it.key) && old > 0 && (v <= 0 || v / old > 3 || v / old < 0.33);
      rows.push({ key: it.key, label: it.label, value: v, asOf: String(x.asOf || "").slice(0, 30), src: String(x.src || "").slice(0, 60),
        fromT: fmt(it, old), toT: fmt(it, v) + (odd ? " (controleer: grote sprong)" : ""), on: !odd });
    }
    kvSet("lastMacroTry", { at: nowISO(), found: rows.length });
    return { rows, note: res.note ? String(res.note).slice(0, 300) : "" };
  }
  async function applyMacro(rows) {
    await ready;
    const doc = (await getDoc("market/latest")) || { items: [] };
    const items = new Map(doc.items.map((i) => [i.key, i]));
    let n = 0;
    for (const r of rows) { const it = items.get(r.key); if (!it) continue; Object.assign(it, { value: r.value, asOf: r.asOf || stamp(), src: (r.src ? r.src + " via " : "") + "Claude", display: null, change: "" }); n++; }
    const spx = items.get("spx"), dd = items.get("spxDD");
    if (spx && dd && rows.some((r) => r.key === "spx") && dd.ath) {
      if (spx.value > dd.ath) { dd.ath = spx.value; dd.athDate = new Date().toISOString().slice(0, 10); }
      dd.value = Math.round((spx.value / dd.ath - 1) * 10000) / 100; dd.asOf = spx.asOf; dd.src = "berekend uit de S&P 500";
      dd.change = "record " + nf(dd.ath, 0);
    }
    const t10 = items.get("us10y"), t2 = items.get("us2y"), cv = items.get("curve");
    if (cv && t10 && t2 && rows.some((r) => r.key === "us10y" || r.key === "us2y") && !rows.some((r) => r.key === "curve")) {
      cv.value = Math.round((t10.value - t2.value) * 100) / 100; cv.asOf = t10.asOf; cv.src = "berekend (10j − 2j)";
    }
    doc.items = [...items.values()]; doc.updatedAt = nowISO(); doc.updatedBy = "Claude (online opgezocht)";
    await setDoc("market/latest", doc);
    kvSet("lastMacro", { at: nowISO(), n });
    window.dispatchEvent(new Event("hp-local"));
    return n;
  }

  // ---------------- back-up ----------------
  async function exportBackup() {
    await ready;
    const docs = {}; for (const [p, r] of await rawAll()) if (r) docs[p] = r.data;
    const n = new Date(), pad = (x) => String(x).padStart(2, "0");
    const name = `handelsplan-backup-${n.getFullYear()}${pad(n.getMonth() + 1)}${pad(n.getDate())}-${pad(n.getHours())}${pad(n.getMinutes())}.json`;
    await downloads.save({ filename: name, data: JSON.stringify({ app: "handelsplan-2026", format: 1, exportedAt: nowISO(), docs }, null, 1) });
    kvSet("lastExport", nowISO());
    return name;
  }
  async function importBackup(file) {
    await ready;
    let j; try { j = JSON.parse(await file.text()); } catch (e) { throw { message: "Dit is geen back-upbestand van je handelsplan (.json)." }; }
    if (!j || j.app !== "handelsplan-2026" || !j.docs || !j.docs["plan/current"]) throw { message: "In dit bestand staat geen handelsplan." };
    const entries = Object.entries(j.docs).filter(([p, d]) => { try { colOf(p); return d && typeof d === "object"; } catch (e) { return false; } });
    await rawClear();
    for (const [p, d] of entries) await rawPut(p, { col: colOf(p), data: d, updated: Date.now() });
    const plan = await getDoc("plan/current"), market = await getDoc("market/latest");
    applyPatch(plan, market, SEED.patch);
    await rawPut("plan/current", { col: "plan", data: plan, updated: Date.now() });
    if (market) await rawPut("market/latest", { col: "market", data: market, updated: Date.now() });
    return { docs: entries.length };
  }

  // ---------------- overige onderdelen ----------------
  const downloads = {
    save: async ({ filename, data }) => {
      const url = URL.createObjectURL(data instanceof Blob ? data : new Blob([data], { type: "application/octet-stream" }));
      const a = document.createElement("a"); a.href = url; a.download = filename; document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 2000);
      return { status: "saved" };
    },
  };
  const user = { can: async () => true, canEdit: async () => true, isOwner: async () => true, id: async () => "me" };
  const local = {
    status: async () => {
      await ready;
      const usage = Object.values(kvGet("usage", {})).reduce((a, m) => ({ input: a.input + m.input, output: a.output + m.output, searches: a.searches + (m.searches || 0) }), { input: 0, output: 0, searches: 0 });
      return { keys: { anthropic: !!key("anthropic"), twelvedata: !!key("twelvedata") }, storage: mode, persisted: !!kvGet("persisted"),
        lastPrices: kvGet("lastPrices"), lastMacro: kvGet("lastMacro"), lastExport: kvGet("lastExport"), usage: usage.input || usage.output ? usage : null };
    },
    saveKeys: async (k) => { if (k.anthropic) kvSet("key:anthropic", k.anthropic.trim()); if (k.twelvedata) kvSet("key:twelvedata", k.twelvedata.trim()); },
    clearKeys: async () => { kvSet("key:anthropic", null); kvSet("key:twelvedata", null); },
    refreshPrices, findMacro, applyMacro, exportBackup, importBackup,
  };
  window.claude = {
    use: async (name) => {
      if (name === "db") { await ready; return db; }
      if (name === "sample") return key("anthropic") ? sample : null;
      if (name === "downloads") return downloads;
      if (name === "user") return user;
      if (name === "local") { await ready; return local; }
      return null;
    },
  };
})();

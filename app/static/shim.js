// Laat de handelsplan-pagina op je eigen server draaien: vervangt claude.use(...) door je eigen API.
(function () {
  "use strict";
  const listeners = new Set();
  const api = async (method, url, body) => {
    const r = await fetch(url, { method, headers: { "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined, credentials: "same-origin" });
    if (r.status === 401) { location.href = "/login"; throw { code: "revoked" }; }
    if (!r.ok) { let m = ""; try { const j = await r.json(); m = j.detail || ""; } catch (e) {} throw { code: r.status === 404 ? "invalid_argument" : r.status === 429 ? "resource_exhausted" : "unavailable", message: m }; }
    return r.json();
  };
  const refreshAll = () => listeners.forEach((fn) => fn());
  setInterval(() => { if (!document.hidden) refreshAll(); }, 30000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refreshAll(); });
  const freeze = (o) => o;
  const snap = (id, exists, data) => ({ id, exists, data: () => data, metadata: { fromCache: false, hasPendingWrites: false } });
  const newId = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36);

  function docRef(path) {
    const id = path.split("/").pop();
    return {
      id, path,
      get: async () => { const r = await api("GET", "/api/doc?path=" + encodeURIComponent(path)); return snap(id, r.exists, r.data); },
      set: async (d) => { await api("PUT", "/api/doc?path=" + encodeURIComponent(path), d); refreshAll(); },
      update: async (d) => { await api("PATCH", "/api/doc?path=" + encodeURIComponent(path), d); refreshAll(); },
      delete: async () => {},
      onSnapshot(next, err) {
        const run = async () => { try { const r = await api("GET", "/api/doc?path=" + encodeURIComponent(path)); next(snap(id, r.exists, r.data)); } catch (e) { err && err(e); } };
        listeners.add(run); run(); return () => listeners.delete(run);
      },
    };
  }
  function query(path, order, dir, lim) {
    const q = {
      where: () => q,
      orderBy: (f, d) => query(path, f, d || "asc", lim),
      limit: (n) => query(path, order, dir, n),
      get: async () => fetchQ(),
      onSnapshot(next, err) {
        const run = async () => { try { next(await fetchQ()); } catch (e) { err && err(e); } };
        listeners.add(run); run(); return () => listeners.delete(run);
      },
      doc: (id) => docRef(path + "/" + (id || newId())),
      add: async (d) => { const r = docRef(path + "/" + newId()); await r.set(d); return r; },
      path,
    };
    async function fetchQ() {
      const r = await api("GET", `/api/col?path=${encodeURIComponent(path)}&order=${encodeURIComponent(order || "")}&dir=${dir || "asc"}&limit=${lim || 100}`);
      const docs = r.docs.map((d) => snap(d.id, true, d.data));
      return { docs, size: docs.length, empty: !docs.length, docChanges: () => [], metadata: { fromCache: false, hasPendingWrites: false } };
    }
    return q;
  }
  const db = { doc: docRef, collection: (p) => query(p, "", "asc", 100) };

  async function sample(input, opts = {}) {
    const prompt = typeof input === "string" ? input : input.map((m) => m.content).join("\n\n");
    let r;
    try {
      r = await fetch("/api/ai", { method: "POST", headers: { "Content-Type": "application/json" }, credentials: "same-origin",
        body: JSON.stringify({ prompt, tier: opts.modelTier || "default" }), signal: opts.signal });
    } catch (e) { throw { code: e && e.name === "AbortError" ? "cancelled" : "upstream_error" }; }
    if (r.status === 401) { location.href = "/login"; throw { code: "session_expired" }; }
    if (r.status === 429) throw { code: "rate_limited" };
    if (!r.ok) { let m = ""; try { const j = await r.json(); m = j.detail || ""; } catch (e) {} throw { code: r.status === 503 ? "upstream_error" : "upstream_error", message: m }; }
    const data = await r.json();
    opts.onText && opts.onText({ text: data.text, delta: data.text });
    return { text: data.text, truncated: !!data.truncated, modelTierApplied: opts.modelTier || "default" };
  }
  sample.json = async (input, opts) => {
    const { text } = await sample(input, opts);
    const tryParse = (s) => { try { return JSON.parse(s); } catch { return undefined; } };
    let v = tryParse(text.trim());
    if (v === undefined) { const m = text.match(/```(?:json)?\s*([\s\S]*?)```/); if (m) v = tryParse(m[1]); }
    if (v === undefined) { const a = text.search(/[\[{]/), b = Math.max(text.lastIndexOf("}"), text.lastIndexOf("]")); if (a >= 0 && b > a) v = tryParse(text.slice(a, b + 1)); }
    if (v === undefined) throw { code: "invalid_json", text };
    return v;
  };
  sample.limits = async () => ({ maxPromptBytes: 262144 });

  const downloads = {
    save: async ({ filename, data }) => {
      const url = URL.createObjectURL(data instanceof Blob ? data : new Blob([data]));
      const a = document.createElement("a"); a.href = url; a.download = filename; a.click();
      setTimeout(() => URL.revokeObjectURL(url), 2000);
      return { status: "saved" };
    },
  };
  const user = { can: async () => true, canEdit: async () => true, isOwner: async () => true, id: async () => "me" };
  const server = {
    api: (method, url, body) => api(method, url, body),
    status: () => api("GET", "/api/status"),
    run: (job) => api("POST", "/api/run/" + encodeURIComponent(job)),
    backupUrl: "/api/export",
    restore: async (file) => {
      const r = await fetch("/api/import", { method: "POST", body: file, credentials: "same-origin", headers: { "Content-Type": "application/json" } });
      if (r.status === 401) { location.href = "/login"; throw { code: "revoked" }; }
      let j = {}; try { j = await r.json(); } catch (e) {}
      if (!r.ok) throw { code: "restore_failed", message: j.detail || "Terugzetten mislukt." };
      return j;
    },
    logout: async () => { await fetch("/logout", { method: "POST", credentials: "same-origin" }); location.href = "/login"; },
  };
  const caps = { db, sample, downloads, user, server };
  window.claude = { use: async (name) => caps[name] || null };
})();

// Losse html die met je Railway-site praat. Hier staat niets van je plan of sleutels in:
// alles (database, mail, Grok, koersen) komt van de server. Na inloggen bewaart Chrome alleen
// het serveradres en een inlogsleutel (geldig 30 dagen, vervalt als je APP_PASSWORD wijzigt).
(function () {
  "use strict";
  const KB = "hp2027:server", KT = "hp2027:token";
  const DEFAULT = "https://plan.vsonsbeek.nl";
  const mem = {};
  const get = (k) => { try { return localStorage.getItem(k) || mem[k] || ""; } catch (e) { return mem[k] || ""; } };
  const put = (k, v) => { mem[k] = v; try { v ? localStorage.setItem(k, v) : localStorage.removeItem(k); } catch (e) { /* privévenster: alleen in geheugen */ } };
  let release;
  const ready = new Promise((r) => { release = r; });

  function norm(raw) {
    let u = String(raw || "").trim();
    if (!u) return "";
    if (!/^https?:\/\//i.test(u)) u = "https://" + u;
    try {
      const x = new URL(u);
      const local = x.hostname === "localhost" || x.hostname === "127.0.0.1";
      if (x.protocol !== "https:" && !local) return "";
      return x.origin;
    } catch (e) { return ""; }
  }

  const CSS = `
#hpc{position:fixed;inset:0;z-index:1000;display:grid;place-items:center;padding:16px;background:rgba(9,14,19,.72);backdrop-filter:blur(3px)}
#hpc form{background:var(--surface,#fff);color:var(--ink,#13202C);border:1px solid var(--line,#D3DAE1);border-radius:14px;padding:26px;width:100%;max-width:400px;display:grid;gap:14px;box-shadow:0 20px 60px rgba(0,0,0,.35);font:15px/1.5 var(--font-body,system-ui,sans-serif)}
#hpc h1{margin:0;font:700 1.4rem var(--font-display,system-ui)}#hpc h1 span{color:var(--accent,#8A580A)}
#hpc p{margin:0;color:var(--muted,#56636F);font-size:.88rem}
#hpc label{display:grid;gap:4px;font-size:.84rem;color:var(--muted,#56636F)}
#hpc input{font:inherit;padding:10px;border:1px solid var(--line,#D3DAE1);border-radius:8px;background:var(--surface,#fff);color:var(--ink,#13202C)}
#hpc button{font:600 1rem var(--font-body,system-ui);padding:11px;border:0;border-radius:8px;background:var(--accent,#8A580A);color:#fff;cursor:pointer}
#hpc button:disabled{opacity:.6;cursor:default}
#hpc .err{color:var(--bad,#AF2F29);font-size:.9rem;min-height:1.2em}
#hpc .cs{display:flex;flex-wrap:wrap;gap:6px 14px;font-size:.8rem;color:var(--muted,#56636F);border-top:1px solid var(--line,#D3DAE1);padding-top:12px;min-height:1.6em}
#hpc .cs span{display:inline-flex;align-items:center;gap:6px}#hpc .cs i{width:8px;height:8px;border-radius:50%;background:var(--line,#D3DAE1)}
#hpc .cs .ok i{background:var(--good,#2D7A4B)}#hpc .cs .bad{color:var(--bad,#AF2F29)}#hpc .cs .bad i{background:var(--bad,#AF2F29)}`;

  const dot = (ok, t) => `<span class="${ok ? "ok" : "bad"}"><i></i>${t}</span>`;
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  async function probe(base, el) {
    if (!base) { el.innerHTML = dot(false, "Ongeldig adres: begin met https://"); return null; }
    el.innerHTML = `<span><i></i>Verbinding met ${esc(base.replace(/^https?:\/\//, ""))} controleren…</span>`;
    try {
      const r = await fetch(base + "/health", { cache: "no-store", credentials: "omit" });
      const j = await r.json();
      el.innerHTML = dot(true, "Server verbonden") + dot(j.database, j.database ? "Database verbonden" : "Database niet bereikbaar")
        + (j.login === false ? dot(false, "APP_PASSWORD ontbreekt in Railway") : "");
      return j;
    } catch (e) {
      el.innerHTML = dot(false, "Server niet bereikbaar. Klopt het adres, en staat de nieuwste Dockerfile op Railway?");
      return null;
    }
  }

  function show(msg, after) {
    const mount = () => {
      if (document.getElementById("hpc")) return;
      const st = document.createElement("style"); st.textContent = CSS; document.head.appendChild(st);
      const box = document.createElement("div"); box.id = "hpc"; box.setAttribute("role", "dialog"); box.setAttribute("aria-modal", "true"); box.setAttribute("aria-labelledby", "hpcT");
      box.innerHTML = `<form id="hpcF" autocomplete="on">
  <h1 id="hpcT">Handelsplan <span>2027</span></h1>
  <p>${esc(msg || "Deze html haalt alles van je Railway-site: plan, database, mail, Grok en koersen. Log in om verbinding te maken.")}</p>
  <label>Adres van je Railway-site<input id="hpcB" name="url" type="url" inputmode="url" autocomplete="url" spellcheck="false" required placeholder="https://jouw-site.up.railway.app"></label>
  <input type="text" name="username" autocomplete="username" value="handelsplan" hidden>
  <label>Wachtwoord (APP_PASSWORD)<input id="hpcP" name="password" type="password" autocomplete="current-password" required></label>
  <button type="submit" id="hpcGo">Verbinden</button>
  <div class="err" id="hpcE" role="alert"></div>
  <div class="cs" id="hpcS" aria-live="polite"></div>
</form>`;
      document.body.appendChild(box);
      const B = document.getElementById("hpcB"), P = document.getElementById("hpcP"), S = document.getElementById("hpcS"), E = document.getElementById("hpcE"), G = document.getElementById("hpcGo");
      B.value = get(KB) || DEFAULT;
      (get(KB) ? P : B).focus();
      probe(norm(B.value), S);
      B.addEventListener("change", () => probe(norm(B.value), S));
      document.getElementById("hpcF").addEventListener("submit", async (ev) => {
        ev.preventDefault();
        E.textContent = ""; G.disabled = true; G.textContent = "Verbinden…";
        const base = norm(B.value);
        try {
          if (!base) { E.textContent = "Vul het adres in, bijvoorbeeld https://jouw-site.up.railway.app"; return; }
          const h = await probe(base, S);
          if (!h) { E.textContent = "Geen verbinding met de server."; return; }
          let r;
          try {
            r = await fetch(base + "/api/token", { method: "POST", headers: { "Content-Type": "application/json" }, credentials: "omit", body: JSON.stringify({ password: P.value }) });
          } catch (e) { E.textContent = "De server antwoordt niet op inloggen. Staat de nieuwste versie op Railway?"; return; }
          let j = {}; try { j = await r.json(); } catch (e) { /* geen json */ }
          if (r.status === 404) { E.textContent = "Deze serverversie kent de losse html nog niet. Zet eerst de nieuwe Dockerfile op GitHub."; return; }
          if (!r.ok || !j.token) { E.textContent = j.error || "Inloggen mislukt."; P.value = ""; P.focus(); return; }
          put(KB, base); put(KT, j.token);
          box.remove();
          if (after) after(); else release();
        } finally { G.disabled = false; G.textContent = "Verbinden"; }
      });
    };
    if (document.body) mount(); else document.addEventListener("DOMContentLoaded", mount);
  }

  window.HP_REMOTE = {
    ready,
    base: () => get(KB),
    token: () => get(KT),
    expired: () => { put(KT, ""); show("Je inlog is verlopen of je wachtwoord is gewijzigd. Log opnieuw in.", () => location.reload()); },
    logout: () => { put(KT, ""); location.reload(); },
    change: () => { put(KT, ""); show("Kies het adres van je Railway-site en log in.", () => location.reload()); },
  };
  if (get(KB) && get(KT)) release(); else show();
})();

/* Causeway Bay Jarvis — the web client.
 *
 * One page, no framework, talking to the server it was loaded from:
 * every op is `POST /v1/<op>` with a JSON body and the same envelope the
 * LÖVE client reads; the shelves are read back over `/file/<path>`; a
 * turn streams over `/v1/chat/stream` as server-sent events; and a file
 * from the phone goes up as the body of `POST /upload`.
 *
 * State is one object, the URL hash names the agent and the shelf
 * (`#/food/videos`), and everything on screen is rendered from those —
 * `render()` is cheap enough to call after any change.
 */
(() => {
  "use strict";

  /* --------------------------------------------------------- helpers ---- */
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const h = (html) => { const t = document.createElement("template"); t.innerHTML = html.trim(); return t.content.firstElementChild; };
  const size = (n) => { n = Number(n) || 0; if (n >= 1 << 30) return (n / (1 << 30)).toFixed(2) + " GB"; if (n >= 1 << 20) return (n / (1 << 20)).toFixed(1) + " MB"; if (n >= 1024) return Math.round(n / 1024) + " KB"; return n + " B"; };
  const when = (secs) => { if (!secs) return ""; const d = new Date(secs * 1000); const now = Date.now(); const diff = (now - d) / 1000; if (diff < 60) return "just now"; if (diff < 3600) return Math.floor(diff / 60) + " min ago"; if (diff < 86400) return Math.floor(diff / 3600) + " h ago"; return d.toLocaleDateString(undefined, { month: "short", day: "numeric" }) + (diff > 300 * 86400 ? " " + d.getFullYear() : ""); };
  const fileUrl = (rel) => "/file/" + String(rel || "").split("/").map(encodeURIComponent).join("/");
  const meta = (item) => { try { return JSON.parse(item.meta || "{}") || {}; } catch { return {}; } };
  const isImage = (item) => String(item.mime || "").startsWith("image/");
  const isVideo = (item) => item.kind === "video" || String(item.mime || "").startsWith("video/");
  const initials = (name) => String(name || "?").trim().split(/\s+/).map((w) => w[0]).join("").slice(0, 2).toUpperCase();

  // The backend names a colour; the palette is here, the same one the
  // LÖVE window uses so an agent is the same colour on both screens.
  const COLORS = {
    gold: "hsl(45 95% 60%)", cyan: "hsl(190 95% 55%)", teal: "hsl(172 70% 50%)", jade: "hsl(150 70% 52%)",
    magenta: "hsl(320 85% 65%)", orange: "hsl(28 95% 60%)", lime: "hsl(90 70% 55%)", green: "hsl(150 70% 52%)",
    blue: "hsl(215 90% 68%)", yellow: "hsl(48 95% 60%)", red: "hsl(0 85% 66%)", violet: "hsl(268 90% 72%)",
    rose: "hsl(345 90% 70%)", sky: "hsl(205 90% 68%)", amber: "hsl(40 95% 60%)", ice: "hsl(200 60% 85%)",
  };
  const colorOf = (agent) => (agent && COLORS[String(agent.color || "").toLowerCase()]) || "var(--accent)";

  const toast = (text, tone = "") => {
    const el = h(`<div class="toast ${tone}">${esc(text)}</div>`);
    $("toasts").appendChild(el);
    setTimeout(() => { el.style.opacity = "0"; el.style.transition = "opacity .3s"; setTimeout(() => el.remove(), 320); }, 3800);
  };

  /* -------------------------------------------------------------- api ---- */
  async function api(op, body = {}) {
    const res = await fetch(`/v1/${op}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const reply = await res.json().catch(() => ({ ok: false, error: `HTTP ${res.status}` }));
    if (!reply.ok) throw new Error(reply.error || `${op} failed`);
    return reply.data;
  }

  /* ------------------------------------------------------------ state ---- */
  const TABS = [
    { id: "photos", label: "Photos", icon: "i-image", color: "cyan" },
    { id: "videos", label: "Videos", icon: "i-video", color: "violet" },
    { id: "files", label: "Files", icon: "i-file", color: "amber" },
    { id: "notes", label: "Notes", icon: "i-note", color: "magenta" },
    { id: "papers", label: "Paper", icon: "i-paper", color: "ice" },
    { id: "chat", label: "Chat", icon: "i-chat", color: "jade" },
    { id: "search", label: "Search", icon: "i-search", color: "gold" },
  ];

  const S = {
    agents: [],
    selected: null,       // an agent object, or null for everyone / the global space
    tab: "photos",
    page: null,           // the `page` reply for the selection
    pageFor: undefined,   // whose page that is (agent id or null); undefined = none yet
    everyone: null,       // the `gallery` reply, for photos with nobody chosen
    messages: [],
    health: null,
    where: null,
    stats: null,
    filter: "",
    search: { query: "", mode: "hybrid", all: false, hits: null, busy: false },
    stream: null,         // the EventSource of a turn in flight
    lightbox: { items: [], i: 0 },
  };

  /* ----------------------------------------------------------- theme ---- */
  const THEMES = ["auto", "dark", "light"];
  function applyTheme(t) {
    document.documentElement.dataset.theme = t === "auto" ? "" : t;
    document.documentElement.classList.toggle("light-scheme", t === "auto" && matchMedia("(prefers-color-scheme: light)").matches);
    $("theme-btn").title = "Theme: " + t;
    $("theme-btn").querySelector("use").setAttribute("href", t === "dark" ? "#i-moon" : t === "light" ? "#i-sun" : "#i-auto");
  }
  let theme = "auto";
  try { theme = localStorage.getItem("jarvis.theme") || "auto"; } catch {}
  applyTheme(theme);
  matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => applyTheme(theme));
  $("theme-btn").onclick = () => { theme = THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length]; try { localStorage.setItem("jarvis.theme", theme); } catch {} applyTheme(theme); };

  /* ---------------------------------------------------------- routing ---- */
  function parseHash() {
    const m = location.hash.match(/^#\/([^/]*)\/?([^/]*)/);
    return { who: m ? decodeURIComponent(m[1]) : "", tab: m && m[2] ? m[2] : "" };
  }
  function go(who, tab) {
    const slug = who ? who.slug : "";
    location.hash = `#/${encodeURIComponent(slug)}/${tab || S.tab}`;
  }
  function applyRoute() {
    const { who, tab } = parseHash();
    const agent = who ? S.agents.find((a) => a.slug === who || a.id === who) || null : null;
    const changed = (agent ? agent.id : null) !== (S.selected ? S.selected.id : null);
    S.selected = agent;
    if (TABS.some((t) => t.id === tab)) S.tab = tab;
    if (changed) { S.page = null; S.pageFor = undefined; S.messages = []; S.search.hits = null; }
    render();
    loadPage();
    if (S.tab === "chat") loadMessages();
  }
  addEventListener("hashchange", applyRoute);

  /* ------------------------------------------------------------ boot ---- */
  async function boot() {
    try {
      const [where, health, agents] = await Promise.all([
        fetch("/where").then((r) => r.json()).then((r) => r.data),
        api("health"),
        api("agents.list"),
      ]);
      S.where = where; S.health = health; S.agents = agents;
      $("version").textContent = where.version ? "v" + where.version : "";
      $("rail-foot").textContent = where.space || "";
      $("rail-foot").title = where.space || "";
    } catch (e) {
      $("ticker-text").textContent = "NO BACKEND — " + e.message;
      $("online-dot").className = "dot off";
      return;
    }
    refreshStats();
    applyRoute();
    setInterval(refreshHealth, 15000);
  }
  async function refreshHealth() { try { S.health = await api("health"); renderTicker(); } catch {} }
  async function refreshStats() { try { S.stats = await api("stats"); renderRail(); } catch {} }

  /* -------------------------------------------------------------- data ---- */
  let pageBusy = false;
  async function loadPage(force) {
    const want = S.selected ? S.selected.id : null;
    if (!force && S.pageFor === want && S.page) return;
    if (pageBusy) return;
    pageBusy = true;
    try {
      const page = await api("page", { agent: want || "global" });
      if ((S.selected ? S.selected.id : null) !== want) return;
      S.page = page; S.pageFor = want;
      if (!want) S.everyone = await api("gallery", {});
    } catch (e) {
      toast("Cannot read the archive: " + e.message, "bad");
    } finally {
      pageBusy = false;
      render();
    }
  }
  async function loadMessages() {
    try { S.messages = await api("messages", { agent: S.selected ? S.selected.id : "global", limit: 60 }); render(); } catch {}
  }

  /* ------------------------------------------------------------ render ---- */
  function render() {
    renderTicker();
    renderRail();
    renderHero();
    renderTabs();
    renderContent();
    const whose = S.selected ? S.selected.name : "the global space";
    for (const id of ["add-whose", "note-whose", "drop-whose"]) $(id).textContent = whose;
  }

  function renderTicker() {
    const hlt = S.health;
    if (!hlt) return;
    const p = hlt.provider || {};
    const eff = String(p.effective || "").toUpperCase();
    const cur = String(p.current || "auto").toUpperCase();
    const label = cur === eff || eff === "" ? cur : `${cur}›${eff.replace("ONDEVICE", "ON-DEV")}`;
    $("brain-text").textContent = label.replace("ONDEVICE", "ON-DEV");
    const chip = $("brain");
    chip.className = "chip chip-brain " + (eff === "OFFLINE" ? "bad" : eff === "CLOUD" ? "warn" : "on");
    chip.title = (p.why ? p.why + " — " : "") + "click to change which brain answers";
    const dot = $("online-dot");
    dot.className = "dot " + (eff === "OFFLINE" ? "off" : eff === "CLOUD" ? "warn" : "on");
    const model = (p.ondevice && p.ondevice.model) || (p.cloud && p.cloud.model) || "";
    const bits = [eff === "OFFLINE" ? "OFFLINE · ARCHIVE ONLY" : eff === "CLOUD" ? "CLOUD · PROMPTS LEAVE THIS MAC" : "ON-DEVICE · NOTHING LEAVES THIS MAC"];
    if (model) bits.push(model);
    if (S.where && !S.where.loopback) bits.push("OPEN ON THE WI-FI");
    $("ticker-text").textContent = bits.join("  ·  ");
  }

  function renderRail() {
    const list = $("agents");
    const q = S.filter.trim().toLowerCase();
    const counts = {};
    const items = [];
    const everyoneOn = !S.selected;
    items.push(`
      <li><button class="agent everyone ${everyoneOn ? "on" : ""}" data-id="">
        <span class="avatar" style="--c:var(--accent)"><svg viewBox="0 0 24 24" width="20" height="20"><use href="#i-bolt"/></svg></span>
        <span style="min-width:0"><span class="agent-name">EVERYONE</span><br><span class="agent-role">every agent, and the global space</span></span>
        <span class="agent-n">${S.stats ? esc(S.stats.items) : ""}</span>
      </button></li>`);
    for (const a of S.agents) {
      if (q && !(`${a.name} ${a.slug} ${a.role} ${a.kind} ${a.keywords}`.toLowerCase().includes(q))) continue;
      const on = S.selected && S.selected.id === a.id;
      items.push(`
        <li><button class="agent ${on ? "on" : ""}" data-id="${esc(a.id)}" style="--c:${colorOf(a)}">
          <span class="avatar" style="--c:${colorOf(a)}">${esc(initials(a.name))}</span>
          <span style="min-width:0"><span class="agent-name">${esc(a.name)}</span><br><span class="agent-role">${esc(a.role)} · ${esc(a.kind)}</span></span>
          <span class="agent-n">${counts[a.id] || ""}</span>
        </button></li>`);
    }
    list.innerHTML = items.join("");
    $("rail-count").textContent = S.agents.length ? `${S.agents.length} agents` : "";
    list.querySelectorAll(".agent").forEach((b) => {
      b.onclick = () => { const a = S.agents.find((x) => x.id === b.dataset.id) || null; go(a, S.tab); };
    });
    const on = list.querySelector(".agent.on");
    if (on && innerWidth <= 860) on.scrollIntoView({ block: "nearest", inline: "center", behavior: "smooth" });
  }

  function renderHero() {
    const a = S.selected;
    const p = S.page && S.pageFor === (a ? a.id : null) ? S.page : null;
    const c = colorOf(a);
    const total = p ? p.gallery.length + p.videos.length + p.files.length + p.markdowns.length + p.notes.length : null;
    $("hero").style.setProperty("--c", c);
    $("hero").innerHTML = a ? `
      <span class="avatar" style="--c:${c}">${esc(initials(a.name))}</span>
      <div style="min-width:0">
        <div class="hero-title"><h1>${esc(a.name)}</h1><span class="hero-role">${esc(a.role)} // ${esc(a.kind)}</span><span class="tag mono">${esc(a.id.slice(0, 8))}</span></div>
        <p class="hero-persona">${esc(a.persona)}</p>
        <div class="hero-folder"><svg viewBox="0 0 24 24" width="14" height="14"><use href="#i-folder"/></svg>${esc(p ? p.folder : "reading the archive…")}</div>
      </div>
      <div class="hero-stats">
        <div class="stat"><b>${total ?? "–"}</b><span>items</span></div>
        <div class="stat"><b>${p ? p.messages : "–"}</b><span>messages</span></div>
        <div class="stat"><b>${p ? size(p.bytes) : "–"}</b><span>on disk</span></div>
      </div>` : `
      <span class="avatar" style="--c:${c}"><svg viewBox="0 0 24 24" width="28" height="28"><use href="#i-bolt"/></svg></span>
      <div style="min-width:0">
        <div class="hero-title"><h1>EVERYONE</h1><span class="hero-role">${S.agents.length} agents // the global space</span></div>
        <p class="hero-persona">Nobody chosen: the photo shelf is every agent's photos at once, a search asks every agent, and a turn is routed to whichever agent the words belong to. What is filed here goes to the global space.</p>
        <div class="hero-folder"><svg viewBox="0 0 24 24" width="14" height="14"><use href="#i-folder"/></svg>${esc(p ? p.folder : "reading the archive…")}</div>
      </div>
      <div class="hero-stats">
        <div class="stat"><b>${S.stats ? S.stats.items : "–"}</b><span>items</span></div>
        <div class="stat"><b>${S.stats ? S.stats.images : "–"}</b><span>photos</span></div>
        <div class="stat"><b>${S.stats ? S.stats.videos ?? 0 : "–"}</b><span>videos</span></div>
        <div class="stat"><b>${S.stats ? size(S.stats.bytes) : "–"}</b><span>on disk</span></div>
      </div>`;
  }

  function counts() {
    const p = S.page && S.pageFor === (S.selected ? S.selected.id : null) ? S.page : null;
    if (!p) return {};
    return {
      photos: !S.selected && S.everyone ? S.everyone.total : p.gallery.length,
      videos: p.videos.length, files: p.files.length, notes: p.markdowns.length + p.notes.length,
      papers: p.papers.length, chat: p.messages, search: S.search.hits ? S.search.hits.length : null,
    };
  }

  function renderTabs() {
    const n = counts();
    const tab = (t, i, mobile) => `
      <button class="tab" role="tab" aria-selected="${S.tab === t.id}" data-tab="${t.id}" style="--c:${COLORS[t.color]}">
        <svg viewBox="0 0 24 24" width="16" height="16"><use href="#${t.icon}"/></svg>${t.label}
        ${n[t.id] != null ? `<span class="n">${n[t.id]}</span>` : ""}${mobile ? "" : `<kbd>${i + 1}</kbd>`}
      </button>`;
    $("tabs").innerHTML = TABS.map((t, i) => tab(t, i, false)).join("");
    $("bottombar").innerHTML = TABS.map((t, i) => tab(t, i, true)).join("");
    document.querySelectorAll(".tab").forEach((b) => { b.onclick = () => go(S.selected, b.dataset.tab); });
  }

  function renderContent() {
    const box = $("content");
    const p = S.page && S.pageFor === (S.selected ? S.selected.id : null) ? S.page : null;
    if (!p && S.tab !== "chat" && S.tab !== "search") {
      box.innerHTML = `<div class="empty"><b>Reading the archive…</b>${esc(S.selected ? S.selected.name : "everyone")}</div>`;
      return;
    }
    switch (S.tab) {
      case "photos": return renderPhotos(box, p);
      case "videos": return renderVideos(box, p);
      case "files": return renderFiles(box, p);
      case "notes": return renderNotes(box, p);
      case "papers": return renderPapers(box, p);
      case "chat": return renderChat(box);
      case "search": return renderSearch(box);
    }
  }

  const empty = (icon, title, text) => `<div class="empty"><svg viewBox="0 0 24 24" width="36" height="36"><use href="#${icon}"/></svg><b>${esc(title)}</b>${esc(text)}</div>`;

  /* --- photos ------------------------------------------------------------ */
  function renderPhotos(box, p) {
    let items;
    if (!S.selected && S.everyone) {
      items = [];
      for (const g of S.everyone.groups) for (const ph of g.photos) items.push({ ...ph, owner: g.agent, ownerName: g.agent ? g.agent.name : "GLOBAL" });
    } else items = p.gallery;
    if (!items.length) { box.innerHTML = empty("i-image", "No photos yet", "Press Add, drop a picture on the page, or take one with the phone's camera."); return; }
    S.lightbox.items = items;
    box.innerHTML = `<div class="grid">${items.map((it, i) => `
      <figure class="tile" data-i="${i}" style="--i:${Math.min(i, 30)};--c:${colorOf(it.owner)}">
        <img src="${fileUrl(it.path)}" alt="${esc(it.title)}" loading="lazy" decoding="async" />
        ${it.ownerName ? `<span class="owner"><span class="tag">${esc(it.ownerName)}</span></span>` : ""}
        <figcaption class="cap">${esc(it.title)}</figcaption>
      </figure>`).join("")}</div>`;
    box.querySelectorAll(".tile").forEach((t) => { t.onclick = () => openLightbox(Number(t.dataset.i)); });
  }

  /* --- videos ------------------------------------------------------------ */
  function renderVideos(box, p) {
    const items = p.videos;
    if (!items.length) { box.innerHTML = empty("i-video", "No videos yet", "A video filed here keeps its original for the browser, and gets a three-second Ogg Theora clip beside it for the LÖVE window."); return; }
    box.innerHTML = `<div class="grid videos">${items.map((it, i) => {
      const m = meta(it);
      const clip = m.clip ? `<a class="tag accent clip" href="${fileUrl(m.clip)}" title="The three-second Ogg Theora clip LÖVE plays (${esc(m.encoder || "")})"><svg viewBox="0 0 24 24" width="12" height="12"><use href="#i-love"/></svg>LÖVE clip ${m.seconds ? Math.round(m.seconds) + "s" : ""}${m.width ? ` · ${m.width}×${m.height}` : ""}</a>`
        : `<span class="tag warn" title="${esc(m.why || "")}">no LÖVE clip</span>`;
      return `
      <article class="vcard" style="--i:${Math.min(i, 30)}">
        <video controls playsinline preload="metadata" ${m.poster ? `poster="${fileUrl(m.poster)}"` : ""} src="${fileUrl(it.path)}"></video>
        <div class="vcard-body">
          <div class="vcard-title" title="${esc(it.title)}">${esc(it.title)}</div>
          <div class="vcard-meta">
            <span class="tag">${esc(size(it.bytes))}</span>
            ${m.duration ? `<span class="tag">${Number(m.duration).toFixed(1)} s</span>` : ""}
            <span class="tag">${esc(when(it.created_at))}</span>
            ${clip}
          </div>
          ${m.why && !m.clip ? `<div class="faint" style="font-size:12px">${esc(m.why)}</div>` : ""}
          <div class="vcard-actions">
            <a class="btn btn-sm" href="${fileUrl(it.path)}" download="${esc(it.title)}"><svg viewBox="0 0 24 24" width="16" height="16"><use href="#i-download"/></svg>Original</a>
            <button class="btn btn-sm btn-danger" data-del="${it.id}" title="Forget this row (the file stays on disk)"><svg viewBox="0 0 24 24" width="16" height="16"><use href="#i-trash"/></svg></button>
          </div>
        </div>
      </article>`;
    }).join("")}</div>`;
    wireDelete(box);
  }

  /* --- files ------------------------------------------------------------- */
  function renderFiles(box, p) {
    const items = p.files;
    if (!items.length) { box.innerHTML = empty("i-file", "No files yet", "A PDF, a CSV, a binary — anything that is not a picture, a video or a markdown page lands here."); return; }
    box.innerHTML = `<div class="panel"><div class="rows">${items.map((it) => `
      <div class="row">
        <span class="row-ic"><svg viewBox="0 0 24 24" width="20" height="20"><use href="#i-file"/></svg></span>
        <div class="row-main"><div class="row-title">${esc(it.title)}</div><div class="row-sub">${esc(it.mime)} · ${esc(size(it.bytes))} · ${esc(when(it.created_at))} · <span class="mono">${esc(it.path || "")}</span></div></div>
        <div class="row-actions">
          <a class="btn btn-sm" href="${fileUrl(it.path)}" target="_blank" rel="noopener">Open</a>
          <button class="btn btn-sm btn-danger" data-del="${it.id}"><svg viewBox="0 0 24 24" width="16" height="16"><use href="#i-trash"/></svg></button>
        </div>
      </div>`).join("")}</div></div>`;
    wireDelete(box);
  }

  /* --- notes ------------------------------------------------------------- */
  function renderNotes(box, p) {
    const items = [...p.markdowns, ...p.notes].sort((a, b) => b.id - a.id);
    if (!items.length) { box.innerHTML = empty("i-note", "Nothing written down yet", "A markdown page filed here, or a note the agent wrote itself, is what a turn retrieves from."); return; }
    box.innerHTML = items.map((it, i) => {
      const m = meta(it);
      return `
      <article class="note" style="--i:${i}">
        <div class="note-head">
          <h3>${esc(it.title)}</h3>
          <div class="row-actions">
            <span class="tag ${it.kind === "markdown" ? "accent" : ""}">${esc(it.kind)}${m.author === "tool" ? " · by the agent" : ""}</span>
            <span class="tag">${esc(when(it.created_at))}</span>
            ${it.path ? `<a class="btn btn-sm" href="${fileUrl(it.path)}" target="_blank" rel="noopener">Raw</a>` : ""}
            <button class="btn btn-sm btn-danger" data-del="${it.id}"><svg viewBox="0 0 24 24" width="16" height="16"><use href="#i-trash"/></svg></button>
          </div>
        </div>
        <div class="md ${it.body.length > 1200 ? "clamp" : ""}">${markdown(it.body)}</div>
        ${it.body.length > 1200 ? `<button class="btn btn-sm" style="margin-top:10px" data-expand>Read all</button>` : ""}
      </article>`;
    }).join("");
    box.querySelectorAll("[data-expand]").forEach((b) => { b.onclick = () => { b.previousElementSibling.classList.remove("clamp"); b.remove(); }; });
    wireDelete(box);
  }

  /* --- papers ------------------------------------------------------------ */
  function renderPapers(box, p) {
    const items = p.papers;
    const draw = `<div class="panel-head"><h3>Paper</h3><button class="btn btn-sm btn-primary" id="draw-paper"><svg viewBox="0 0 24 24" width="16" height="16"><use href="#i-paper"/></svg>Draw a paper now</button></div>`;
    box.innerHTML = `<div class="panel" style="margin-bottom:14px">${draw}</div>` + (items.length
      ? `<div class="grid papers">${items.map((it, i) => `<figure class="tile" data-i="${i}" style="--i:${i}"><img src="${fileUrl(it.path)}" alt="${esc(it.title)}" loading="lazy" /><figcaption class="cap">${esc(it.title)}</figcaption></figure>`).join("")}</div>`
      : empty("i-paper", "No paper drawn yet", "A paper is this whole archive as one 1024×1024 picture: the head, the shelves, the gallery strip and the words."));
    S.lightbox.items = items;
    box.querySelectorAll(".tile").forEach((t) => { t.onclick = () => openLightbox(Number(t.dataset.i)); });
    $("draw-paper").onclick = async () => {
      const b = $("draw-paper"); b.disabled = true; b.textContent = "Drawing…";
      try { const d = await api("paper", { agent: S.selected ? S.selected.id : "global" }); toast(`Paper ${d.width}×${d.height} drawn`, "good"); await loadPage(true); }
      catch (e) { toast("Paper refused: " + e.message, "bad"); b.disabled = false; }
    };
  }

  /* --- chat -------------------------------------------------------------- */
  function renderChat(box) {
    const who = S.selected ? S.selected.name : "the swarm";
    const msgs = S.messages.map(msgHtml).join("");
    box.innerHTML = `
      <div class="panel chat">
        <div class="panel-head"><h3>Transcript</h3><button class="btn btn-sm" type="button" id="clear-chat" title="Clear the transcript">Clear</button></div>
        <div class="msgs" id="msgs">${msgs || `<div class="empty" style="border:0"><b>Nothing said yet</b>Say something to ${esc(who)}. ${S.selected ? "" : "With nobody chosen the words are routed to whichever agent they belong to."}</div>`}</div>
        <form class="composer" id="composer">
          <input class="field" id="say" placeholder="Say something to ${esc(who)}…" autocomplete="off" enterkeyhint="send" />
          <button class="btn btn-primary" type="submit" id="send"><svg viewBox="0 0 24 24" width="18" height="18"><use href="#i-send"/></svg></button>
        </form>
      </div>`;
    const list = $("msgs");
    list.scrollTop = list.scrollHeight;
    $("composer").onsubmit = (e) => { e.preventDefault(); send($("say").value); };
    $("clear-chat").onclick = async () => {
      if (!confirm(`Clear the transcript with ${who}?`)) return;
      try { await api("messages.clear", { agent: S.selected ? S.selected.id : "global" }); S.messages = []; render(); loadPage(true); } catch (e) { toast(e.message, "bad"); }
    };
  }
  function msgHtml(m) {
    const role = m.role || "user";
    return `<div class="msg ${esc(role)}"><span class="who">${esc(role)}</span>${markdown(m.body)}</div>`;
  }
  function send(text) {
    text = String(text || "").trim();
    if (!text || S.stream) return;
    const who = S.selected ? S.selected.id : "";
    const list = $("msgs");
    if (list.querySelector(".empty")) list.innerHTML = "";
    list.appendChild(h(msgHtml({ role: "user", body: text })));
    const reply = h(`<div class="msg assistant"><span class="who">${esc(S.selected ? S.selected.name : "…")}</span><div class="tools"></div><details hidden><summary>thinking</summary><div class="thinking"></div></details><div class="body caret"></div></div>`);
    list.appendChild(reply);
    list.scrollTop = list.scrollHeight;
    $("say").value = "";
    const send = $("send");
    send.innerHTML = `<svg viewBox="0 0 24 24" width="18" height="18"><use href="#i-stop"/></svg>`;
    send.type = "button";
    let answer = "", thinking = "";
    const body = reply.querySelector(".body"), think = reply.querySelector(".thinking"), details = reply.querySelector("details");
    const url = `/v1/chat/stream?text=${encodeURIComponent(text)}&agent=${encodeURIComponent(who)}`;
    const es = new EventSource(url);
    S.stream = es;
    const finish = () => { es.close(); S.stream = null; body.classList.remove("caret"); send.innerHTML = `<svg viewBox="0 0 24 24" width="18" height="18"><use href="#i-send"/></svg>`; send.type = "submit"; };
    send.onclick = () => { if (S.stream) { finish(); toast("Stopped", "warn"); } };
    es.addEventListener("token", (e) => { answer += JSON.parse(e.data).text; body.innerHTML = markdown(answer); list.scrollTop = list.scrollHeight; });
    es.addEventListener("reasoning", (e) => { thinking += JSON.parse(e.data).text; details.hidden = false; think.textContent = thinking; });
    es.addEventListener("tool", (e) => { reply.querySelector(".tools").appendChild(h(`<span class="tag">${esc(JSON.parse(e.data).text)}</span>`)); });
    es.addEventListener("prefill", (e) => { const d = JSON.parse(e.data); body.textContent = `reading ${d.done}/${d.total}…`; });
    es.addEventListener("done", (e) => {
      const d = JSON.parse(e.data).data || {};
      const agent = d.agent;
      if (agent) reply.querySelector(".who").textContent = agent.name;
      if (d.reply) body.innerHTML = markdown(d.reply);
      const receipt = [];
      if (d.model) receipt.push(`<span class="tag">${esc(d.model)}</span>`);
      if (d.effective) receipt.push(`<span class="tag ${d.effective === "offline" ? "warn" : "good"}">${esc(d.effective)}</span>`);
      if (d.seconds) receipt.push(`<span class="tag">${Number(d.seconds).toFixed(1)} s</span>`);
      if (receipt.length) reply.appendChild(h(`<div class="receipt">${receipt.join("")}</div>`));
      finish();
      loadMessages();
      refreshHealth();
    });
    es.addEventListener("error", (e) => {
      let why = "the stream closed";
      try { why = JSON.parse(e.data).error || why; } catch {}
      if (S.stream) { body.textContent = why; body.classList.add("faint"); finish(); }
    });
    es.onerror = () => { if (S.stream) { body.textContent = (answer || "") + "\n[connection lost]"; finish(); } };
  }

  /* --- search ------------------------------------------------------------ */
  function renderSearch(box) {
    const s = S.search;
    const where = s.all || !S.selected ? "every agent" : S.selected.name;
    box.innerHTML = `
      <div class="panel">
        <form class="searchbar" id="searchform">
          <input class="field" id="q" placeholder="Search ${esc(where)}… BM25 and vectors, fused" value="${esc(s.query)}" autocomplete="off" enterkeyhint="search" />
          <div class="seg" id="modes">${["hybrid", "bm25", "semantic"].map((m) => `<button type="button" data-mode="${m}" aria-pressed="${s.mode === m}">${m}</button>`).join("")}</div>
          <div class="seg"><button type="button" id="all" aria-pressed="${s.all}" ${S.selected ? "" : "disabled"}>all agents</button></div>
          <button class="btn btn-primary" type="submit">Search</button>
        </form>
        <div id="hits">${hitsHtml()}</div>
      </div>`;
    $("searchform").onsubmit = (e) => { e.preventDefault(); runSearch($("q").value); };
    box.querySelectorAll("#modes button").forEach((b) => { b.onclick = () => { s.mode = b.dataset.mode; if (s.query) runSearch(s.query); else renderSearch(box); }; });
    $("all").onclick = () => { s.all = !s.all; if (s.query) runSearch(s.query); else renderSearch(box); };
    if (!s.query) setTimeout(() => $("q").focus(), 50);
    const hits = (s.hits || []).map((x) => x.item).filter((it) => it && isImage(it) && it.path);
    S.lightbox.items = hits;
    box.querySelectorAll("[data-lb]").forEach((t) => { t.onclick = () => openLightbox(Number(t.dataset.lb)); });
  }
  function hitsHtml() {
    const s = S.search;
    if (s.busy) return `<div class="empty" style="border:0"><b>Searching…</b></div>`;
    if (!s.hits) return `<div class="empty" style="border:0"><b>Type a few words</b>A chosen agent searches its own database; nobody chosen searches every agent at once.</div>`;
    if (!s.hits.length) return `<div class="empty" style="border:0"><b>Nothing for “${esc(s.query)}”</b>Try other words, or the semantic mode.</div>`;
    let lb = 0;
    return s.hits.map((hit) => {
      const it = hit.item || {};
      const img = isImage(it) && it.path;
      const thumb = img ? `<img class="hit-thumb" src="${fileUrl(it.path)}" data-lb="${lb++}" alt="" loading="lazy" />`
        : `<span class="hit-thumb ic"><svg viewBox="0 0 24 24" width="22" height="22"><use href="#${isVideo(it) ? "i-video" : it.kind === "message" ? "i-chat" : it.kind === "file" ? "i-file" : "i-note"}"/></svg></span>`;
      return `<div class="hit">
        ${thumb}
        <div style="min-width:0">
          <div class="hit-title">${esc(it.title)}</div>
          <div class="hit-snip">${esc((it.body || "").slice(0, 240))}</div>
          <div class="hit-meta"><span class="tag accent">${esc(hit.agent_name || "")}</span><span class="tag">${esc(it.kind)}</span>${hit.via ? `<span class="tag">${esc(hit.via)}</span>` : ""}<span class="score">${Number(hit.score || 0).toFixed(3)}</span></div>
        </div>
        ${it.path ? `<a class="btn btn-sm" href="${fileUrl(it.path)}" target="_blank" rel="noopener">Open</a>` : ""}
      </div>`;
    }).join("");
  }
  async function runSearch(query) {
    const s = S.search;
    query = String(query || "").trim();
    if (!query) return;
    s.query = query; s.busy = true; renderContent();
    try {
      const d = await api("search", { query, mode: s.mode, all: s.all, agent: S.selected ? S.selected.id : "", limit: 30 });
      s.hits = d.hits || [];
    } catch (e) { s.hits = []; toast("Search failed: " + e.message, "bad"); }
    s.busy = false; renderTabs(); renderContent();
  }

  /* --- delete ------------------------------------------------------------ */
  function wireDelete(box) {
    box.querySelectorAll("[data-del]").forEach((b) => {
      b.onclick = async () => {
        if (!confirm("Forget this item? The file stays on disk; only the row goes.")) return;
        try { await api("item.delete", { item: Number(b.dataset.del) }); toast("Forgotten", "good"); await loadPage(true); refreshStats(); }
        catch (e) { toast(e.message, "bad"); }
      };
    });
  }

  /* --- lightbox ---------------------------------------------------------- */
  function openLightbox(i) {
    S.lightbox.i = i;
    showLightbox();
    $("lightbox").showModal();
  }
  function showLightbox() {
    const { items, i } = S.lightbox;
    const it = items[i];
    if (!it) return;
    const fig = $("lb-figure");
    fig.innerHTML = isVideo(it) ? `<video src="${fileUrl(it.path)}" controls autoplay playsinline></video>` : `<img src="${fileUrl(it.path)}" alt="${esc(it.title)}" />`;
    $("lb-caption").innerHTML = `<b>${esc(it.title)}</b>${it.ownerName ? `<span class="tag accent">${esc(it.ownerName)}</span>` : ""}<span class="tag">${esc(size(it.bytes))}</span><span class="tag">${i + 1} / ${items.length}</span><a class="tag" href="${fileUrl(it.path)}" target="_blank" rel="noopener">open</a>`;
    $("lb-prev").hidden = items.length < 2; $("lb-next").hidden = items.length < 2;
  }
  $("lb-prev").onclick = () => { const n = S.lightbox.items.length; S.lightbox.i = (S.lightbox.i - 1 + n) % n; showLightbox(); };
  $("lb-next").onclick = () => { const n = S.lightbox.items.length; S.lightbox.i = (S.lightbox.i + 1) % n; showLightbox(); };
  $("lightbox").onclick = (e) => { if (e.target === $("lightbox") || e.target === $("lb-figure")) $("lightbox").close(); };
  $("lightbox").addEventListener("close", () => { $("lb-figure").innerHTML = ""; });
  let touchX = null;
  $("lightbox").addEventListener("touchstart", (e) => { touchX = e.touches[0].clientX; }, { passive: true });
  $("lightbox").addEventListener("touchend", (e) => { if (touchX == null) return; const dx = e.changedTouches[0].clientX - touchX; touchX = null; if (dx > 60) $("lb-prev").click(); else if (dx < -60) $("lb-next").click(); });

  /* --- upload ------------------------------------------------------------ */
  function uploadFiles(files) {
    files = [...files];
    if (!files.length) return;
    $("add-dialog").open || $("add-dialog").showModal();
    const list = $("uploads");
    const who = S.selected ? S.selected.id : "";
    let left = files.length;
    for (const f of files) {
      const row = h(`<li class="upload"><span>${esc(f.name)}</span><span class="faint">${esc(size(f.size))}</span><span class="bar"><i></i></span></li>`);
      list.appendChild(row);
      const bar = row.querySelector("i");
      const xhr = new XMLHttpRequest();
      xhr.open("POST", `/upload?agent=${encodeURIComponent(who)}&name=${encodeURIComponent(f.name)}`);
      if (f.type) xhr.setRequestHeader("Content-Type", f.type);
      xhr.upload.onprogress = (e) => { if (e.lengthComputable) bar.style.width = (e.loaded / e.total * 100).toFixed(1) + "%"; };
      xhr.onload = () => {
        let reply = {};
        try { reply = JSON.parse(xhr.responseText); } catch {}
        if (reply.ok) {
          row.classList.add("done"); bar.style.width = "100%";
          const it = reply.data || {};
          const m = meta(it);
          toast(`${it.kind || "file"} filed with ${S.selected ? S.selected.name : "the global space"}${it.kind === "video" ? (m.clip ? " — LÖVE clip made" : " — no LÖVE clip: " + (m.why || "")) : ""}`, it.kind === "video" && !m.clip ? "warn" : "good");
        } else {
          row.classList.add("bad");
          row.querySelector(".faint").textContent = reply.error || `HTTP ${xhr.status}`;
          toast("Refused: " + (reply.error || xhr.status), "bad");
        }
        if (--left === 0) { loadPage(true); refreshStats(); setTimeout(() => { if ($("add-dialog").open && !list.querySelector(".bad")) $("add-dialog").close(); list.innerHTML = ""; }, 900); }
      };
      xhr.onerror = () => { row.classList.add("bad"); toast("Upload failed: " + f.name, "bad"); if (--left === 0) loadPage(true); };
      xhr.send(f);
    }
  }
  for (const id of ["pick-media", "pick-camera", "pick-any"]) {
    $(id).addEventListener("change", (e) => { uploadFiles(e.target.files); e.target.value = ""; });
  }
  $("fab").onclick = () => { $("uploads").innerHTML = ""; $("add-dialog").showModal(); };

  // Drop anywhere on the page.
  let dragDepth = 0;
  addEventListener("dragenter", (e) => { if (!e.dataTransfer || ![...e.dataTransfer.types].includes("Files")) return; e.preventDefault(); dragDepth++; $("dropzone").classList.add("on"); });
  addEventListener("dragover", (e) => { if ($("dropzone").classList.contains("on")) e.preventDefault(); });
  addEventListener("dragleave", () => { if (--dragDepth <= 0) { dragDepth = 0; $("dropzone").classList.remove("on"); } });
  addEventListener("drop", (e) => { if (!$("dropzone").classList.contains("on")) return; e.preventDefault(); dragDepth = 0; $("dropzone").classList.remove("on"); uploadFiles(e.dataTransfer.files); });

  // A note, typed here.
  $("write-note").onclick = () => { $("add-dialog").close(); $("note-title").value = ""; $("note-body").value = ""; $("note-dialog").showModal(); setTimeout(() => $("note-title").focus(), 50); };
  $("note-form").onsubmit = async (e) => {
    e.preventDefault();
    const body = $("note-body").value.trim();
    if (!body) return;
    try {
      await api("item.add", { agent: S.selected ? S.selected.id : "global", kind: "markdown", title: $("note-title").value.trim(), body });
      $("note-dialog").close(); toast("Note filed", "good"); loadPage(true); refreshStats();
      if (S.tab !== "notes") go(S.selected, "notes");
    } catch (err) { toast(err.message, "bad"); }
  };

  /* --- share, brain, filter ---------------------------------------------- */
  $("share-btn").onclick = () => {
    const w = S.where || {};
    const urls = (w.urls || []).filter((u) => !u.includes("127.0.0.1"));
    $("share-body").innerHTML = (urls.length
      ? `<p class="muted">On the same Wi-Fi, open one of these — or add it to the home screen and it opens like an app.</p>${urls.map((u) => `<div class="share-url"><a href="${esc(u)}">${esc(u)}</a><button class="btn btn-sm" data-copy="${esc(u)}">Copy</button></div>`).join("")}`
      : `<p class="muted">This server answers on <code>${esc(w.bind || "127.0.0.1")}:${esc(w.port || "")}</code> — this Mac only.</p>`)
      + `<div class="share-note">${w.loopback
        ? `To reach it from a phone or a tablet, start the backend on every interface:<br><code>make start BIND=0.0.0.0</code><br>There is no login on this page — anything on the Wi-Fi can then read the archive and use the GPU.`
        : `Open to the Wi-Fi. There is no login on this page — anything that can reach it can read the archive and use the GPU.`}</div>`;
    $("share-body").querySelectorAll("[data-copy]").forEach((b) => { b.onclick = async () => { try { await navigator.clipboard.writeText(b.dataset.copy); toast("Copied", "good"); } catch { toast("Select and copy the address", "warn"); } }; });
    $("share-dialog").showModal();
  };
  $("brain").onclick = async () => {
    const ring = ["auto", "ondevice", "cloud"];
    const cur = (S.health && S.health.provider && S.health.provider.current) || "auto";
    const next = ring[(ring.indexOf(cur) + 1) % ring.length];
    try { const p = await api("provider.set", { provider: next }); S.health.provider = p; renderTicker(); toast(`AI ${next.toUpperCase()}${p.effective && p.effective !== next ? " › " + String(p.effective).toUpperCase() : ""}${p.why ? " — " + p.why : ""}`, p.effective === "offline" ? "warn" : "good"); }
    catch (e) { toast(e.message, "bad"); }
  };
  $("rail-filter").oninput = (e) => { S.filter = e.target.value; renderRail(); };
  document.querySelectorAll("[data-close]").forEach((b) => { b.onclick = () => b.closest("dialog").close(); });

  /* --- keyboard ---------------------------------------------------------- */
  addEventListener("keydown", (e) => {
    const typing = /^(INPUT|TEXTAREA)$/.test(document.activeElement.tagName) || document.querySelector("dialog[open]");
    if (e.key === "Escape" && S.stream) { S.stream.close(); S.stream = null; }
    if (typing) return;
    if (e.key === "/") { e.preventDefault(); go(S.selected, "search"); }
    if (/^[1-7]$/.test(e.key)) go(S.selected, TABS[Number(e.key) - 1].id);
    if (e.key === "[" || e.key === "]") {
      const ring = [null, ...S.agents];
      const i = ring.findIndex((a) => (a ? a.id : null) === (S.selected ? S.selected.id : null));
      const n = ring[(i + (e.key === "]" ? 1 : -1) + ring.length) % ring.length];
      go(n, S.tab);
    }
    if (e.key === "a" || e.key === "+") $("fab").click();
  });

  /* --- markdown ---------------------------------------------------------- */
  // Enough markdown for a note: headings, lists, code, emphasis, links.
  // The text is escaped first, and nothing after that is trusted.
  function markdown(src) {
    const lines = esc(src || "").replace(/\r/g, "").split("\n");
    let out = "", list = null, code = false, para = [];
    const flush = () => { if (para.length) { out += `<p>${inline(para.join(" "))}</p>`; para = []; } if (list) { out += `</${list}>`; list = null; } };
    for (const raw of lines) {
      const line = raw;
      if (line.startsWith("```")) { if (code) { out += "</code></pre>"; code = false; } else { flush(); out += "<pre><code>"; code = true; } continue; }
      if (code) { out += line + "\n"; continue; }
      let m;
      if ((m = line.match(/^(#{1,6})\s+(.*)/))) { flush(); out += `<h${Math.min(3, m[1].length)}>${inline(m[2])}</h${Math.min(3, m[1].length)}>`; }
      else if ((m = line.match(/^\s*[-*]\s+(.*)/))) { if (para.length) { out += `<p>${inline(para.join(" "))}</p>`; para = []; } if (list !== "ul") { if (list) out += `</${list}>`; out += "<ul>"; list = "ul"; } out += `<li>${inline(m[1])}</li>`; }
      else if ((m = line.match(/^\s*\d+[.)]\s+(.*)/))) { if (para.length) { out += `<p>${inline(para.join(" "))}</p>`; para = []; } if (list !== "ol") { if (list) out += `</${list}>`; out += "<ol>"; list = "ol"; } out += `<li>${inline(m[1])}</li>`; }
      else if ((m = line.match(/^&gt;\s?(.*)/))) { flush(); out += `<blockquote>${inline(m[1])}</blockquote>`; }
      else if (!line.trim()) { flush(); }
      else para.push(line);
    }
    if (code) out += "</code></pre>";
    flush();
    return out;
  }
  function inline(s) {
    return s
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
      .replace(/(^|\W)\*([^*]+)\*(?=\W|$)/g, "$1<i>$2</i>")
      .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>')
      .replace(/(^|\s)(https?:\/\/[^\s<]+)/g, '$1<a href="$2" target="_blank" rel="noopener">$2</a>');
  }

  boot();
})();

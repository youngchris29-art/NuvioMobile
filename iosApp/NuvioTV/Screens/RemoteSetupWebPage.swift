import Foundation

/// The single-page config UI served at `/` by `RemoteSetupServer`. Plain HTML+JS, no external
/// resources (works offline on the LAN). Edits are staged client-side; "Send to TV" POSTs the
/// whole desired state to `/api/apply`, then polls `/api/status/{id}` until the user confirms
/// or rejects the change on the TV.
enum RemoteSetupWebPage {
    static let html = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nuvio Remote Setup</title>
<style>
  :root {
    --bg: #0b0d12; --card: #161a22; --card2: #1d2330; --text: #f2f4f8; --dim: #8b93a5;
    --accent: #4f6bf0; --grad: linear-gradient(90deg, #2bd9e5, #4f6bf0, #a238f0);
    --danger: #e5484d; --ok: #30a46c;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--text);
    font: 16px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    padding-bottom: 96px;
  }
  header { padding: 20px 16px 4px; max-width: 720px; margin: 0 auto; }
  header h1 {
    margin: 0; font-size: 26px; font-weight: 800;
    background: var(--grad); -webkit-background-clip: text; background-clip: text; color: transparent;
  }
  header p { margin: 6px 0 0; color: var(--dim); font-size: 14px; }
  main { max-width: 720px; margin: 0 auto; padding: 8px 16px; }
  section { background: var(--card); border-radius: 14px; padding: 16px; margin-top: 16px; }
  h2 { margin: 0 0 4px; font-size: 18px; }
  .hint { color: var(--dim); font-size: 13px; margin: 0 0 12px; }
  .row {
    display: flex; align-items: center; gap: 10px; background: var(--card2);
    border-radius: 10px; padding: 10px 12px; margin-top: 8px;
  }
  .row .info { flex: 1; min-width: 0; }
  .row .name { font-weight: 600; font-size: 15px; }
  .row .sub {
    color: var(--dim); font-size: 12px; overflow: hidden;
    text-overflow: ellipsis; white-space: nowrap;
  }
  .row.disabled .name, .row.disabled .sub { opacity: 0.45; }
  button {
    border: 0; border-radius: 8px; background: #2a3245; color: var(--text);
    font-size: 14px; padding: 8px 10px; cursor: pointer; flex-shrink: 0;
  }
  button:active { opacity: 0.7; }
  button.icon { width: 36px; height: 36px; padding: 0; font-size: 16px; }
  button.danger { background: rgba(229, 72, 77, 0.18); color: var(--danger); }
  .addbar { display: flex; gap: 8px; margin-top: 12px; }
  input[type=text], input[type=password] {
    flex: 1; min-width: 0; background: var(--card2); border: 1px solid #2a3245;
    border-radius: 8px; color: var(--text); font-size: 15px; padding: 10px 12px;
  }
  input::placeholder { color: #5a6376; }
  .keyrow { display: flex; gap: 8px; align-items: center; margin-top: 8px; }
  .keyrow label { width: 88px; flex-shrink: 0; font-size: 14px; }
  .footer {
    position: fixed; left: 0; right: 0; bottom: 0; padding: 12px 16px;
    background: rgba(11, 13, 18, 0.92); backdrop-filter: blur(10px);
    border-top: 1px solid #232a3a;
  }
  .footer .inner { max-width: 720px; margin: 0 auto; display: flex; gap: 10px; align-items: center; }
  .apply {
    flex: 1; background: var(--grad); font-weight: 700; font-size: 16px; padding: 13px;
    border-radius: 10px; color: #fff;
  }
  .apply:disabled { filter: grayscale(0.7); opacity: 0.6; }
  #status { font-size: 13px; color: var(--dim); flex: 1; }
  #status.ok { color: var(--ok); }
  #status.err { color: var(--danger); }
  .toggle { position: relative; width: 44px; height: 26px; flex-shrink: 0; }
  .toggle input { display: none; }
  .toggle span {
    position: absolute; inset: 0; border-radius: 13px; background: #2a3245; transition: 0.15s;
  }
  .toggle span::after {
    content: ""; position: absolute; top: 3px; left: 3px; width: 20px; height: 20px;
    border-radius: 50%; background: #fff; transition: 0.15s;
  }
  .toggle input:checked + span { background: var(--accent); }
  .toggle input:checked + span::after { left: 21px; }
  .empty { color: var(--dim); font-size: 14px; padding: 8px 2px; }
  /* While the add-on list reloads, nothing on the page can be edited. */
  main.busy { pointer-events: none; opacity: 0.5; }
</style>
</head>
<body>
<header>
  <h1>Nuvio Remote Setup</h1>
  <p>Changes are staged here, then confirmed on your Apple&nbsp;TV.</p>
</header>
<main>
  <section>
    <h2>Add-ons</h2>
    <p class="hint">Paste a manifest URL to install. Reorder with the arrows; the first add-on's rows appear first on Home.</p>
    <div id="addons"></div>
    <div class="addbar">
      <input type="text" id="addon-url" placeholder="https://example.com/manifest.json" autocapitalize="off" autocorrect="off">
      <button onclick="addAddon()">Add</button>
    </div>
  </section>

  <section>
    <h2>Home Rows</h2>
    <p class="hint">Toggle rows on or off and reorder how they appear on the Home screen.</p>
    <div id="rows"></div>
  </section>

  <section>
    <h2>Stream Badge Packs</h2>
    <p class="hint">Badge packs add quality / HDR / audio chips to stream results. Paste a pack's JSON URL to import it on the TV. Remove packs on the TV under Settings &rarr; Appearance &rarr; Stream Badges.</p>
    <div id="badges"></div>
    <div class="addbar">
      <input type="text" id="badge-url" placeholder="https://example.com/badges.json" autocapitalize="off" autocorrect="off">
      <button onclick="addBadgeUrl()">Add</button>
    </div>
  </section>

  <section>
    <h2>API Keys</h2>
    <p class="hint">Optional. MDBList adds IMDb/RT/Metacritic ratings. Key is only sent when you enter one. TMDB enrichment (cast, studios, collections) needs no key &mdash; turn it on in Settings on the TV.</p>
    <div class="keyrow">
      <label>MDBList</label>
      <input type="password" id="mdblist-key" autocapitalize="off" autocorrect="off">
    </div>
  </section>

  <section>
    <h2>Custom Posters</h2>
    <p class="hint">Optional. Use a poster service such as RPDB for artwork. Placeholders like {id}, {type} and {shape} are replaced for each title. The pattern is only sent when you enter one.</p>
    <div class="keyrow">
      <label>Custom poster URL pattern</label>
      <input type="text" id="poster-pattern" placeholder="https://api.ratingposterdb.com/YOUR-KEY/imdb/poster-default/{id}.jpg" autocapitalize="off" autocorrect="off">
    </div>
  </section>
</main>
<div class="footer">
  <div class="inner">
    <div id="status">Loading&hellip;</div>
    <button class="apply" id="apply" onclick="apply()" disabled>Send to TV</button>
  </div>
</div>

<script>
// Installed add-ons come as {id, host, name, description, enabled}: a per-session id and the host,
// never the manifest URL (it can carry a debrid key). A new add-on is {url, enabled, isNew: true}.
let addons = [];
let addonBaseline = []; // the TV list's ids as loaded, sent back so the TV can tell it moved
let badgePacks = [];      // source URLs already imported on the TV (read-only here)
let stagedBadgeUrls = []; // pack URLs staged for import on Send
let rows = [];     // {key, title, enabled, isCollection}

const el = id => document.getElementById(id);
const esc = s => (s || "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

// Per-session pairing token from the QR/typed URL; the server requires it on every route.
const TOKEN = new URLSearchParams(location.search).get("t") || "";
const AUTH = { "X-Setup-Token": TOKEN };

function setStatus(text, cls) {
  const s = el("status");
  s.textContent = text;
  s.className = cls || "";
}

// `note`, when given, replaces the "Connected" line once the TV's list is on screen. With
// `addonsOnly`, the staged Home-row edits are kept and only the add-on list is replaced.
// A restarted Remote Setup session has a new pairing token, so this page's token now gets a 403
// on every route: say so and stop, rather than retrying or waiting forever.
function endPairing() {
  setStatus("This page's pairing has ended: Remote Setup was restarted on the TV. Scan the new code on the TV to pair again.", "err");
  el("apply").disabled = true;
  setLocked(false);
}

// true when loaded, false when the TV can't be reached, "ended" when the pairing has ended.
async function load(note, addonsOnly) {
  try {
    const res = await fetch("/api/state", { headers: AUTH });
    if (res.status === 403) { endPairing(); return "ended"; }
    const state = await res.json();
    addons = (state.addons || []).map(a => ({ ...a, isNew: false, origEnabled: a.enabled }));
    addonBaseline = addons.map(a => a.id);
    if (!addonsOnly) rows = state.rows || [];
    badgePacks = state.badgePacks || [];
    if (state.mdblistKeySet) el("mdblist-key").placeholder = "Saved on TV — enter to replace";
    if (state.posterPatternSet) el("poster-pattern").placeholder = "Saved on TV — enter to replace";
    render();
    if (note) setStatus(note, "err"); else setStatus("Connected to " + (state.deviceName || "Apple TV"), "ok");
    el("apply").disabled = false;
    return true;
  } catch (e) {
    setStatus("Couldn't reach the TV. Is Remote Setup still open?", "err");
    return false;
  }
}

function move(list, i, delta) {
  const j = i + delta;
  if (j < 0 || j >= list.length) return;
  [list[i], list[j]] = [list[j], list[i]];
  render();
}

function render() {
  el("addons").innerHTML = addons.length ? addons.map((a, i) => `
    <div class="row ${a.enabled ? "" : "disabled"}">
      <label class="toggle"><input type="checkbox" ${a.enabled ? "checked" : ""}
        onchange="addons[${i}].enabled = this.checked; render()"><span></span></label>
      <div class="info">
        <div class="name">${esc(a.name || "New add-on")}${a.isNew ? " (new)" : ""}</div>
        <div class="sub">${esc(a.isNew ? a.url : a.host)}</div>
      </div>
      <button class="icon" onclick="move(addons, ${i}, -1)">&#8593;</button>
      <button class="icon" onclick="move(addons, ${i}, 1)">&#8595;</button>
      <button class="icon danger" onclick="addons.splice(${i}, 1); render()">&#10005;</button>
    </div>`).join("") : `<div class="empty">No add-ons installed.</div>`;

  const badgeRows = badgePacks.map(u => `
    <div class="row">
      <div class="info">
        <div class="name">Imported</div>
        <div class="sub">${esc(u)}</div>
      </div>
    </div>`).concat(stagedBadgeUrls.map((u, i) => `
    <div class="row">
      <div class="info">
        <div class="name">New pack (on Send)</div>
        <div class="sub">${esc(u)}</div>
      </div>
      <button class="icon danger" onclick="stagedBadgeUrls.splice(${i}, 1); render()">&#10005;</button>
    </div>`));
  el("badges").innerHTML = badgeRows.length ? badgeRows.join("") : `<div class="empty">No badge packs imported.</div>`;

  el("rows").innerHTML = rows.length ? rows.map((r, i) => `
    <div class="row ${r.enabled ? "" : "disabled"}">
      <label class="toggle"><input type="checkbox" ${r.enabled ? "checked" : ""}
        onchange="rows[${i}].enabled = this.checked; render()"><span></span></label>
      <div class="info">
        <div class="name">${esc(r.title)}</div>
        <div class="sub">${r.isCollection ? "Collection" : "Catalog row"}</div>
      </div>
      <button class="icon" onclick="move(rows, ${i}, -1)">&#8593;</button>
      <button class="icon" onclick="move(rows, ${i}, 1)">&#8595;</button>
    </div>`).join("") : `<div class="empty">Rows appear after add-ons load.</div>`;
}

function addBadgeUrl() {
  const input = el("badge-url");
  const url = input.value.trim();
  if (!url) return;
  if (stagedBadgeUrls.includes(url) || badgePacks.includes(url)) {
    setStatus("That badge pack is already in the list.", "err");
    return;
  }
  stagedBadgeUrls.push(url);
  input.value = "";
  render();
}

function addAddon() {
  const input = el("addon-url");
  const url = input.value.trim();
  if (!url) return;
  // Installed add-ons are known only by host here, so the TV checks a new address against its
  // list and refuses the change (keeping these edits) when that add-on is already installed.
  if (addons.some(a => a.isNew && a.url === url)) { setStatus("That add-on is already in the list.", "err"); return; }
  addons.push({ url, name: "", description: "", enabled: true, isNew: true });
  input.value = "";
  render();
}

// Reloads the TV's state with the page locked (`inert` also blocks keyboard input) and Send off
// until it is on screen, retrying while the TV can't be reached, so no edit is made or sent
// against a list or baseline the TV has moved past.
async function reloadLocked(note, addonsOnly, delayMs) {
  el("apply").disabled = true;
  setLocked(true);
  if (delayMs) await new Promise(r => setTimeout(r, delayMs));
  let loaded;
  while ((loaded = await load(note, addonsOnly)) === false) {
    setStatus("Couldn't reach the TV to reload its list. Trying again… (is Remote Setup still open?)", "err");
    await new Promise(r => setTimeout(r, 3000));
  }
  if (loaded === true) setLocked(false);
}

function setLocked(locked) {
  const main = document.querySelector("main");
  main.classList.toggle("busy", locked);
  main.inert = locked;
}

async function apply() {
  const btn = el("apply");
  btn.disabled = true;
  // Locked until the outcome is handled: an edit made against the sent snapshot could be lost
  // when a stale outcome replaces the add-on list.
  setLocked(true);
  setStatus("Waiting for confirmation on the TV…");
  const payload = {
    rowOrder: rows.map(r => r.key),
    disabledRowKeys: rows.filter(r => !r.enabled).map(r => r.key)
  };
  // The add-on list goes only when it was edited, and an installed add-on's flag only when the
  // user changed it, so a change elsewhere never rewrites add-on state the TV has since updated.
  const addonsEdited = addons.length !== addonBaseline.length ||
    addons.some((a, i) => a.isNew || a.id !== addonBaseline[i] || a.enabled !== a.origEnabled);
  if (addonsEdited) {
    payload.addons = addons.map(a => a.isNew ? { url: a.url, enabled: a.enabled }
      : (a.enabled !== a.origEnabled ? { id: a.id, enabled: a.enabled } : { id: a.id }));
    payload.addonBaseline = addonBaseline;
  }
  const mdbl = el("mdblist-key").value.trim();
  if (mdbl) payload.mdblistKey = mdbl;
  const posterPattern = el("poster-pattern").value.trim();
  if (posterPattern) payload.posterPattern = posterPattern;
  if (stagedBadgeUrls.length) payload.badgeUrls = stagedBadgeUrls.slice();

  try {
    const res = await fetch("/api/apply", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...AUTH },
      body: JSON.stringify(payload)
    });
    if (res.status === 403) { endPairing(); return; }
    const { id, error } = await res.json();
    if (error || !id) throw new Error(error || "bad response");
    poll(id, 0);
  } catch (e) {
    setStatus("Couldn't send changes to the TV.", "err");
    btn.disabled = false; setLocked(false);
  }
}

async function poll(id, tries) {
  // The TV can still apply this change, so the page stays locked and keeps asking until it
  // settles (a TV that restarted its session answers not_found and the page reloads).
  if (tries === 120) setStatus("Still waiting for the TV. Confirm or decline the change there.", "err");
  try {
    const res = await fetch("/api/status/" + id, { headers: AUTH });
    if (res.status === 403) { endPairing(); return; }
    const { status } = await res.json();
    if (status === "confirmed") {
      setStatus("Applied on the TV ✓", "ok");
      el("mdblist-key").value = "";
      el("poster-pattern").value = "";
      stagedBadgeUrls = [];
      // Give the TV a moment to publish the applied state, then take it as the new baseline.
      await reloadLocked("Applied on the TV ✓", false, 1500);
      el("status").className = "ok";
      return;
    }
    if (status === "not_found") {
      // The TV no longer holds this change's outcome (a long disconnect, or many later changes):
      // it may or may not have been applied, so show the TV's state as it is now.
      await reloadLocked("The TV no longer knows how this change ended. This is its current state, so check it before sending again.", false, 0);
      return;
    }
    if (status === "stale") {
      // The add-on ids belong to the list this page loaded, and the TV's list has changed since
      // (or the TV restarted the session): only a fresh copy can be edited.
      // Reload straight away, with Apply held until the fresh list is on screen, so nothing the
      // user edits next is replaced by the reload.
      // Only the add-on list is replaced; the page is locked until it is on screen.
      setStatus("Not applied: the TV's add-on list changed. Reloading it…", "err");
      await reloadLocked("Not applied: the TV's add-on list changed. This is its list now, so make your add-on changes again. Your other changes are still here.", true, 0);
      return;
    }
    if (status === "read_only") {
      setStatus("Not applied: this TV profile uses another profile's add-ons, so add-ons can only be changed from that profile. Your other changes are still here.", "err");
      el("apply").disabled = false; setLocked(false);
      return;
    }
    if (status === "invalid") {
      setStatus("Not applied: a new add-on address isn't valid, or that add-on is already installed. Your other changes are still here.", "err");
      el("apply").disabled = false; setLocked(false);
      return;
    }
    if (status === "superseded") {
      setStatus("Not applied: a newer change reached the TV first. Your changes are still here.", "err");
      el("apply").disabled = false; setLocked(false);
      return;
    }
    if (status === "rejected") {
      setStatus("Declined on the TV. Your changes are still here.", "err");
      el("apply").disabled = false; setLocked(false);
      return;
    }
  } catch (e) { /* transient; keep polling */ }
  setTimeout(() => poll(id, tries + 1), 1000);
}

load();
</script>
</body>
</html>
"""#
}

const OFFSCREEN_URL = "offscreen.html";
const PCLOUD_HOST_RE = /(^|\.)pcloud\.(com|link)$/i;
const PCLOUD_UI_HOST_RE = /^(my|e|www)\.pcloud\.com$/i;
const PCLOUD_CDN_HOST_RE = /^p[a-z0-9]+\.pcloud\.com$/i;
const FINALIZE_FALLBACK_MS = 1500;
const CAPTURE_DEDUP_MS = 10000;
const MAX_CAPTURES = 200;
const MAX_REST_LOGS = 100;
const LOCAL_LOG_URL = "http://127.0.0.1:18765/log";

/** @type {Map<number, { url: string, filename: string|null, referrer: string|null, timer: ReturnType<typeof setTimeout>|null, done: boolean }>} */
const pending = new Map();
/** @type {Map<string, number>} */
const recentCaptureKeys = new Map();
/** @type {Set<number>} */
const closingCdnTabIds = new Set();

function isPcloudUrl(url) {
  if (!url || url.startsWith("blob:")) return false;
  try {
    return PCLOUD_HOST_RE.test(new URL(url).hostname);
  } catch {
    return false;
  }
}

function isPcloudUiUrl(url) {
  if (!url) return false;
  try {
    return PCLOUD_UI_HOST_RE.test(new URL(url).hostname);
  } catch {
    return false;
  }
}

/** CDN / signed file links (often opened as a new tab instead of a download). */
function isPcloudCdnFileUrl(url) {
  if (!isPcloudUrl(url)) return false;
  try {
    const u = new URL(url);
    const host = u.hostname.toLowerCase();
    if (PCLOUD_UI_HOST_RE.test(host)) return false;
    if (/^(api|eapi|apinyc\d*|apieu|api[a-z0-9]+)\.pcloud\.com$/i.test(host)) {
      return false;
    }
    const name = filenameFromUrl(url);
    if (!name || !/\.[a-z0-9]{2,8}$/i.test(name)) return false;
    return PCLOUD_CDN_HOST_RE.test(host) || /\.pcloud\.link$/i.test(host);
  } catch {
    return false;
  }
}

function isPcloudDownload(item) {
  return isPcloudUrl(item.finalUrl || item.url) || isPcloudUrl(item.url);
}

function captureKey(url) {
  try {
    const u = new URL(url);
    return `${u.origin}${u.pathname}`;
  } catch {
    return String(url || "");
  }
}

function claimCapture(url) {
  const key = captureKey(url);
  if (!key) return false;
  const now = Date.now();
  for (const [k, at] of recentCaptureKeys) {
    if (now - at > CAPTURE_DEDUP_MS) recentCaptureKeys.delete(k);
  }
  const prev = recentCaptureKeys.get(key);
  if (prev && now - prev < CAPTURE_DEDUP_MS) return false;
  recentCaptureKeys.set(key, now);
  return true;
}

async function cancelDownloadQuiet(downloadId) {
  if (downloadId == null) return;
  try {
    await chrome.downloads.cancel(downloadId);
  } catch {
    // already finished or gone
  }
  try {
    await chrome.downloads.erase({ id: downloadId });
  } catch {
    // ignore
  }
}

async function closeMatchingCdnTabs(url) {
  const key = captureKey(url);
  if (!key) return;
  let tabs = [];
  try {
    tabs = await chrome.tabs.query({});
  } catch {
    return;
  }
  for (const tab of tabs) {
    if (tab.id == null || !tab.url) continue;
    if (captureKey(tab.url) !== key) continue;
    closingCdnTabIds.add(tab.id);
    try {
      await chrome.tabs.remove(tab.id);
    } catch {
      // ignore
    } finally {
      closingCdnTabIds.delete(tab.id);
    }
  }
}

function baseName(pathOrName) {
  if (!pathOrName) return null;
  const trimmed = String(pathOrName).trim().replace(/[\\/]+$/, "");
  if (!trimmed) return null;
  const parts = trimmed.split(/[/\\]/);
  const name = parts[parts.length - 1];
  return name || null;
}

function filenameFromUrl(url) {
  try {
    const path = new URL(url).pathname;
    const name = baseName(decodeURIComponent(path));
    if (!name || name === "/" || !name.includes(".")) return null;
    return name;
  } catch {
    return null;
  }
}

async function ensureOffscreen() {
  const contexts = await chrome.runtime.getContexts({
    contextTypes: ["OFFSCREEN_DOCUMENT"],
    documentUrls: [chrome.runtime.getURL(OFFSCREEN_URL)],
  });
  if (contexts.length > 0) return;

  await chrome.offscreen.createDocument({
    url: OFFSCREEN_URL,
    reasons: ["CLIPBOARD"],
    justification: "Copy cancelled pCloud download URL and filename to the clipboard",
  });
}

async function copyToClipboard(text) {
  await ensureOffscreen();
  await chrome.runtime.sendMessage({ type: "copy-to-clipboard", text });
}

async function loadLanConfig() {
  const url = chrome.runtime.getURL("lan_config.json");
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) {
    throw new Error(`lan_config.json HTTP ${res.status}`);
  }
  const raw = (await res.text()).replace(/^\uFEFF/, "").trim();
  if (!raw) throw new Error("lan_config.json is empty");
  const cfg = JSON.parse(raw);
  const phoneLanHost = String(cfg.phoneLanHost || "").trim();
  if (!phoneLanHost) throw new Error("phoneLanHost missing in lan_config.json");
  return {
    phoneLanHost,
    lanPort: Number(cfg.lanPort) > 0 ? Number(cfg.lanPort) : 8765,
    webdavUser: String(cfg.webdavUser || "admin"),
    webdavPassword: String(cfg.webdavPassword || "iosadmin"),
  };
}

function lanBaseUrl(cfg) {
  return `http://${cfg.phoneLanHost}:${cfg.lanPort}`;
}

function basicAuthHeader(user, password) {
  const token = btoa(`${user}:${password}`);
  return `Basic ${token}`;
}

function parseFolderIdFromText(text) {
  if (!text) return null;
  const m = String(text).match(/[?&#]folder=(\d+)/i) || String(text).match(/folder=(\d+)/i);
  return m ? m[1] : null;
}

function isSearchResultsUrl(url) {
  if (!url) return false;
  return (
    /[?&#]q=/i.test(url) ||
    (/filter=/i.test(url) && /folderid=0/i.test(url))
  );
}

function isGarbledFolderPath(path, folderId, tabUrl) {
  if (isSearchResultsUrl(tabUrl) && !folderId) return true;
  if (!path) return false;
  if (/["']/.test(path)) return true;
  if (/All Files/i.test(path)) return true;
  if (/\bin\b/i.test(path) && /\//.test(path)) return true;
  const parts = String(path)
    .split("/")
    .map((p) => p.trim())
    .filter(Boolean);
  if (parts.some((p) => p.length <= 1 || /^["'.]+$/.test(p))) return true;
  if (parts.some((p) => /\s+in\s+/i.test(p))) return true;
  return false;
}

/**
 * Injected (MAIN world): right-click the file row → Open Location, wait for folder=.
 */
async function openLocationForFileName(fileName) {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const startHref = location.href;

  const normalize = (s) =>
    String(s || "")
      .replace(/\u00a0/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .toLowerCase();

  const needle = normalize(fileName);
  if (!needle) return { ok: false, error: "empty fileName" };
  const stem = needle.replace(/\.[a-z0-9]{1,5}$/i, "");
  const tokens = stem
    .split(/[^a-z0-9]+/i)
    .map((t) => t.toLowerCase())
    .filter((t) => t.length >= 4);
  const prefixes = [needle, stem];
  if (stem.length > 16) prefixes.push(stem.slice(0, 16), stem.slice(0, 24));

  const labelOf = (el) =>
    normalize(
      el.getAttribute("title") ||
        el.getAttribute("aria-label") ||
        el.getAttribute("data-name") ||
        el.getAttribute("data-filename") ||
        el.textContent
    );

  const scoreLabel = (label) => {
    if (!label) return -1;
    if (label === needle || label === stem) return 1000;
    if (label.includes(needle) || needle.includes(label)) return 800 - Math.abs(label.length - needle.length);
    if (label.includes(stem) || stem.includes(label)) return 700 - Math.abs(label.length - stem.length);
    for (const p of prefixes) {
      if (p && (label.startsWith(p) || p.startsWith(label))) return 600;
      if (p && label.includes(p)) return 500;
    }
    if (tokens.length) {
      const hit = tokens.filter((t) => label.includes(t)).length;
      if (hit >= Math.min(2, tokens.length)) return 300 + hit * 20;
      if (hit === 1 && tokens[0].length >= 6) return 200;
    }
    return -1;
  };

  const nodes = [
    ...document.querySelectorAll(
      '[title], [aria-label], [data-name], [data-filename], a, span, div, tr, li, button, [role="row"], [role="listitem"], [class*="file" i], [class*="item" i], [class*="name" i]'
    ),
  ];

  let target = null;
  let bestScore = -1;
  const samples = [];
  for (const el of nodes) {
    const label = labelOf(el);
    if (!label || label.length < 3 || label.length > 300) continue;
    const score = scoreLabel(label);
    if (score < 0) continue;
    if (samples.length < 8) samples.push(label.slice(0, 80));
    // Prefer smaller leaf nodes with higher score
    const sizePenalty = Math.min(el.querySelectorAll("*").length || 0, 50);
    const adjusted = score * 10 - sizePenalty - label.length;
    if (adjusted > bestScore) {
      bestScore = adjusted;
      target = el;
    }
  }

  // Fallback: selected / focused row in search results.
  if (!target) {
    target =
      document.querySelector('[aria-selected="true"], .selected, [class*="selected" i], [class*="active" i][class*="item" i]') ||
      null;
  }

  if (!target) {
    return {
      ok: false,
      error: "file row not found",
      fileName,
      samples,
      href: location.href,
    };
  }

  const row =
    target.closest(
      '[role="row"], [role="listitem"], tr, li, [class*="row" i], [class*="item" i], [class*="file" i]'
    ) || target;
  row.scrollIntoView({ block: "center", inline: "nearest" });
  await sleep(200);

  // Try left-click select first (search UIs often need selection before context menu).
  const rect = row.getBoundingClientRect();
  const x = Math.max(5, rect.left + Math.min(Math.max(rect.width / 3, 24), 80));
  const y = Math.max(5, rect.top + rect.height / 2);
  const left = {
    bubbles: true,
    cancelable: true,
    view: window,
    clientX: x,
    clientY: y,
    button: 0,
    buttons: 1,
  };
  row.dispatchEvent(new MouseEvent("mousedown", left));
  row.dispatchEvent(new MouseEvent("mouseup", left));
  row.dispatchEvent(new MouseEvent("click", left));
  await sleep(200);

  const right = {
    bubbles: true,
    cancelable: true,
    view: window,
    clientX: x,
    clientY: y,
    button: 2,
    buttons: 2,
  };
  row.dispatchEvent(new MouseEvent("mousedown", right));
  row.dispatchEvent(new MouseEvent("mouseup", right));
  row.dispatchEvent(new MouseEvent("contextmenu", right));
  await sleep(500);

  const menuText = (el) => normalize(el.textContent);
  const menuItems = [
    ...document.querySelectorAll(
      '[role="menuitem"], [class*="context" i] *, [class*="menu" i] li, [class*="Menu"] button, [class*="menu" i] button, [class*="menu" i] span, [class*="menu" i] div, [class*="dropdown" i] *'
    ),
  ];
  const openLoc = menuItems.find((el) => {
    const t = menuText(el);
    return (
      /open\s*location/.test(t) ||
      /show\s*(in\s*)?(enclosing\s*)?folder/.test(t) ||
      /show\s*location/.test(t) ||
      /go\s*to\s*folder/.test(t) ||
      /view\s*location/.test(t) ||
      /^location$/.test(t)
    );
  });
  if (!openLoc) {
    return {
      ok: false,
      error: "Open Location menu item not found",
      matchedLabel: labelOf(target).slice(0, 120),
      menuSample: menuItems
        .map((el) => (el.textContent || "").trim())
        .filter(Boolean)
        .slice(0, 16),
      href: location.href,
    };
  }
  openLoc.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
  openLoc.click();

  for (let i = 0; i < 48; i++) {
    await sleep(250);
    const href = location.href;
    const folderMatch =
      href.match(/[?&#]folder=(\d+)/i) || href.match(/folder=(\d+)/i);
    const leftSearch = !/[?&#]q=/i.test(href);
    if (folderMatch && leftSearch) {
      return {
        ok: true,
        folderId: folderMatch[1],
        href,
        method: "open_location",
        matchedLabel: labelOf(target).slice(0, 120),
      };
    }
  }
  return {
    ok: false,
    error: "timed out waiting for folder navigation",
    href: location.href,
    matchedLabel: labelOf(target).slice(0, 120),
  };
}

/** Injected into my.pcloud.com (MAIN world) to read folder id + session auth. */
function extractPcloudFolderFromPage() {
  const blob = `${location.href}\n${location.hash}\n${location.search}`;
  const folderMatch =
    blob.match(/[?&#]folder=(\d+)/i) || blob.match(/folder=(\d+)/i);
  const folderId = folderMatch ? folderMatch[1] : null;

  let path = null;
  let name = null;
  const crumbRoots = [];
  const selectors = [
    "[class*='breadcrumb' i]",
    "[class*='Breadcrumb']",
    "nav[aria-label*='breadcrumb' i]",
    "[data-testid*='breadcrumb' i]",
  ];
  for (const sel of selectors) {
    document.querySelectorAll(sel).forEach((el) => crumbRoots.push(el));
  }
  for (const root of crumbRoots) {
    const parts = [...root.querySelectorAll("a, span, button")]
      .map((el) => (el.textContent || "").trim())
      .filter((t) => t && t !== "/" && t.toLowerCase() !== "home");
    if (parts.length) {
      path = "/" + parts.join("/");
      name = parts[parts.length - 1];
      break;
    }
  }

  let auth = null;
  let apiHost = null;
  const consider = (key, value) => {
    if (!value || typeof value !== "string") return;
    const detected = detectApiHostFromText(value);
    if (detected) apiHost = apiHost || detected;
    if (/eapi|europe|locationid['\"]?\s*[:=]\s*2/i.test(value)) {
      apiHost = apiHost || "eapi.pcloud.com";
    }
    if (/^(auth|pcauth|access_token|token)$/i.test(key) && value.length >= 16) {
      auth = value.replace(/^"|"$/g, "");
      return;
    }
    try {
      const j = JSON.parse(value);
      if (!j || typeof j !== "object") return;
      const candidate =
        j.auth || j.pcauth || j.token || j.access_token || j.authToken;
      if (typeof candidate === "string" && candidate.length >= 16) auth = candidate;
      if (j.locationid === 2 || j.locationId === 2) apiHost = "eapi.pcloud.com";
      const hostCand =
        j.apihost || j.apiHost || j.hostname || j.host || j.api_server;
      if (typeof hostCand === "string") {
        apiHost = detectApiHostFromText(hostCand) || apiHost;
      }
    } catch {
      // not JSON
    }
  };

  for (const store of [localStorage, sessionStorage]) {
    for (let i = 0; i < store.length; i++) {
      const key = store.key(i);
      consider(key, store.getItem(key));
    }
  }

  // Performance entries often include apinyc*.pcloud.com listfolder calls.
  try {
    for (const entry of performance.getEntriesByType("resource")) {
      const detected = detectApiHostFromText(entry.name || "");
      if (detected) {
        apiHost = detected;
        break;
      }
    }
  } catch {
    // ignore
  }

  const cookieAuth = document.cookie.match(
    /(?:^|;\s*)(?:pcauth|auth)=([^;]+)/i
  );
  if (cookieAuth) auth = decodeURIComponent(cookieAuth[1]);

  return {
    folderId,
    path,
    name,
    auth,
    apiHost,
    href: location.href,
  };
}

/**
 * CDN download host → API host, e.g. pnyc1.pcloud.com → apinyc1.pcloud.com
 */
function apiHostFromCdnUrl(urlOrHost) {
  if (!urlOrHost) return null;
  let host = String(urlOrHost).trim().toLowerCase();
  try {
    if (/^https?:\/\//i.test(host)) host = new URL(host).hostname;
  } catch {
    // already a hostname-ish string
  }
  host = host.replace(/^www\./, "");
  // pnyc1.pcloud.com → apinyc1.pcloud.com
  let m = host.match(/^p([a-z0-9]+)\.pcloud\.com$/i);
  if (m) return `api${m[1]}.pcloud.com`;
  // already an API edge host
  if (/^(?:api|eapi|apinyc\d*|apieu|api[a-z0-9]+)\.pcloud\.com$/i.test(host)) {
    return host;
  }
  return null;
}

function pcloudApiHosts(preferredHost, cdnUrl) {
  const hosts = [];
  const fromCdn = apiHostFromCdnUrl(cdnUrl);
  if (fromCdn) hosts.push(fromCdn);
  if (preferredHost) {
    hosts.push(String(preferredHost).replace(/^https?:\/\//i, "").toLowerCase());
  }
  // Fallbacks only — prefer CDN-derived / discovered host.
  hosts.push(
    "apinyc1.pcloud.com",
    "apinyc0.pcloud.com",
    "api.pcloud.com",
    "eapi.pcloud.com",
    "apieu.pcloud.com"
  );
  return [...new Set(hosts.filter(Boolean))];
}

function detectApiHostFromText(text) {
  if (!text) return null;
  const m = String(text).match(
    /\b((?:api|eapi|apinyc\d*|apieu|api[a-z0-9]+)\.pcloud\.com)\b/i
  );
  return m ? m[1].toLowerCase() : null;
}

async function readAuthCandidatesFromCookies() {
  const urls = [
    "https://my.pcloud.com",
    "https://e.pcloud.com",
    "https://api.pcloud.com",
    "https://eapi.pcloud.com",
    "https://apinyc1.pcloud.com",
  ];
  const all = [];
  for (const url of urls) {
    try {
      all.push(...(await chrome.cookies.getAll({ url })));
    } catch {
      // ignore
    }
  }
  try {
    all.push(...(await chrome.cookies.getAll({ domain: "pcloud.com" })));
  } catch {
    // ignore
  }

  const seen = new Set();
  const candidates = [];
  for (const c of all) {
    if (!c?.value || c.value.length < 16) continue;
    const key = `${c.name}|${c.value.slice(0, 12)}`;
    if (seen.has(key)) continue;
    seen.add(key);
    candidates.push({
      name: c.name,
      auth: c.value,
      domain: c.domain,
      apiHost: /e\.pcloud|eapi/i.test(c.domain || "")
        ? "eapi.pcloud.com"
        : null,
    });
  }

  // Prefer likely auth cookie names first.
  candidates.sort((a, b) => {
    const score = (n) =>
      /^(pcauth|auth|token|access_token)$/i.test(n) ? 0 : 1;
    return score(a.name) - score(b.name);
  });
  return candidates;
}

async function pcloudApiFolderMeta(folderId, auth, preferredHost, cdnUrl) {
  const uniqueHosts = pcloudApiHosts(preferredHost, cdnUrl);
  const errors = [];

  for (const host of uniqueHosts) {
    try {
      const listUrl =
        `https://${host}/listfolder?folderid=${encodeURIComponent(folderId)}` +
        `&recursive=0&iconformat=id&auth=${encodeURIComponent(auth)}`;
      const listRes = await fetch(listUrl);
      const listJson = await listRes.json();
      if (listJson && listJson.result === 0 && listJson.metadata) {
        const meta = listJson.metadata;
        let path = typeof meta.path === "string" ? meta.path : null;
        const name = typeof meta.name === "string" ? meta.name : null;
        if (!path) {
          path = await buildPathFromParents(folderId, auth, host, name);
        }
        return {
          path,
          name,
          host,
          method: "listfolder",
        };
      }
      errors.push(`${host}/listfolder result=${listJson?.result}`);
    } catch (err) {
      errors.push(`${host}/listfolder ${err}`);
    }

    try {
      const pathUrl = `https://${host}/getpath?folderid=${encodeURIComponent(
        folderId
      )}&auth=${encodeURIComponent(auth)}`;
      const pathRes = await fetch(pathUrl);
      const pathJson = await pathRes.json();
      if (pathJson && pathJson.result === 0 && typeof pathJson.path === "string") {
        const path = pathJson.path;
        const name = baseName(path) || path;
        return { path, name, host, method: "getpath" };
      }
      errors.push(`${host}/getpath result=${pathJson?.result}`);
    } catch (err) {
      errors.push(`${host}/getpath ${err}`);
    }
  }
  return { error: errors.slice(0, 8).join("; ") };
}

/** Walk parentfolderid chain when listfolder metadata omits `path`. */
async function buildPathFromParents(folderId, auth, host, leafName) {
  const parts = [];
  if (leafName && leafName !== "/") parts.push(leafName);
  let currentId = folderId;
  for (let depth = 0; depth < 32; depth++) {
    try {
      const url =
        `https://${host}/listfolder?folderid=${encodeURIComponent(currentId)}` +
        `&recursive=0&auth=${encodeURIComponent(auth)}`;
      const res = await fetch(url);
      const json = await res.json();
      if (!json || json.result !== 0 || !json.metadata) break;
      const meta = json.metadata;
      const parentId = meta.parentfolderid;
      if (parentId == null || Number(parentId) === 0) break;
      const parentUrl =
        `https://${host}/listfolder?folderid=${encodeURIComponent(parentId)}` +
        `&recursive=0&auth=${encodeURIComponent(auth)}`;
      const parentRes = await fetch(parentUrl);
      const parentJson = await parentRes.json();
      if (!parentJson || parentJson.result !== 0 || !parentJson.metadata) break;
      const parentName = parentJson.metadata.name;
      if (parentName && parentName !== "/") parts.unshift(parentName);
      currentId = parentId;
      if (Number(parentJson.metadata.parentfolderid) === 0) break;
    } catch {
      break;
    }
  }
  if (!parts.length) return null;
  return "/" + parts.join("/");
}

async function loadTrackedFolderContext() {
  try {
    const session = await chrome.storage.session.get("pcloudFolderContext");
    if (session.pcloudFolderContext) return session.pcloudFolderContext;
  } catch {
    // ignore
  }
  try {
    const local = await chrome.storage.local.get("pcloudFolderContext");
    return local.pcloudFolderContext || null;
  } catch {
    return null;
  }
}

async function resolvePcloudFolderContext(downloadItem) {
  const tracked = await loadTrackedFolderContext();
  const fromReferrer = parseFolderIdFromText(downloadItem?.referrer);
  const cdnUrl = downloadItem?.cdnUrl || downloadItem?.url || null;
  const cdnApiHost = apiHostFromCdnUrl(cdnUrl);
  let folderId =
    tracked?.folderId || fromReferrer || null;
  let path = tracked?.folderPath || null;
  let name = tracked?.folderName || null;
  let auth = tracked?.auth || null;
  let apiHost = cdnApiHost || tracked?.apiHost || null;
  let tabUrl = tracked?.href || downloadItem?.referrer || null;
  let source = tracked?.folderId ? "tracker" : fromReferrer ? "referrer" : null;
  const cookieNames = [];

  if (
    tracked?.isSearch ||
    isGarbledFolderPath(path, folderId, tabUrl)
  ) {
    path = null;
    name = null;
    if (tracked?.isSearch || isSearchResultsUrl(tabUrl)) {
      folderId = null;
      source = null;
    }
  }

  const tabs = await chrome.tabs.query({});
  const pcloudTabs = tabs
    .filter((t) => {
      try {
        // Only my/e UI — never treat CDN file tabs as folder context.
        return t.url && isPcloudUiUrl(t.url);
      } catch {
        return false;
      }
    })
    .sort((a, b) => Number(b.active) - Number(a.active));

  for (const tab of pcloudTabs) {
    tabUrl = tab.url || tabUrl;
    const searching = isSearchResultsUrl(tab.url);
    const idFromTab = parseFolderIdFromText(tab.url);
    if (idFromTab && !searching) {
      folderId = idFromTab;
      source = "tab_url";
    }

    try {
      const injected = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        world: "MAIN",
        func: extractPcloudFolderFromPage,
      });
      const page = injected?.[0]?.result;
      if (!page) continue;
      if (page.folderId && !searching) {
        folderId = page.folderId;
        source = "page_hash";
      }
      // Never take breadcrumb text from search results (garbled "x" in "/All Files/").
      if (!searching) {
        if (page.path && !isGarbledFolderPath(page.path, page.folderId, tab.url)) {
          path = page.path;
        }
        if (page.name && page.name !== '"') name = page.name;
      }
      if (page.auth) auth = page.auth;
      if (page.apiHost) apiHost = page.apiHost;
    } catch {
      // tab may be restricted
    }
  }

  const cookieCandidates = await readAuthCandidatesFromCookies();
  for (const c of cookieCandidates) cookieNames.push(c.name);
  if (!auth && cookieCandidates.length) {
    auth = cookieCandidates[0].auth;
    apiHost = apiHost || cookieCandidates[0].apiHost;
  }

  let apiError = null;
  if (folderId) {
    const authsToTry = [];
    if (auth) authsToTry.push({ auth, apiHost, name: "primary" });
    for (const c of cookieCandidates) {
      if (auth && c.auth === auth) continue;
      authsToTry.push({
        auth: c.auth,
        apiHost: c.apiHost || apiHost,
        name: c.name,
      });
    }

    for (const candidate of authsToTry.slice(0, 6)) {
      const meta = await pcloudApiFolderMeta(
        folderId,
        candidate.auth,
        candidate.apiHost || apiHost,
        cdnUrl
      );
      if (meta && !meta.error) {
        path = meta.path || path;
        name = meta.name || name;
        source = meta.method;
        apiHost = meta.host || apiHost;
        apiError = null;
        break;
      }
      apiError = meta?.error || apiError;
    }
  }

  if (path && !name) name = baseName(path);
  if (name === "/") name = null;

  return {
    folderId: folderId || null,
    folderPath: path || null,
    folderName: name || null,
    source: source || null,
    tabUrl: tabUrl || null,
    apiHost: apiHost || null,
    cdnUrl: cdnUrl || null,
    cdnApiHost: cdnApiHost || null,
    hasAuth: Boolean(auth),
    cookieNames: [...new Set(cookieNames)].slice(0, 20),
    apiError: apiError || null,
    auth: auth || null,
  };
}

async function findPcloudTabId() {
  const tabs = await chrome.tabs.query({});
  const pcloudTabs = tabs
    .filter((t) => {
      try {
        // Only my/e UI — never treat CDN file tabs as folder context.
        return t.url && isPcloudUiUrl(t.url);
      } catch {
        return false;
      }
    })
    .sort((a, b) => Number(b.active) - Number(a.active));
  return pcloudTabs[0]?.id ?? null;
}

async function repairFolderViaOpenLocation(fileName) {
  const tabId = await findPcloudTabId();
  if (tabId == null) {
    return { ok: false, error: "no pCloud tab" };
  }

  let result;
  try {
    const injected = await chrome.scripting.executeScript({
      target: { tabId },
      world: "MAIN",
      func: openLocationForFileName,
      args: [fileName],
    });
    result = injected?.[0]?.result || { ok: false, error: "empty inject result" };
  } catch (err) {
    return {
      ok: false,
      error: String(err && err.message ? err.message : err),
    };
  }

  await appendRestLog({
    phase: "open_location",
    ok: Boolean(result?.ok),
    fileName,
    ...result,
  });

  if (!result?.ok) return result;

  // Give the SPA a moment, then re-resolve from the new folder=.
  await new Promise((r) => setTimeout(r, 500));
  const repaired = await resolvePcloudFolderContext({});
  return {
    ok: Boolean(repaired.folderPath || repaired.folderId),
    method: "open_location",
    folder: repaired,
  };
}

function extractSearchEntries(json) {
  const entries = [];
  const pushRows = (rows) => {
    if (!Array.isArray(rows)) return;
    for (const row of rows) {
      if (row && typeof row === "object") entries.push(row);
    }
  };
  for (const key of ["items", "matches", "results", "entries", "files", "file"]) {
    if (Array.isArray(json[key])) pushRows(json[key]);
    else if (json[key] && typeof json[key] === "object") entries.push(json[key]);
  }
  if (Array.isArray(json.metadata)) pushRows(json.metadata);
  else if (json.metadata && typeof json.metadata === "object") {
    if (Array.isArray(json.metadata.contents)) pushRows(json.metadata.contents);
    else entries.push(json.metadata);
  }
  // Deep-ish fallback: first array-of-objects that looks like metadata.
  if (!entries.length) {
    for (const value of Object.values(json)) {
      if (!Array.isArray(value) || !value.length) continue;
      if (value.every((v) => v && typeof v === "object" && (v.name || v.fileid || v.path))) {
        pushRows(value);
        break;
      }
    }
  }
  return entries;
}

function parentPathFromFileEntry(entry) {
  const name = String(entry.name || "");
  let path = typeof entry.path === "string" ? entry.path : null;
  if (path && name) {
    const suffix = "/" + name;
    if (path.toLowerCase().endsWith(suffix.toLowerCase())) {
      path = path.slice(0, -suffix.length) || "/";
    } else if (!entry.isfolder) {
      const idx = path.lastIndexOf("/");
      if (idx > 0) path = path.slice(0, idx);
    }
  } else if (path && !entry.isfolder) {
    const idx = path.lastIndexOf("/");
    if (idx > 0) path = path.slice(0, idx);
  }
  return path;
}

async function repairFolderViaSearchApi(fileName, auth, preferredHost, cdnUrl) {
  if (!auth || !fileName) {
    return { ok: false, error: "auth/fileName required" };
  }
  const hosts = pcloudApiHosts(preferredHost, cdnUrl);
  const stem = fileName.replace(/\.[^.]+$/, "") || fileName;
  const tokenBits = stem
    .split(/[^a-zA-Z0-9]+/)
    .filter((t) => t.length >= 4)
    .slice(0, 4);
  const queries = [
    fileName,
    stem,
    tokenBits.join(" "),
    tokenBits.slice(0, 2).join(" "),
    tokenBits[0],
  ].filter((q, i, arr) => q && arr.indexOf(q) === i);

  const attempts = [];
  const needle = fileName.toLowerCase();
  const stemNeedle = stem.toLowerCase();

  for (const host of hosts) {
    for (const query of queries) {
      for (const style of ["browser", "legacy"]) {
        try {
          const params = new URLSearchParams({
            auth,
            query,
          });
          if (style === "browser") {
            params.set("offset", "0");
            params.set("limit", "100");
            params.set("iconformat", "id");
          } else {
            params.set("searchall", "1");
          }
          const res = await fetch(`https://${host}/search?${params.toString()}`);
          const json = await res.json();
          const code = json?.result;
          const entries = extractSearchEntries(json || {});
          attempts.push({
            host,
            style,
            query,
            result: code,
            entryCount: entries.length,
            keys: json ? Object.keys(json).slice(0, 12) : [],
          });
          if (code !== 0 || !entries.length) continue;

          let best = null;
          for (const entry of entries) {
            if (entry.isfolder) continue;
            const name = String(entry.name || "");
            const nameLower = name.toLowerCase();
            let rank = -1;
            if (nameLower === needle) rank = 100;
            else if (nameLower === stemNeedle) rank = 90;
            else if (nameLower.includes(needle) || needle.includes(nameLower)) rank = 80;
            else if (nameLower.includes(stemNeedle) || stemNeedle.includes(nameLower)) rank = 70;
            else if (tokenBits.filter((t) => nameLower.includes(t.toLowerCase())).length >= 2) {
              rank = 50;
            }
            if (rank < 0) continue;
            if (!best || rank > best.rank) best = { entry, rank, name };
          }
          if (!best) continue;

          let path = parentPathFromFileEntry(best.entry);
          const parentId =
            best.entry.parentfolderid != null
              ? String(best.entry.parentfolderid)
              : null;
          if (parentId) {
            const meta = await pcloudApiFolderMeta(parentId, auth, host, cdnUrl);
            if (meta && !meta.error) path = meta.path || path;
          }
          // getpath by fileid when available
          if (!path && best.entry.fileid != null) {
            try {
              const pathUrl =
                `https://${host}/getpath?fileid=${encodeURIComponent(
                  String(best.entry.fileid)
                )}&auth=${encodeURIComponent(auth)}`;
              const pathRes = await fetch(pathUrl);
              const pathJson = await pathRes.json();
              if (pathJson?.result === 0 && typeof pathJson.path === "string") {
                path = parentPathFromFileEntry({
                  name: best.name,
                  path: pathJson.path,
                  isfolder: false,
                });
              }
            } catch {
              // ignore
            }
          }

          if (!path) continue;
          return {
            ok: true,
            method: "search_api",
            query,
            matchedName: best.name,
            folder: {
              folderId: parentId,
              folderPath: path,
              folderName: baseName(path),
              source: "search_api",
              tabUrl: null,
              apiHost: host,
              hasAuth: true,
              cookieNames: [],
              apiError: null,
              auth,
            },
          };
        } catch (err) {
          attempts.push({
            host,
            style,
            query,
            error: String(err && err.message ? err.message : err),
          });
        }
      }
    }
  }
  return {
    ok: false,
    error: "search_api no match",
    attempts: attempts.slice(0, 20),
  };
}

async function ensureUsableFolderPath(folder, fileName, cdnUrl) {
  const garbled = isGarbledFolderPath(
    folder.folderPath,
    folder.folderId,
    folder.tabUrl
  );
  const missing = !folder.folderPath;
  if (!garbled && !missing) return folder;

  const effectiveCdn = cdnUrl || folder.cdnUrl || null;
  if (!folder.apiHost && effectiveCdn) {
    folder.apiHost = apiHostFromCdnUrl(effectiveCdn) || folder.apiHost;
  }

  await appendRestLog({
    phase: "folder_repair",
    ok: false,
    message: garbled
      ? "garbled folderPath — trying Open Location"
      : "missing folderPath — trying Open Location",
    folderPath: folder.folderPath,
    tabUrl: folder.tabUrl,
    fileName,
    cdnUrl: effectiveCdn,
    cdnApiHost: apiHostFromCdnUrl(effectiveCdn),
  });

  const viaUi = await repairFolderViaOpenLocation(fileName);
  if (viaUi.ok && viaUi.folder?.folderPath) {
    await appendRestLog({
      phase: "folder_repair",
      ok: true,
      method: "open_location",
      folderPath: viaUi.folder.folderPath,
      folderId: viaUi.folder.folderId,
    });
    return viaUi.folder;
  }

  const authCandidates = [];
  if (folder.auth) authCandidates.push({ auth: folder.auth, apiHost: folder.apiHost });
  try {
    const cookies = await readAuthCandidatesFromCookies();
    for (const c of cookies) {
      if (/^pcauth$/i.test(c.name) || /^auth$/i.test(c.name)) {
        authCandidates.push({ auth: c.auth, apiHost: c.apiHost || folder.apiHost });
      }
    }
  } catch {
    // ignore
  }

  let viaSearch = { ok: false, error: "search_api not attempted" };
  const seenAuth = new Set();
  for (const cand of authCandidates) {
    if (!cand.auth || seenAuth.has(cand.auth)) continue;
    seenAuth.add(cand.auth);
    viaSearch = await repairFolderViaSearchApi(
      fileName,
      cand.auth,
      cand.apiHost,
      effectiveCdn
    );
    if (viaSearch.ok && viaSearch.folder?.folderPath) break;
  }
  if (viaSearch.ok && viaSearch.folder?.folderPath) {
    await appendRestLog({
      phase: "folder_repair",
      ok: true,
      method: "search_api",
      folderPath: viaSearch.folder.folderPath,
      folderId: viaSearch.folder.folderId,
      openLocationError: viaUi.error || null,
    });
    return viaSearch.folder;
  }

  await appendRestLog({
    phase: "folder_repair",
    ok: false,
    error: viaUi.error || viaSearch.error || "repair failed",
    openLocation: viaUi,
    searchApi: viaSearch,
  });

  // Do not POST a garbled path.
  if (garbled) {
    return {
      ...folder,
      folderPath: null,
      folderName: null,
      source: folder.source,
      apiError: viaUi.error || viaSearch.error || "garbled path unrepaired",
    };
  }
  return folder;
}

async function appendRestLog(entry) {
  const row = { at: new Date().toISOString(), ...entry };
  console.log("[rest]", row);

  try {
    const { restLogs = [] } = await chrome.storage.local.get("restLogs");
    restLogs.unshift(row);
    await chrome.storage.local.set({ restLogs: restLogs.slice(0, MAX_REST_LOGS) });
  } catch (err) {
    console.error("storage rest log failed:", err);
  }

  try {
    await fetch(LOCAL_LOG_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(row),
    });
  } catch (err) {
    console.warn("disk rest log sink unreachable:", err);
  }

  try {
    const title = row.ok ? "Loop Segments: queued" : "Loop Segments: REST failed";
    const message = row.ok
      ? `${row.saveName || ""} → ${row.endpoint || ""}`.trim()
      : String(row.error || row.message || "unknown error").slice(0, 180);
    await chrome.notifications.create({
      type: "basic",
      iconUrl: "icon.png",
      title,
      message,
      priority: 2,
    });
  } catch (err) {
    console.warn("notification failed:", err);
  }

  return row;
}

function listingFolderPath(path) {
  if (!path) return null;
  let p = String(path).replace(/\\/g, "/").trim();
  if (!p) return null;
  if (!p.startsWith("/")) p = `/${p}`;
  if (!p.endsWith("/")) p = `${p}/`;
  return p;
}

async function postLanExport({ saveName, folderPath }) {
  const cfg = await loadLanConfig();
  const folderListing = listingFolderPath(folderPath);
  if (!folderListing) {
    const error = "folderPath required for export_from_folder.json (CDN url not posted)";
    await appendRestLog({
      phase: "request",
      ok: false,
      endpoint: `${lanBaseUrl(cfg)}/export_from_folder.json`,
      mode: "folder",
      saveName,
      folderPath: null,
      error,
      host: cfg.phoneLanHost,
      port: cfg.lanPort,
    });
    throw new Error(error);
  }

  const endpoint = `${lanBaseUrl(cfg)}/export_from_folder.json`;
  const bodyObj = {
    folderPath: folderListing,
    displayName: saveName,
    seekMs: 0,
    id: crypto.randomUUID(),
  };
  const body = JSON.stringify(bodyObj);
  const started = Date.now();

  await appendRestLog({
    phase: "request",
    ok: true,
    endpoint,
    mode: "folder",
    saveName,
    folderPath: folderListing,
    body: bodyObj,
    host: cfg.phoneLanHost,
    port: cfg.lanPort,
  });

  let res;
  try {
    res = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: basicAuthHeader(cfg.webdavUser, cfg.webdavPassword),
        "Content-Type": "application/json",
      },
      body,
    });
  } catch (err) {
    const error = `fetch failed: ${err && err.message ? err.message : err}`;
    await appendRestLog({
      phase: "response",
      ok: false,
      endpoint,
      mode: "folder",
      saveName,
      folderPath: folderListing,
      ms: Date.now() - started,
      error,
    });
    throw new Error(error);
  }

  const rawText = await res.text();
  let payload = null;
  try {
    payload = rawText ? JSON.parse(rawText) : null;
  } catch {
    payload = null;
  }

  const ok = res.ok;
  await appendRestLog({
    phase: "response",
    ok,
    endpoint,
    mode: "folder",
    saveName,
    folderPath: folderListing,
    ms: Date.now() - started,
    httpStatus: res.status,
    responseText: rawText.slice(0, 2000),
    payload,
    error: ok ? null : `HTTP ${res.status}: ${rawText.slice(0, 500)}`,
    triggerId: payload?.triggerId || null,
  });

  if (!ok) {
    throw new Error(`Loop Segments API ${res.status}: ${rawText.slice(0, 500)}`);
  }

  return { endpoint, status: res.status, payload, cfg, mode: "folder" };
}

async function openLanBrowse(cfg) {
  const base = lanBaseUrl(cfg);
  const browseUrl = `${base}/browse`;
  try {
    const tabs = await chrome.tabs.query({});
    const existing = tabs.find((t) => {
      if (!t.url) return false;
      try {
        const u = new URL(t.url);
        return (
          `${u.protocol}//${u.host}` === base &&
          (u.pathname === "/browse" || u.pathname === "/browse/")
        );
      } catch {
        return false;
      }
    });

    if (existing?.id != null) {
      await chrome.tabs.update(existing.id, { active: true });
      if (existing.windowId != null) {
        await chrome.windows.update(existing.windowId, { focused: true });
      }
      await appendRestLog({
        phase: "browse",
        ok: true,
        browseUrl,
        message: "focused existing Loop Segments /browse tab",
      });
      return;
    }

    await chrome.tabs.create({ url: browseUrl, active: true });
    await appendRestLog({
      phase: "browse",
      ok: true,
      browseUrl,
      message: "opened new Loop Segments /browse tab",
    });
  } catch (err) {
    await appendRestLog({
      phase: "browse",
      ok: false,
      browseUrl,
      error: String(err && err.message ? err.message : err),
    });
  }
}

async function recordCapture(entry) {
  const { captures = [] } = await chrome.storage.local.get("captures");
  captures.unshift(entry);
  await chrome.storage.local.set({ captures: captures.slice(0, MAX_CAPTURES) });
}

async function finalize(downloadId) {
  const rec = pending.get(downloadId);
  if (!rec || rec.done) return;
  rec.done = true;
  if (rec.timer) clearTimeout(rec.timer);
  pending.delete(downloadId);

  const url = rec.url;
  // Stop the download / CDN tab immediately — do not wait for folder resolve.
  await cancelDownloadQuiet(downloadId);
  await closeMatchingCdnTabs(url);

  if (!claimCapture(url)) {
    await appendRestLog({
      phase: "capture",
      ok: true,
      downloadId,
      url,
      message: "duplicate capture skipped (already handled)",
    });
    return;
  }

  await runCapturePipeline({
    url,
    filename: rec.filename || filenameFromUrl(url) || "pcloud-download",
    referrer: rec.referrer || null,
    downloadId,
  });
}

async function runCapturePipeline({ url, filename, referrer, downloadId }) {
  let folder = {
    folderId: null,
    folderPath: null,
    folderName: null,
    source: null,
    tabUrl: null,
    apiHost: null,
    hasAuth: false,
    cookieNames: [],
    apiError: null,
  };

  try {
    folder = await resolvePcloudFolderContext({
      referrer: referrer || null,
      url,
      cdnUrl: url,
    });
    folder = await ensureUsableFolderPath(folder, filename, url);
  } catch (err) {
    folder.apiError = String(err && err.message ? err.message : err);
  }

  await appendRestLog({
    phase: "folder_resolve",
    ok: Boolean(folder.folderPath || folder.folderName),
    folderId: folder.folderId,
    folderPath: folder.folderPath,
    folderName: folder.folderName,
    folderSource: folder.source,
    tabUrl: folder.tabUrl,
    hasAuth: folder.hasAuth,
    cookieNames: folder.cookieNames,
    apiError: folder.apiError,
    apiHost: folder.apiHost,
    cdnUrl: folder.cdnUrl || url || null,
    cdnApiHost: folder.cdnApiHost || apiHostFromCdnUrl(url) || null,
  });

  await appendRestLog({
    phase: "capture",
    ok: true,
    downloadId: downloadId ?? null,
    url,
    saveName: filename,
    folderId: folder.folderId,
    folderPath: folder.folderPath,
    folderName: folder.folderName,
    folderSource: folder.source,
    message: "pCloud download intercepted; posting to Loop Segments",
  });

  const clipboardLines = [url, filename];
  if (folder.folderPath) clipboardLines.push(folder.folderPath);
  if (folder.folderName && folder.folderName !== folder.folderPath) {
    clipboardLines.push(folder.folderName);
  }
  if (!folder.folderPath && !folder.folderName && folder.folderId) {
    clipboardLines.push(`folder=${folder.folderId}`);
  }
  const clipboardText = clipboardLines.join("\n");

  let api = null;
  let apiError = null;
  let lanCfg = null;

  try {
    api = await postLanExport({
      saveName: filename,
      folderPath: folder.folderPath,
    });
    lanCfg = api.cfg || null;
  } catch (err) {
    apiError = String(err && err.message ? err.message : err);
  }

  if (!lanCfg) {
    try {
      lanCfg = await loadLanConfig();
    } catch (err) {
      await appendRestLog({
        phase: "browse",
        ok: false,
        error: `lan_config: ${err && err.message ? err.message : err}`,
      });
    }
  }

  if (lanCfg) {
    await openLanBrowse(lanCfg);
  }

  try {
    await recordCapture({
      url,
      filename,
      folderId: folder.folderId,
      folderPath: folder.folderPath,
      folderName: folder.folderName,
      at: new Date().toISOString(),
      apiStatus: api ? api.status : null,
      apiError,
      triggerId: api?.payload?.triggerId || null,
    });
    await copyToClipboard(clipboardText);
  } catch (err) {
    await appendRestLog({
      phase: "clipboard",
      ok: false,
      url,
      saveName: filename,
      error: String(err && err.message ? err.message : err),
    });
  }
}

async function handleCdnFileNavigation(tabId, url) {
  if (!isPcloudCdnFileUrl(url)) return;
  if (closingCdnTabIds.has(tabId)) return;

  closingCdnTabIds.add(tabId);
  try {
    await chrome.tabs.remove(tabId);
  } catch {
    // already closed
  } finally {
    closingCdnTabIds.delete(tabId);
  }

  if (!claimCapture(url)) {
    await appendRestLog({
      phase: "cdn_tab",
      ok: true,
      url,
      message: "CDN tab closed (duplicate of in-flight capture)",
    });
    return;
  }

  await appendRestLog({
    phase: "cdn_tab",
    ok: true,
    url,
    message: "CDN file tab intercepted (no downloads API event)",
  });

  await runCapturePipeline({
    url,
    filename: filenameFromUrl(url) || "pcloud-download",
    referrer: null,
    downloadId: null,
  });
}

function trackPcloudDownload(item, filenameHint) {
  const url = isPcloudUrl(item.finalUrl || item.url)
    ? item.finalUrl || item.url
    : item.url;
  const existing = pending.get(item.id);
  const filename = filenameHint || existing?.filename || baseName(item.filename);

  // Cancel immediately so Chromium does not open/save the CDN file while we resolve.
  void cancelDownloadQuiet(item.id);
  void closeMatchingCdnTabs(url);

  if (existing) {
    if (filename) existing.filename = filename;
    if (url) existing.url = url;
    if (item.referrer) existing.referrer = item.referrer;
    return existing;
  }

  const rec = {
    url,
    filename: filename || null,
    referrer: item.referrer || null,
    timer: null,
    done: false,
  };
  rec.timer = setTimeout(() => {
    void finalize(item.id);
  }, FINALIZE_FALLBACK_MS);
  pending.set(item.id, rec);
  return rec;
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "pcloud-folder-context") return;
  const payload = message.payload || {};
  void (async () => {
    try {
      await chrome.storage.session.set({ pcloudFolderContext: payload });
    } catch {
      // ignore
    }
    try {
      await chrome.storage.local.set({ pcloudFolderContext: payload });
    } catch {
      // ignore
    }
    sendResponse({ ok: true });
  })();
  return true;
});

chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
  if (!isPcloudDownload(item)) return;

  const name = baseName(item.filename);
  trackPcloudDownload(item, name);
  suggest();
  void finalize(item.id);
});

chrome.downloads.onCreated.addListener((item) => {
  if (!isPcloudDownload(item)) return;
  trackPcloudDownload(item, baseName(item.filename));
});

// pCloud often opens the signed CDN URL in a new tab (inline media) instead of
// firing downloads.onCreated — especially on the first click after launch.
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  const url = changeInfo.url || (changeInfo.status === "loading" ? tab.url : null);
  if (!url || !isPcloudCdnFileUrl(url)) return;
  void handleCdnFileNavigation(tabId, url);
});

chrome.tabs.onCreated.addListener((tab) => {
  if (!tab?.id || !tab.url || !isPcloudCdnFileUrl(tab.url)) return;
  void handleCdnFileNavigation(tab.id, tab.url);
});

chrome.runtime.onInstalled.addListener(() => {
  void appendRestLog({
    phase: "startup",
    ok: true,
    message: "extension installed/updated",
  });
});

chrome.runtime.onStartup.addListener(() => {
  void logServiceWorkerBoot("onStartup");
});

async function logServiceWorkerBoot(reason) {
  try {
    const cfg = await loadLanConfig();
    await appendRestLog({
      phase: "sw_boot",
      ok: true,
      message: reason,
      host: cfg.phoneLanHost,
      port: cfg.lanPort,
      endpoint: `${lanBaseUrl(cfg)}/export_from_folder.json`,
    });
  } catch (err) {
    await appendRestLog({
      phase: "sw_boot",
      ok: false,
      message: reason,
      error: String(err && err.message ? err.message : err),
    });
  }
}

// Runs when the service worker starts (including --load-extension launches).
void logServiceWorkerBoot("service_worker_eval");

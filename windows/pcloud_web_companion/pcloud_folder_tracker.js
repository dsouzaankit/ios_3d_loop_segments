(() => {
  const STATE_KEY = "pcloudFolderContext";

  function parseFolderId(text) {
    if (!text) return null;
    const m =
      String(text).match(/[?&#]folder=(\d+)/i) ||
      String(text).match(/folder=(\d+)/i);
    return m ? m[1] : null;
  }

  function readBreadcrumb() {
    const selectors = [
      "[class*='breadcrumb' i]",
      "[class*='Breadcrumb']",
      "nav[aria-label*='breadcrumb' i]",
      "[data-testid*='breadcrumb' i]",
      "[class*='path' i]",
    ];
    for (const sel of selectors) {
      const roots = document.querySelectorAll(sel);
      for (const root of roots) {
        const parts = [...root.querySelectorAll("a, span, button, li")]
          .map((el) => (el.textContent || "").replace(/\s+/g, " ").trim())
          .filter(
            (t) =>
              t &&
              t !== "/" &&
              t.length < 180 &&
              !/^home$/i.test(t) &&
              !/^pcloud$/i.test(t)
          );
        // de-dupe adjacent repeats
        const uniq = [];
        for (const p of parts) {
          if (uniq[uniq.length - 1] !== p) uniq.push(p);
        }
        if (uniq.length >= 1) {
          return {
            path: "/" + uniq.join("/"),
            name: uniq[uniq.length - 1],
          };
        }
      }
    }
    return { path: null, name: null };
  }

  function readAuthHint() {
    let auth = null;
    let apiHost = null;
    const consider = (key, value) => {
      if (!value || typeof value !== "string") return;
      if (/\b((?:api|eapi|apinyc\d*|apieu|api[a-z0-9]+)\.pcloud\.com)\b/i.test(value)) {
        const m = value.match(/\b((?:api|eapi|apinyc\d*|apieu|api[a-z0-9]+)\.pcloud\.com)\b/i);
        if (m) apiHost = apiHost || m[1].toLowerCase();
      }
      if (/eapi|locationid['\"]?\s*[:=]\s*2/i.test(value)) {
        apiHost = apiHost || "eapi.pcloud.com";
      }
      if (/^(auth|pcauth|access_token|token|authtoken)$/i.test(key) && value.length >= 16) {
        auth = value.replace(/^"|"$/g, "");
        return;
      }
      try {
        const j = JSON.parse(value);
        if (!j || typeof j !== "object") return;
        const candidate =
          j.auth || j.pcauth || j.token || j.access_token || j.authToken;
        if (typeof candidate === "string" && candidate.length >= 16) {
          auth = candidate;
        }
        if (j.locationid === 2 || j.locationId === 2) apiHost = "eapi.pcloud.com";
      } catch {
        // ignore
      }
    };

    try {
      for (const store of [localStorage, sessionStorage]) {
        for (let i = 0; i < store.length; i++) {
          const key = store.key(i);
          consider(key, store.getItem(key));
        }
      }
    } catch {
      // storage blocked
    }

    try {
      for (const entry of performance.getEntriesByType("resource")) {
        const m = String(entry.name || "").match(
          /\b((?:api|eapi|apinyc\d*|apieu|api[a-z0-9]+)\.pcloud\.com)\b/i
        );
        if (m) {
          apiHost = m[1].toLowerCase();
          break;
        }
      }
    } catch {
      // ignore
    }

    try {
      const cookieAuth = document.cookie.match(
        /(?:^|;\s*)(?:pcauth|auth|token)=([^;]+)/i
      );
      if (cookieAuth) auth = decodeURIComponent(cookieAuth[1]);
    } catch {
      // ignore
    }

    return { auth, apiHost };
  }

  function publish() {
    const href = location.href;
    const folderId = parseFolderId(href);
    const isSearch =
      /[?&#]q=/i.test(href) ||
      (/filter=/i.test(href) && /folderid=0/i.test(href));
    // Search-result chrome text ("foo" in "/All Files/") is not a real path.
    const crumb = isSearch ? { path: null, name: null } : readBreadcrumb();
    const authHint = readAuthHint();
    const payload = {
      folderId: isSearch ? null : folderId,
      folderPath: crumb.path,
      folderName: crumb.name,
      href,
      isSearch,
      auth: authHint.auth,
      apiHost: authHint.apiHost,
      at: Date.now(),
    };
    try {
      chrome.runtime.sendMessage({ type: "pcloud-folder-context", payload });
    } catch {
      // extension context invalidated
    }
    try {
      chrome.storage.session.set({ [STATE_KEY]: payload });
    } catch {
      // session storage may be unavailable
    }
  }

  function parseFileIdsFromUrl(url) {
    try {
      const u = new URL(url, location.href);
      const raw = u.searchParams.get("fileids") || u.searchParams.get("fileid");
      if (!raw) return [];
      return String(raw)
        .split(/[,%2C]+/i)
        .map((s) => s.trim())
        .filter((s) => /^\d+$/.test(s));
    } catch {
      return [];
    }
  }

  function rememberFileIds(ids) {
    if (!ids || !ids.length) return;
    const payload = {
      fileIds: ids.map(String),
      at: Date.now(),
      href: location.href,
    };
    try {
      chrome.runtime.sendMessage({ type: "pcloud-selected-fileids", payload });
    } catch {
      // ignore
    }
    try {
      chrome.storage.session.set({ pcloudSelectedFileIds: payload });
    } catch {
      // ignore
    }
  }

  // Capture multi-select fileids from getthumbslinks / getziplink XHR (archive download path).
  try {
    const origFetch = window.fetch;
    if (typeof origFetch === "function") {
      window.fetch = function (input, init) {
        try {
          const url = typeof input === "string" ? input : input && input.url;
          if (url && /getthumbslinks|getziplink|getzip\b/i.test(url)) {
            const ids = parseFileIdsFromUrl(url);
            if (ids.length) rememberFileIds(ids);
          }
        } catch {
          // ignore
        }
        return origFetch.apply(this, arguments);
      };
    }
  } catch {
    // ignore
  }

  try {
    const XO = XMLHttpRequest.prototype.open;
    const XS = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      this.__lsUrl = url;
      return XO.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      try {
        const url = this.__lsUrl;
        if (url && /getthumbslinks|getziplink|getzip\b/i.test(String(url))) {
          const ids = parseFileIdsFromUrl(String(url));
          if (ids.length) rememberFileIds(ids);
        }
      } catch {
        // ignore
      }
      return XS.apply(this, arguments);
    };
  } catch {
    // ignore
  }

  publish();
  window.addEventListener("hashchange", publish);
  window.addEventListener("popstate", publish);
  setInterval(publish, 1500);

  const origPush = history.pushState;
  const origReplace = history.replaceState;
  history.pushState = function () {
    const ret = origPush.apply(this, arguments);
    setTimeout(publish, 0);
    return ret;
  };
  history.replaceState = function () {
    const ret = origReplace.apply(this, arguments);
    setTimeout(publish, 0);
    return ret;
  };
})();

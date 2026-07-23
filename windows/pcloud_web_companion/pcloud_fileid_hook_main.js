// MAIN world: page fetch/XHR see this hook (isolated content scripts do not).
(() => {
  if (window.__loopSegmentsFileIdHook) return;
  window.__loopSegmentsFileIdHook = true;

  function parseFileIdsFromUrl(url) {
    try {
      const u = new URL(url, location.href);
      const raw = u.searchParams.get("fileids") || u.searchParams.get("fileid");
      if (raw) {
        return String(raw)
          .split(",")
          .map((s) => s.trim())
          .filter((s) => /^\d+$/.test(s));
      }
    } catch {
      // fall through
    }
    const m = String(url).match(/[?&]fileids?=([^&#]+)/i);
    if (!m) return [];
    try {
      return decodeURIComponent(m[1])
        .split(",")
        .map((s) => s.trim())
        .filter((s) => /^\d+$/.test(s));
    } catch {
      return [];
    }
  }

  function parseFileIdsFromBody(body) {
    if (body == null) return [];
    let text = "";
    if (typeof body === "string") text = body;
    else if (body instanceof URLSearchParams) text = body.toString();
    else if (typeof FormData !== "undefined" && body instanceof FormData) {
      const parts = [];
      for (const [k, v] of body.entries()) {
        if (typeof v === "string") parts.push(`${k}=${v}`);
      }
      text = parts.join("&");
    } else {
      return [];
    }
    const ids = [];
    const m = text.match(/(?:^|&)fileids?=([^&]+)/i);
    if (m) {
      try {
        ids.push(
          ...decodeURIComponent(m[1].replace(/\+/g, " "))
            .split(",")
            .map((s) => s.trim())
            .filter((s) => /^\d+$/.test(s))
        );
      } catch {
        // ignore
      }
    }
    try {
      const j = JSON.parse(text);
      const raw = j?.fileids ?? j?.fileIds ?? j?.fileid ?? j?.fileId;
      if (Array.isArray(raw)) {
        ids.push(...raw.map(String).filter((s) => /^\d+$/.test(s)));
      } else if (raw != null) {
        ids.push(
          ...String(raw)
            .split(",")
            .map((s) => s.trim())
            .filter((s) => /^\d+$/.test(s))
        );
      }
    } catch {
      // not JSON
    }
    return [...new Set(ids)];
  }

  function publish(ids, url) {
    if (!ids.length) return;
    window.postMessage(
      {
        source: "loop-segments-fileids",
        fileIds: ids.map(String),
        url: String(url || ""),
        at: Date.now(),
      },
      "*"
    );
  }

  function maybeCapture(url, body) {
    if (!url || !/getthumbslinks|getziplink|getzip\b|savezip|pubzip/i.test(url)) {
      return;
    }
    const fromUrl = parseFileIdsFromUrl(url);
    const fromBody = parseFileIdsFromBody(body);
    publish([...new Set([...fromUrl, ...fromBody])], url);
  }

  try {
    const origFetch = window.fetch;
    if (typeof origFetch === "function") {
      window.fetch = function (input, init) {
        try {
          const url = typeof input === "string" ? input : input && input.url;
          const body = init && init.body != null ? init.body : null;
          maybeCapture(url, body);
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
    XMLHttpRequest.prototype.send = function (body) {
      try {
        maybeCapture(this.__lsUrl, body);
      } catch {
        // ignore
      }
      return XS.apply(this, arguments);
    };
  } catch {
    // ignore
  }
})();

(function () {
  var MEDIA_ROOT = window.__XR_CONFIG__.mediaRoot;
  var LOOP_PREFIX = window.__XR_CONFIG__.loopPrefix;
  var ARCHIVE_PREFIX = window.__XR_CONFIG__.archivePrefix;
  var RATE_KEY = "loopsegments.lan.xrChromaRate.v1";
  var VOL_KEY = "loopsegments.lan.xrVolume.v1";
  var KEY_KEY = "loopsegments.lan.xrChromaKey.v1";
  var MODE_KEY = "loopsegments.lan.xrChromaMode.v2";
  var RATES = [0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3];
  var loopPlaylist = [];
  var workingPlaylist = [];
  var archivePlaylist = [];
  var mode = "loop";
  var index = 0;
  var wantPlay = false;
  var video = document.getElementById("chroma-stream");
  var overlay = document.getElementById("overlay");
  var label = document.getElementById("xr-label");
  var rateSel = document.getElementById("xr-rate");
  var volumeEl = document.getElementById("xr-volume");
  var volumeLaunchEl = document.getElementById("xr-volume-launch");
  var launchBtn = document.getElementById("xr-launch");
  var prevBtn = document.getElementById("xr-prev");
  var nextBtn = document.getElementById("xr-next");
  var modeLoopBtn = document.getElementById("xr-mode-loop");
  var modeWorkingBtn = document.getElementById("xr-mode-working");
  var modeArchiveBtn = document.getElementById("xr-mode-archive");
  var fileListEl = document.getElementById("xr-file-list");
  var refreshBtn = document.getElementById("xr-refresh-list");
  var reopenBtn = document.getElementById("xr-reopen");
  var transport = document.getElementById("xr-transport");
  var playPauseBtn = document.getElementById("xr-playpause");
  var seekEl = document.getElementById("xr-seek");
  var seekBackBtn = document.getElementById("xr-seek-back");
  var fullscreenBtn = document.getElementById("xr-fullscreen");
  var seekFwdBtn = document.getElementById("xr-seek-fwd");
  var timeEl = document.getElementById("xr-time");
  var chromaToggle = document.getElementById("xr-chroma-toggle");
  var chromaKeyEl = document.getElementById("xr-chroma-key");
  var chromaKeyPlayEl = document.getElementById("xr-chroma-key-play");
  var sbsToggle = document.getElementById("xr-sbs-toggle");
  var seekDragging = false;
  if (!video || !overlay) return;
  // Same-origin LAN files must not use crossOrigin=anonymous (no CORS headers → black WebGL + audio OK).
  try {
    video.crossOrigin = null;
    video.removeAttribute("crossorigin");
  } catch (e) {}

  function sphereEls() {
    return [
      document.getElementById("chroma-screen"),
      document.getElementById("chroma-sphere"),
      document.getElementById("chroma-sphere-right")
    ].filter(Boolean);
  }
  function refreshSphereShader() {
    sphereEls().forEach(function (el) {
      var comp = el.components && el.components["chroma-stereo-sbs"];
      if (comp) try { comp.applyShader(); } catch (e) {}
    });
  }
  function chromaKeyColor() {
    var raw = (chromaKeyEl && chromaKeyEl.value) || "#00ff00";
    if (!/^#[0-9a-fA-F]{6}$/.test(raw)) return "#00ff00";
    return raw.toLowerCase();
  }
  function syncShaderToggles() {
    var chromaOn = !!(chromaToggle && chromaToggle.checked);
    var sbsOn = !sbsToggle || !!sbsToggle.checked;
    var key = chromaKeyColor();
    sphereEls().forEach(function (el) {
      try {
        el.setAttribute("chroma-stereo-sbs", "chroma", chromaOn);
        el.setAttribute("chroma-stereo-sbs", "sbs", sbsOn);
        el.setAttribute("chroma-stereo-sbs", "keyColor", key);
      } catch (e) {}
    });
  }
  function applyChromaKey(hex) {
    if (!/^#[0-9a-fA-F]{6}$/.test(hex || "")) hex = "#00ff00";
    hex = hex.toLowerCase();
    if (chromaKeyEl) chromaKeyEl.value = hex;
    if (chromaKeyPlayEl) chromaKeyPlayEl.value = hex;
    try { localStorage.setItem(KEY_KEY, hex); } catch (e) {}
    syncShaderToggles();
    refreshSphereShader();
  }

  function setLabel(msg) {
    if (label) label.textContent = msg || "";
  }
  function normalizeMode(m) {
    if (m === "working" || m === "archive" || m === "loop") return m;
    if (m === "media") return "working";
    return "loop";
  }
  function activePlaylist() {
    if (mode === "working") return workingPlaylist;
    if (mode === "archive") return archivePlaylist;
    return loopPlaylist;
  }
  function emptyLabel() {
    if (mode === "working") {
      return "No playable media in the media root yet — export or copy a file next to _working.mp4, then Refresh list";
    }
    if (mode === "archive") {
      return "No archive/ videos yet — finish an export, then Refresh list";
    }
    return "No loop/op_*.mp4 yet";
  }
  function modeTag() {
    if (mode === "working") return "working";
    if (mode === "archive") return "archive";
    return "loop";
  }
  function listGroupTitle() {
    if (mode === "working") return "Working (media root videos, outside archive/)";
    if (mode === "archive") return "Archive folder";
    return "Loop segments";
  }
  function leafName(path) {
    var n = normPath(path);
    var i = n.lastIndexOf("/");
    return i >= 0 ? n.slice(i + 1) : n;
  }
  function formatBytes(n) {
    var b = Number(n) || 0;
    if (b <= 0) return "";
    if (b < 1024) return b + " B";
    if (b < 1024 * 1024) return Math.round(b / 1024) + " KB";
    return (b / (1024 * 1024)).toFixed(1) + " MB";
  }
  function formatClock(sec) {
    var s = Math.max(0, Math.floor(Number(sec) || 0));
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    var r = s % 60;
    var mm = (h > 0 ? String(m).padStart(2, "0") : String(m));
    var ss = String(r).padStart(2, "0");
    return h > 0 ? (h + ":" + mm + ":" + ss) : (mm + ":" + ss);
  }
  function syncPlayPauseLabel() {
    if (!playPauseBtn) return;
    playPauseBtn.textContent = video.paused ? "Play" : "Pause";
  }
  function mediaDuration() {
    var dur = Number(video.duration);
    if (isFinite(dur) && dur > 0) return dur;
    try {
      if (video.seekable && video.seekable.length > 0) {
        var end = video.seekable.end(video.seekable.length - 1);
        if (isFinite(end) && end > 0) return end;
      }
    } catch (e) {}
    return 0;
  }
  function clampSeekTime(t) {
    t = Number(t);
    if (!isFinite(t) || t < 0) t = 0;
    var dur = mediaDuration();
    if (dur > 0) t = Math.min(dur, t);
    try {
      if (video.seekable && video.seekable.length > 0) {
        for (var i = 0; i < video.seekable.length; i++) {
          var a = video.seekable.start(i);
          var b = video.seekable.end(i);
          if (t >= a && t <= b) return t;
        }
        // Snap to nearest seekable edge (sparse _working holes, partial buffers).
        var best = video.seekable.start(0);
        var bestDist = Math.abs(t - best);
        for (var j = 0; j < video.seekable.length; j++) {
          var s = video.seekable.start(j);
          var e = video.seekable.end(j);
          if (Math.abs(t - s) < bestDist) { best = s; bestDist = Math.abs(t - s); }
          if (Math.abs(t - e) < bestDist) { best = e; bestDist = Math.abs(t - e); }
        }
        return best;
      }
    } catch (e) {}
    return t;
  }
  function applySeekTime(t) {
    t = clampSeekTime(t);
    if (!isFinite(t)) return;
    try {
      if (typeof video.fastSeek === "function") video.fastSeek(t);
      else video.currentTime = t;
    } catch (e) {
      try { video.currentTime = t; } catch (e2) {}
    }
    try {
      if (typeof __xrVideoTex !== "undefined" && __xrVideoTex && __xrDs.av1Known && __xrDs.av1 === true) __xrVideoTex.needsUpdate = true;
    } catch (e3) {}
    try { refreshSphereShader(); } catch (e4) {}
    syncTransportUI();
  }
  function endSeekDrag() {
    if (!seekDragging) return;
    seekDragging = false;
    if (seekEl) applySeekTime(parseFloat(seekEl.value));
    else syncTransportUI();
  }
  function syncTransportUI() {
    if (!seekEl || !timeEl) return;
    var dur = mediaDuration();
    var cur = Number(video.currentTime) || 0;
    var max = dur > 0 ? dur : Math.max(cur, 1);
    // Keep max current even while dragging so the thumb can travel the full bar.
    seekEl.min = "0";
    seekEl.max = String(max);
    if (!seekDragging) {
      seekEl.value = String(Math.min(cur, max));
    }
    timeEl.textContent = formatClock(seekDragging ? (parseFloat(seekEl.value) || cur) : cur)
      + " / " + formatClock(dur);
    syncPlayPauseLabel();
  }
  function showTransport(show) {
    if (!transport) return;
    transport.style.display = show ? "block" : "none";
    if (show) transport.removeAttribute("hidden");
    else transport.setAttribute("hidden", "");
    if (show) syncTransportUI();
  }
  function exitImmersiveIfNeeded() {
    try {
      var scene = document.querySelector("a-scene");
      if (scene && scene.is && (scene.is("vr-mode") || scene.is("ar-mode")) && scene.exitVR) {
        scene.exitVR();
      }
    } catch (e) {}
  }
  function stopPlaybackForHome() {
    // Pause alone can leave Quest WebXR decoding / audio running under the overlay.
    // Suspend AV1 first, exit XR, then dispose GPU — never dispose while presenting.
    wantPlay = false;
    try { xrSuspendAv1Pipeline(); } catch (eSus) {}
    __xrDs.exiting = false;
    try { video.pause(); } catch (e) {}
    exitImmersiveIfNeeded();
    try {
      video.removeAttribute("src");
      video.load();
    } catch (e2) {}
    try { syncPlayPauseLabel(); } catch (e3) {}
    try { refreshSphereShader(); } catch (e4) {}
    try { xrScheduleDisposeAv1Gpu(); } catch (eDisp) {}
    try { xrLog("files-home", { sawAv1Tex: !!__xrDs.sawAv1Tex }); } catch (eL) {}
  }
  function showOverlay(show) {
    overlay.style.display = show ? "flex" : "none";
    if (reopenBtn) reopenBtn.style.display = show ? "none" : "block";
    showTransport(!show);
    if (show) {
      stopPlaybackForHome();
    } else {
      closeArchiveDropdown();
      __xrDs.exiting = false;
      __xrDs.suspendBlit = false;
      try { refreshSphereShader(); } catch (eKick) {}
      try { xrLog("launch-engine", { sawAv1Tex: !!__xrDs.sawAv1Tex }); } catch (eL) {}
    }
    syncArchiveFloat();
  }
  function seekBy(delta) {
    applySeekTime((Number(video.currentTime) || 0) + delta);
  }
  var workingSeekSec = 0;
  function refreshWorkingSeek() {
    return fetch("status.json", { cache: "no-store" })
      .then(function (r) { return r.json(); })
      .then(function (j) {
        var w = j && j.workingSourcePlayback;
        var s = w && Number(w.playbackStartSeconds);
        workingSeekSec = isFinite(s) && s > 0 ? s : 0;
      })
      .catch(function () { workingSeekSec = 0; });
  }
  function applyWorkingSeekIfNeeded(item) {
    if (!item || !isSparseWorkingName(item.name) || !(workingSeekSec > 0)) return;
    var target = workingSeekSec;
    var apply = function () {
      try {
        if (Math.abs((video.currentTime || 0) - target) > 0.5) video.currentTime = target;
      } catch (e) {}
    };
    if (video.readyState >= 1) apply();
    else {
      var onMeta = function () {
        video.removeEventListener("loadedmetadata", onMeta);
        apply();
      };
      video.addEventListener("loadedmetadata", onMeta);
    }
  }
  var archiveDd = document.getElementById("xr-archive-dd");
  var archiveDdList = document.getElementById("xr-archive-dd-list");
  var archiveDdClose = document.getElementById("xr-archive-dd-close");
  var archiveFloat = document.getElementById("xr-archive-float");
  function archiveSelectionLabel() {
    var playlist = archivePlaylist;
    if (!playlist.length) return emptyLabel();
    var item = playlist[index] || playlist[0];
    var sz = formatBytes(item.bytes);
    return (index + 1) + "/" + playlist.length + " · " + leafName(item.name)
      + (sz ? " · " + sz : "");
  }
  function closeArchiveDropdown() {
    if (!archiveDd) return;
    archiveDd.classList.remove("open");
    archiveDd.setAttribute("aria-hidden", "true");
  }
  function openArchiveDropdown() {
    if (!archiveDd || !archiveDdList) return;
    archiveDdList.innerHTML = "";
    var playlist = archivePlaylist;
    if (!playlist.length) {
      var empty = document.createElement("div");
      empty.className = "xr-file-empty";
      empty.textContent = emptyLabel();
      archiveDdList.appendChild(empty);
    } else {
      playlist.forEach(function (item, idx) {
        var btn = document.createElement("button");
        btn.type = "button";
        btn.className = "xr-file-item" + (idx === index ? " selected" : "");
        btn.setAttribute("role", "option");
        btn.setAttribute("aria-selected", idx === index ? "true" : "false");
        var nameEl = document.createElement("span");
        nameEl.className = "xr-file-name";
        nameEl.textContent = leafName(item.name);
        var meta = document.createElement("span");
        meta.className = "xr-file-meta";
        var bits = [];
        var sz = formatBytes(item.bytes);
        if (sz) bits.push(sz);
        bits.push(item.name);
        meta.textContent = bits.join(" · ");
        btn.appendChild(nameEl);
        btn.appendChild(meta);
        btn.onclick = function () {
          closeArchiveDropdown();
          loadIndex(idx, wantPlay && !video.paused);
        };
        archiveDdList.appendChild(btn);
      });
    }
    archiveDd.classList.add("open");
    archiveDd.setAttribute("aria-hidden", "false");
  }
  function makeArchivePickButton() {
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "xr-archive-pick";
    btn.setAttribute("aria-haspopup", "listbox");
    btn.setAttribute("aria-expanded", "false");
    var labelEl = document.createElement("span");
    labelEl.className = "xr-archive-pick-label";
    labelEl.textContent = archiveSelectionLabel();
    var chev = document.createElement("span");
    chev.className = "xr-archive-pick-chevron";
    chev.textContent = "▾";
    btn.appendChild(labelEl);
    btn.appendChild(chev);
    btn.onclick = function (e) {
      e.preventDefault();
      e.stopPropagation();
      openArchiveDropdown();
    };
    return btn;
  }
  function syncArchiveFloat() {
    if (!archiveFloat) return;
    // Floater belongs on the Launch Engine picker page — not over playback.
    var overlayOpen = overlay && overlay.style.display !== "none";
    var show = mode === "archive" && overlayOpen;
    archiveFloat.style.display = show ? "block" : "none";
    if (show) {
      archiveFloat.removeAttribute("hidden");
      archiveFloat.innerHTML = "";
      archiveFloat.appendChild(makeArchivePickButton());
    } else {
      archiveFloat.setAttribute("hidden", "");
      archiveFloat.innerHTML = "";
    }
  }
  function renderFileList() {
    if (!fileListEl) return;
    fileListEl.innerHTML = "";
    var playlist = activePlaylist();
    if (mode === "archive") {
      var wrap = document.createElement("div");
      wrap.className = "xr-archive-pick-wrap";
      if (!playlist.length) {
        var empty = document.createElement("div");
        empty.className = "xr-file-empty";
        empty.textContent = emptyLabel();
        wrap.appendChild(empty);
      } else {
        wrap.appendChild(makeArchivePickButton());
      }
      fileListEl.appendChild(wrap);
      syncArchiveFloat();
      return;
    }
    if (!playlist.length) {
      var empty2 = document.createElement("div");
      empty2.className = "xr-file-empty";
      empty2.textContent = emptyLabel();
      fileListEl.appendChild(empty2);
      syncArchiveFloat();
      return;
    }
    function addGroup(title) {
      var g = document.createElement("div");
      g.className = "xr-file-group";
      g.textContent = title;
      fileListEl.appendChild(g);
    }
    function addItem(item, idx, groupHint) {
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "xr-file-item" + (idx === index ? " selected" : "");
      btn.setAttribute("role", "option");
      btn.setAttribute("aria-selected", idx === index ? "true" : "false");
      btn.dataset.index = String(idx);
      var nameEl = document.createElement("span");
      nameEl.className = "xr-file-name";
      nameEl.textContent = leafName(item.name);
      var meta = document.createElement("span");
      meta.className = "xr-file-meta";
      var bits = [];
      if (groupHint) bits.push(groupHint);
      var sz = formatBytes(item.bytes);
      if (sz) bits.push(sz);
      bits.push(item.name);
      meta.textContent = bits.join(" · ");
      btn.appendChild(nameEl);
      btn.appendChild(meta);
      btn.onclick = function () {
        loadIndex(idx, wantPlay && !video.paused);
      };
      fileListEl.appendChild(btn);
    }
    addGroup(listGroupTitle());
    playlist.forEach(function (item, idx) { addItem(item, idx, modeTag()); });
    syncArchiveFloat();
  }
  if (archiveDdClose) archiveDdClose.onclick = function () { closeArchiveDropdown(); };
  if (archiveDd) {
    archiveDd.addEventListener("click", function (e) {
      if (e.target === archiveDd) closeArchiveDropdown();
    });
  }
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") closeArchiveDropdown();
  });
  function snapRate(v) {
    var r = Math.round(Number(v) * 10) / 10;
    if (!isFinite(r)) return 1;
    for (var i = 0; i < RATES.length; i++) {
      if (Math.abs(RATES[i] - r) < 0.001) return RATES[i];
    }
    return 1;
  }
  function readRate() {
    var v = 1;
    try {
      var raw = localStorage.getItem(RATE_KEY);
      if (raw != null) v = parseFloat(raw);
    } catch (e) {}
    return snapRate(v);
  }
  function writeRate(v) {
    try { localStorage.setItem(RATE_KEY, String(snapRate(v))); } catch (e) {}
  }
  function readMode() {
    try {
      return normalizeMode(localStorage.getItem(MODE_KEY));
    } catch (e) {}
    return "loop";
  }
  function writeMode(m) {
    try { localStorage.setItem(MODE_KEY, normalizeMode(m)); } catch (e) {}
  }
  function applyRate() {
    var v = readRate();
    if (rateSel) rateSel.value = String(v);
    try { video.playbackRate = v; } catch (e) {}
  }
  function readVolume() {
    var v = 1;
    try {
      var raw = localStorage.getItem(VOL_KEY);
      if (raw != null) v = parseFloat(raw);
    } catch (e) {}
    if (!isFinite(v)) v = 1;
    return Math.max(0, Math.min(1, Math.round(v * 10) / 10));
  }
  function applyVolume(v) {
    v = Math.max(0, Math.min(1, Math.round(Number(v) * 10) / 10));
    if (!isFinite(v)) v = 1;
    try { localStorage.setItem(VOL_KEY, String(v)); } catch (e) {}
    try {
      video.volume = v;
      video.muted = v <= 0;
    } catch (e2) {}
    if (volumeEl) volumeEl.value = String(v);
    if (volumeLaunchEl) volumeLaunchEl.value = String(v);
    var label = document.getElementById("xr-vol-label");
    if (label) label.setAttribute("value", Math.round(v * 100) + "%");
    window.__xrVolume = v;
  }
  window.__xrStepVolume = function (delta) {
    applyVolume(readVolume() + Number(delta || 0));
  };
  function syncModeButtons() {
    if (modeLoopBtn) modeLoopBtn.classList.toggle("active", mode === "loop");
    if (modeWorkingBtn) modeWorkingBtn.classList.toggle("active", mode === "working");
    if (modeArchiveBtn) modeArchiveBtn.classList.toggle("active", mode === "archive");
  }
  function normPath(name) {
    return String(name || "").replace(/\\/g, "/");
  }
  function isVideoExt(name) {
    return /\.(mp4|m4v|mov|webm|mkv)$/i.test(name);
  }
  function isLoopSegmentName(name) {
    var n = normPath(name);
    if (n.indexOf(LOOP_PREFIX) !== 0) return false;
    var base = n.slice(LOOP_PREFIX.length);
    if (!base || base.indexOf("/") >= 0) return false;
    if (/staging/i.test(base)) return false;
    return /^op_\d+\.(mp4|m4v|mov)$/i.test(base);
  }
  function isSparseWorkingName(name) {
    var n = normPath(name);
    if (n.indexOf(MEDIA_ROOT) !== 0) return false;
    var leaf = n.slice(MEDIA_ROOT.length);
    if (!leaf || leaf.indexOf("/") >= 0) return false;
    return /^_working/i.test(leaf) && isVideoExt(leaf);
  }
  // Working tab: any playable file in the media root (alongside `_working.mp4`), not loop/ or archive/.
  function isMediaRootPlayableName(name) {
    var n = normPath(name);
    if (n.indexOf(MEDIA_ROOT) !== 0) return false;
    var leaf = n.slice(MEDIA_ROOT.length);
    if (!leaf || leaf.indexOf("/") >= 0) return false;
    if (/staging/i.test(leaf) || /\.sparse\.json$/i.test(leaf)) return false;
    return isVideoExt(leaf);
  }
  function isArchiveMediaName(name) {
    var n = normPath(name);
    if (n.indexOf(ARCHIVE_PREFIX) !== 0) return false;
    var rest = n.slice(ARCHIVE_PREFIX.length);
    if (!rest || rest.indexOf("/") >= 0) return false;
    if (/staging/i.test(rest)) return false;
    return isVideoExt(rest);
  }
  function cacheBust(entry) {
    var q = [];
    if (entry.bytes) q.push("b=" + encodeURIComponent(String(entry.bytes)));
    if (entry.modified) q.push("m=" + encodeURIComponent(String(entry.modified)));
    return q.length ? ("?" + q.join("&")) : "";
  }
  function entryFromFile(f) {
    var name = f && f.name;
    return {
      name: name,
      bytes: Number(f.bytes) || 0,
      modified: f.modified || "",
      url: "/" + String(name).replace(/^\/+/, "") + cacheBust(f)
    };
  }
  function buildLoopPlaylist(files) {
    var list = Array.isArray(files) ? files : [];
    var out = [];
    var seen = {};
    list.forEach(function (f) {
      var name = f && f.name;
      if (!isLoopSegmentName(name) || seen[name]) return;
      seen[name] = true;
      out.push(entryFromFile(f));
    });
    out.sort(function (a, b) {
      return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
    });
    if (!out.length) {
      ["op_00.mp4", "op_01.mp4"].forEach(function (base) {
        var name = LOOP_PREFIX + base;
        out.push({ name: name, bytes: 0, modified: "", url: "/" + name });
      });
    }
    return out;
  }
  function buildWorkingPlaylist(files) {
    var list = Array.isArray(files) ? files : [];
    var out = [];
    var seen = {};
    list.forEach(function (f) {
      var name = f && f.name;
      if (!name || seen[name] || !isMediaRootPlayableName(name)) return;
      seen[name] = true;
      out.push(entryFromFile(f));
    });
    out.sort(function (a, b) {
      function rank(n) {
        if (/_working\.mp4$/i.test(n)) return 0;
        if (/_working/i.test(n)) return 1;
        return 2;
      }
      var ar = rank(a.name);
      var br = rank(b.name);
      if (ar !== br) return ar - br;
      return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
    });
    return out;
  }
  function buildArchivePlaylist(files) {
    var list = Array.isArray(files) ? files : [];
    var out = [];
    var seen = {};
    list.forEach(function (f) {
      var name = f && f.name;
      if (!name || seen[name] || !isArchiveMediaName(name)) return;
      seen[name] = true;
      out.push(entryFromFile(f));
    });
    out.sort(function (a, b) {
      if (a.modified && b.modified && a.modified !== b.modified) {
        return a.modified > b.modified ? -1 : 1;
      }
      return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
    });
    return out;
  }
  function loadIndex(i, autoplay) {
    var playlist = activePlaylist();
    if (!playlist.length) {
      setLabel(emptyLabel());
      renderFileList();
      return;
    }
    index = ((i % playlist.length) + playlist.length) % playlist.length;
    var item = playlist[index];
    wantPlay = !!autoplay;
    // New clip: soft reset in XR (keep last frame); hard reset only outside XR.
    try {
      if (xrIsPresenting()) xrPrepareNewClip();
      else xrResetPlaybackPipeline();
    } catch (eReset) {}
    try { xrLog("loadIndex", { i: index, name: item.name, presenting: !!xrIsPresenting(), sawAv1Tex: !!__xrDs.sawAv1Tex }); } catch (eLog) {}
    video.src = item.url;
    applyRate();
    setLabel("[" + modeTag() + "] " + (index + 1) + "/" + playlist.length + ": " + item.name);
    renderFileList();
    syncShaderToggles();
    applyWorkingSeekIfNeeded(item);
    var onReady = function () {
      applyWorkingSeekIfNeeded(item);
      refreshSphereShader();
    };
    var onLoaded = function () {
      video.removeEventListener("loadeddata", onLoaded);
      onReady();
    };
    video.addEventListener("loadeddata", onLoaded);
    if (video.readyState >= 2) onReady();
    if (wantPlay) {
      var p = video.play();
      if (p && typeof p.then === "function") {
        p.then(function () {
          applyWorkingSeekIfNeeded(item);
          refreshSphereShader();
        }).catch(function () {
          wantPlay = false;
          setLabel("Play blocked — tap Launch Engine");
        });
      } else {
        refreshSphereShader();
      }
    } else {
      refreshSphereShader();
    }
  }
  function setMode(next, keepPlay) {
    mode = normalizeMode(next);
    writeMode(mode);
    syncModeButtons();
    index = 0;
    if (activePlaylist().length) loadIndex(0, !!(keepPlay && wantPlay));
    else {
      try {
        video.removeAttribute("src");
        video.load();
      } catch (e) {}
      setLabel(emptyLabel());
      renderFileList();
    }
  }
  function applyFiles(files) {
    loopPlaylist = buildLoopPlaylist(files);
    workingPlaylist = buildWorkingPlaylist(files);
    archivePlaylist = buildArchivePlaylist(files);
    applyRate();
    if (activePlaylist().length) loadIndex(Math.min(index, activePlaylist().length - 1), false);
    else {
      setLabel(emptyLabel());
      renderFileList();
    }
  }
  function refreshPlaylists() {
    setLabel("Refreshing file list…");
    return fetch("status_lists.json", { cache: "no-store" })
      .then(function (r) { return r.json(); })
      .then(function (j) { applyFiles(j && j.files); })
      .catch(function () {
        applyFiles([]);
        setLabel("Could not refresh status_lists.json");
      });
  }
  function initializePlayer() {
    var playlist = activePlaylist();
    if (!playlist.length) {
      setLabel(emptyLabel());
      return;
    }
    wantPlay = true;
    if (!video.src) loadIndex(index, true);
    else {
      applyRate();
      var p = video.play();
      if (p && typeof p.then === "function") {
        p.then(function () { refreshSphereShader(); }).catch(function () {});
      } else {
        refreshSphereShader();
      }
    }
    showOverlay(false);
    // Give the mesh a moment after overlay hide / first paint.
    setTimeout(refreshSphereShader, 200);
    setTimeout(refreshSphereShader, 800);
  }
  if (launchBtn) launchBtn.onclick = initializePlayer;
  if (modeLoopBtn) modeLoopBtn.onclick = function () { setMode("loop", false); };
  if (modeWorkingBtn) modeWorkingBtn.onclick = function () { setMode("working", false); };
  if (modeArchiveBtn) modeArchiveBtn.onclick = function () { setMode("archive", false); };
  if (refreshBtn) refreshBtn.onclick = function () { refreshPlaylists(); };
  var zoomEl = document.getElementById("xr-zoom");
  if (zoomEl) {
    window.__xrZoom = Number(zoomEl.value) || 1;
    zoomEl.addEventListener("input", function () {
      window.__xrZoom = Number(zoomEl.value) || 1;
      var lab = document.getElementById("xr-zoom-label");
      if (lab) lab.setAttribute("value", Math.round(window.__xrZoom * 180) + "°");
      sphereEls().forEach(function (el) {
        var comp = el.components && el.components["chroma-stereo-sbs"];
        if (!comp) return;
        comp._domeGeoReady = false;
        try { comp.ensureDomeGeometry(); comp.syncEyeLayers(); } catch (eZ) {}
      });
    });
  }
  var distEl = document.getElementById("xr-dist");
  if (distEl) {
    window.__xrDist = Number(distEl.value) || 0;
    distEl.addEventListener("input", function () {
      window.__xrDist = Number(distEl.value) || 0;
      // followHead reads __xrDist every immersive frame; nudge once for immediate feedback.
      sphereEls().forEach(function (el) {
        var comp = el.components && el.components["chroma-stereo-sbs"];
        if (comp) try { comp.followHead(); } catch (eD) {}
      });
    });
  }
  if (chromaToggle) chromaToggle.onchange = function () { syncShaderToggles(); refreshSphereShader(); };
  if (chromaKeyEl) chromaKeyEl.oninput = function () { applyChromaKey(chromaKeyEl.value); };
  if (chromaKeyPlayEl) chromaKeyPlayEl.oninput = function () { applyChromaKey(chromaKeyPlayEl.value); };
  try {
    var savedKey = localStorage.getItem(KEY_KEY);
    if (savedKey && /^#[0-9a-fA-F]{6}$/.test(savedKey)) applyChromaKey(savedKey);
  } catch (eKey) {}
  if (sbsToggle) sbsToggle.onchange = function () { syncShaderToggles(); refreshSphereShader(); };
  if (reopenBtn) {
    reopenBtn.onclick = function () {
      showOverlay(true);
      setLabel("Stopped — pick a file, then Launch Engine");
      renderFileList();
    };
  }
  function togglePlayPause() {
    if (!video || !video.src) return;
    if (video.paused) {
      wantPlay = true;
      var p = video.play();
      if (p && typeof p.then === "function") {
        p.then(function () { refreshSphereShader(); syncPlayPauseLabel(); }).catch(function () {});
      } else {
        refreshSphereShader();
        syncPlayPauseLabel();
      }
    } else {
      video.pause();
      wantPlay = false;
      syncPlayPauseLabel();
    }
  }
  // Always the <video>, Chroma on or off: the browser player has full resolution and its
  // own controls (screen size, brightness, 180/3D menu). Keying only pays off in AR.
  function toggleFullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen();
      return;
    }
    if (xrIsPresenting()) return;
    var request = video.requestFullscreen || video.webkitRequestFullscreen;
    if (!request) return;
    var result = request.call(video);
    if (result && result.catch) {
      result.catch(function (e) {
        try { xrLog("fullscreen-failed", { error: String(e) }); } catch (eLog) {}
      });
    }
  }
  function onFullscreenChange() {
    var full = document.fullscreenElement;
    video.controls = full === video;
    if (fullscreenBtn) fullscreenBtn.textContent = full ? "Exit Fullscreen" : "Fullscreen";
    try { xrLog("fullscreen", { on: !!full }); } catch (eLog) {}
    // Back to the normal preview: rebind, or the plane stays on the fullscreen path.
    if (!full) {
      try { xrClearComponentModes(); } catch (eModes) {}
      try { refreshSphereShader(); } catch (eShader) {}
    }
  }
  document.addEventListener("fullscreenchange", onFullscreenChange);
  function isXrChromeTarget(el) {
    if (!el || !el.closest) return false;
    return !!el.closest(
      "#xr-transport, #xr-reopen, #overlay, #xr-archive-float, #xr-archive-dd,"
      + " .a-enter-vr, .a-enter-ar, .a-dialog, .a-modal, button, input, select, a, label"
    );
  }
  if (playPauseBtn) playPauseBtn.onclick = function () { togglePlayPause(); };
  // Click / tap the scene (not chrome) toggles play/pause during playback.
  document.addEventListener("click", function (e) {
    if (overlay && overlay.style.display !== "none") return;
    if (isXrChromeTarget(e.target)) return;
    // The fullscreen <video> has native controls. A tap here would toggle twice.
    if (document.fullscreenElement === video) return;
    togglePlayPause();
  });
  // Quest controller trigger (WebXR select) toggles play/pause in AR/VR.
  (function wireXrTriggerPlayPause() {
    var lastMs = 0;
    var boundSession = null;
    function onSelect(ev) {
      try {
        if (ev && ev.inputSource && ev.inputSource.targetRayMode === "gaze") return;
      } catch (eGaze) {}
      if (overlay && overlay.style.display !== "none") return;
      var now = Date.now();
      if (now - lastMs < 280) return;
      lastMs = now;
      togglePlayPause();
    }
    function unbind() {
      if (!boundSession) return;
      try { boundSession.removeEventListener("select", onSelect); } catch (eOff) {}
      boundSession = null;
    }
    function bind() {
      unbind();
      var session = null;
      try {
        var scene = document.querySelector("a-scene");
        session = scene && scene.renderer && scene.renderer.xr && scene.renderer.xr.getSession
          ? scene.renderer.xr.getSession()
          : null;
      } catch (eSess) {}
      if (!session) return;
      boundSession = session;
      try { session.addEventListener("select", onSelect); } catch (eOn) {}
    }
    var sceneEl = document.querySelector("a-scene");
    if (sceneEl) {
      sceneEl.addEventListener("enter-vr", function () { setTimeout(bind, 0); setTimeout(bind, 200); });
      sceneEl.addEventListener("exit-vr", unbind);
    }
  })();
  if (fullscreenBtn) fullscreenBtn.onclick = toggleFullscreen;
  if (seekBackBtn) seekBackBtn.onclick = function () { seekBy(-10); };
  if (seekFwdBtn) seekFwdBtn.onclick = function () { seekBy(10); };
  if (seekEl) {
    function beginSeekDrag() { seekDragging = true; }
    // Always seek on input — do not require pointerdown (Quest/PC often skip it on range).
    seekEl.addEventListener("pointerdown", beginSeekDrag);
    seekEl.addEventListener("mousedown", beginSeekDrag);
    seekEl.addEventListener("touchstart", beginSeekDrag, { passive: true });
    seekEl.addEventListener("input", function () {
      seekDragging = true;
      applySeekTime(parseFloat(seekEl.value));
    });
    seekEl.addEventListener("change", function () {
      applySeekTime(parseFloat(seekEl.value));
      seekDragging = false;
    });
    window.addEventListener("pointerup", endSeekDrag);
    window.addEventListener("pointercancel", endSeekDrag);
    window.addEventListener("mouseup", endSeekDrag);
    window.addEventListener("touchend", endSeekDrag);
    window.addEventListener("blur", endSeekDrag);
  }
  if (prevBtn) prevBtn.onclick = function () {
    if (!activePlaylist().length) return;
    loadIndex(index - 1, wantPlay && !video.paused);
  };
  if (nextBtn) nextBtn.onclick = function () {
    if (!activePlaylist().length) return;
    loadIndex(index + 1, wantPlay && !video.paused);
  };
  if (rateSel) {
    rateSel.value = String(readRate());
    rateSel.onchange = function () {
      var v = parseFloat(rateSel.value);
      if (!isFinite(v)) v = 1;
      writeRate(v);
      applyRate();
    };
  }
  function onVolumeInput(e) {
    applyVolume(e && e.target ? e.target.value : readVolume());
  }
  if (volumeEl) {
    volumeEl.value = String(readVolume());
    volumeEl.addEventListener("input", onVolumeInput);
  }
  if (volumeLaunchEl) {
    volumeLaunchEl.value = String(readVolume());
    volumeLaunchEl.addEventListener("input", onVolumeInput);
  }
  applyVolume(readVolume());
  video.addEventListener("loadedmetadata", function () { applyVolume(readVolume()); });
  video.addEventListener("timeupdate", syncTransportUI);
  video.addEventListener("durationchange", syncTransportUI);
  video.addEventListener("loadedmetadata", syncTransportUI);
  video.addEventListener("seeked", function () {
    try {
      if (typeof __xrVideoTex !== "undefined" && __xrVideoTex && __xrDs.av1Known && __xrDs.av1 === true) __xrVideoTex.needsUpdate = true;
    } catch (e) {}
    try { refreshSphereShader(); } catch (e2) {}
    syncTransportUI();
  });
  video.addEventListener("progress", syncTransportUI);
  video.addEventListener("play", syncPlayPauseLabel);
  video.addEventListener("pause", syncPlayPauseLabel);
  video.addEventListener("ended", function () {
    if (!activePlaylist().length) return;
    loadIndex(index + 1, true);
  });
  video.addEventListener("error", function () {
    var playlist = activePlaylist();
    var item = playlist[index];
    setLabel("Could not load " + (item && item.name ? item.name : "media")
      + (playlist.length > 1 ? " — pick another from the list" : " (export on phone first)"));
    wantPlay = false;
    showOverlay(true);
    renderFileList();
  });
  mode = readMode();
  syncModeButtons();
  showOverlay(true);
  try {
    var params = new URLSearchParams(window.location.search || "");
    var qMode = params.get("mode");
    var hashMode = String(window.location.hash || "").replace(/^#/, "");
    if (qMode) mode = normalizeMode(qMode);
    else if (hashMode) mode = normalizeMode(hashMode);
    writeMode(mode);
    syncModeButtons();
  } catch (e) {}
  (function probeWebXR() {
    var el = document.getElementById("xr-webxr-status");
    if (!el) return;
    var secure = !!(window.isSecureContext);
    var origin = String(location.origin || "");
    function setStatus(msg) { el.textContent = msg; }
    if (!navigator.xr) {
      setStatus("WebXR API missing — origin " + origin
        + (secure ? " (secure context OK)" : " (NOT a secure context — need https:// tunnel or Quest flags)"));
      return;
    }
    var done = false;
    function finish(vr, ar) {
      if (done) return;
      done = true;
      setStatus("WebXR @ " + origin
        + " — immersive-vr: " + (vr ? "yes" : "no")
        + ", immersive-ar (passthrough): " + (ar ? "yes — use Enter AR" : "no")
        + (secure ? "" : " — insecure context"));
    }
    var timeout = setTimeout(function () {
      if (done) return;
      done = true;
      setStatus("WebXR probe timed out @ " + origin
        + (secure ? "" : " — insecure context; PC preview still works after Launch"));
    }, 2500);
    Promise.all([
      navigator.xr.isSessionSupported("immersive-vr").catch(function () { return false; }),
      navigator.xr.isSessionSupported("immersive-ar").catch(function () { return false; })
    ]).then(function (bits) {
      clearTimeout(timeout);
      finish(!!bits[0], !!bits[1]);
    }).catch(function () {
      clearTimeout(timeout);
      finish(false, false);
    });
  })();
  refreshWorkingSeek().finally(function () {
    refreshPlaylists();
  });
})();

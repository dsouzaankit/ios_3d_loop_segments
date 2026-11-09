(function () {
  var THREE = window.AFRAME && AFRAME.THREE ? AFRAME.THREE : window.THREE;
  if (!THREE || !window.AFRAME) return;

  // Shared video texture for left/right hemispheres (one decode).
  var __xrVideoTex = null;
  function xrEnsureVideoTexture(video) {
    if (!video || !video.videoWidth) return null;
    if (!__xrVideoTex) {
      __xrVideoTex = new THREE.VideoTexture(video);
      __xrVideoTex.minFilter = THREE.LinearFilter;
      __xrVideoTex.magFilter = THREE.LinearFilter;
      __xrVideoTex.generateMipmaps = false;
      __xrVideoTex.wrapS = THREE.ClampToEdgeWrapping;
      __xrVideoTex.wrapT = THREE.ClampToEdgeWrapping;
      if ("colorSpace" in __xrVideoTex && THREE.SRGBColorSpace) {
        __xrVideoTex.colorSpace = THREE.SRGBColorSpace;
      } else if ("encoding" in __xrVideoTex && THREE.sRGBEncoding) {
        __xrVideoTex.encoding = THREE.sRGBEncoding;
      }
    }
    __xrVideoTex.needsUpdate = true;
    return __xrVideoTex;
  }

  // Shared DOM canvas. A-Frame material src (not a raw CanvasTexture) — Quest 3 AR
  // drops MeshBasicMaterial maps, which blanked both clips after the 1536 downscale.
  window.__xrZoom = 1;
  window.__xrZoomSteps = [0.5, 0.6, 0.7, 0.8, 0.9, 1];
  // Skybox-style: meters to push the dome along world -Z (session forward). 0 = centered.
  window.__xrDist = 0;
  var __xrDs = { canvas: null, ctx: null, codecSrc: "", av1: false, suspendBlit: false, exiting: false, sawAv1Tex: false };
  // Player script (second IIFE) must see these — bare refs otherwise throw and leave
  // "Checking WebXR…" / "Loading playlists…" stuck (PC + Quest).
  window.__xrDs = __xrDs;
  var __xrLogBuf = [];
  var __xrLogFlushTimer = 0;
  function xrDebugSnapshot() {
    var v = document.getElementById("chroma-stream");
    var mode = "";
    try {
      var el = document.getElementById("chroma-sphere");
      var c = el && el.components && el.components["chroma-stereo-sbs"];
      mode = (c && c._mode) || "";
    } catch (eM) {}
    return {
      t: Date.now(),
      presenting: !!xrIsPresenting(),
      exiting: !!__xrDs.exiting,
      suspendBlit: !!__xrDs.suspendBlit,
      av1: !!__xrDs.av1,
      av1Known: !!__xrDs.av1Known,
      sawAv1Tex: !!__xrDs.sawAv1Tex,
      mode: mode,
      resolved: !!__xrDs.resolved,
      codecSrc: (__xrDs.codecSrc || "").slice(-80),
      videoSrc: v ? ((v.currentSrc || v.src || "").slice(-80)) : "",
      paused: !!(v && v.paused),
      vw: v ? (v.videoWidth || 0) : 0,
      vh: v ? (v.videoHeight || 0) : 0,
      ct: v ? (Number(v.currentTime) || 0) : 0,
      note: (typeof window.__xrTexNote === "string") ? window.__xrTexNote : ""
    };
  }
  function xrLog(msg, extra) {
    var line = new Date().toISOString() + " " + String(msg || "");
    if (extra != null) {
      try { line += " " + JSON.stringify(extra); } catch (eJ) {}
    }
    __xrLogBuf.push(line);
    if (__xrLogBuf.length > 80) __xrLogBuf.splice(0, __xrLogBuf.length - 80);
    if (__xrLogFlushTimer) return;
    __xrLogFlushTimer = setTimeout(function () {
      __xrLogFlushTimer = 0;
      var batch = __xrLogBuf.splice(0, __xrLogBuf.length);
      if (!batch.length) return;
      var body = JSON.stringify({ lines: batch, snapshot: xrDebugSnapshot() });
      try {
        fetch("xr_debug.json", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: body,
          keepalive: true
        }).catch(function () {});
      } catch (ePost) {}
    }, 400);
  }
  function xrIsPresenting() {
    try {
      var scene = document.querySelector("a-scene");
      return !!(scene && scene.renderer && scene.renderer.xr && scene.renderer.xr.isPresenting);
    } catch (e) {
      return false;
    }
  }
  function xrClearAv1Flags() {
    __xrDs.av1 = false;
    __xrDs.av1Known = false;
    __xrDs.codecSrc = "";
    __xrDs.codecPending = "";
    __xrDs.codecRetrySrc = "";
    __xrDs.codecRetryAfter = 0;
    __xrDs.resolved = null;
    __xrDs.resolvedSrc = "";
  }
  function xrClearComponentModes() {
    try {
      ["chroma-screen", "chroma-sphere", "chroma-sphere-right"].forEach(function (id) {
        var el = document.getElementById(id);
        var comp = el && el.components && el.components["chroma-stereo-sbs"];
        if (!comp) return;
        comp._mode = "";
        comp._gpuSig = "";
        comp._uvZoom = null;
        comp._uvEyeApplied = null;
        comp._domeGeoReady = false;
      });
    } catch (eComp) {}
  }
  // Disposing a 6K AV1 RT / VideoTexture while WebXR is still presenting freezes Quest.
  function xrDisposeAv1Gpu() {
    try { if (__xrDs.rt) __xrDs.rt.dispose(); } catch (eRt) {}
    __xrDs.rt = null;
    __xrDs.rtW = 0;
    __xrDs.rtH = 0;
    // The texture is gone. Drop the handle so Enter VR does not sample it.
    __xrDs.resolved = null;
    __xrDs.resolvedSrc = "";
    // Do not dispose __xrVideoTex here — Quest then blacks A-Frame's video map too.
    if (__xrVideoTex) {
      try { __xrVideoTex.needsUpdate = false; } catch (eStop) {}
    }
  }
  function xrScheduleDisposeAv1Gpu() {
    var token = (__xrDs.disposeToken || 0) + 1;
    __xrDs.disposeToken = token;
    setTimeout(function () {
      if (__xrDs.disposeToken !== token) return;
      if (xrIsPresenting()) {
        xrScheduleDisposeAv1Gpu();
        return;
      }
      xrDisposeAv1Gpu();
      __xrDs.suspendBlit = false;
    }, 700);
  }
  // Soft stop for AR/VR exit. Keep the last blit and the codec — clearing them
  // made the next Enter VR seed the dome from a canvas (AV1 tile atlas, or empty).
  function xrSuspendAv1Pipeline() {
    __xrDs.suspendBlit = true;
    xrClearComponentModes();
  }
  // Still in XR: re-probe the new clip but keep the last RT on screen (no black hole).
  function xrPrepareNewClip() {
    __xrDs.disposeToken = (__xrDs.disposeToken || 0) + 1;
    __xrDs.suspendBlit = false;
    __xrDs.av1 = false;
    __xrDs.av1Known = false;
    __xrDs.codecSrc = "";
    __xrDs.codecPending = "";
    __xrDs.codecRetrySrc = "";
    __xrDs.codecRetryAfter = 0;
    __xrDs.lastBlitTime = -1;
    __xrDs.needsMaterialKick = true;
    // Keep __xrDs.resolved + RT until the first blit of the new clip replaces them.
    xrClearComponentModes();
    try { xrForgetStaleCanvases(document.getElementById("chroma-stream")); } catch (eBag) {}
  }
  function xrResetPlaybackPipeline() {
    __xrDs.suspendBlit = true;
    __xrDs.exiting = false;
    xrClearAv1Flags();
    xrClearComponentModes();
    try { xrForgetStaleCanvases(document.getElementById("chroma-stream")); } catch (eBag) {}
    __xrDs.lastBlitTime = -1;
    // Keep sawAv1Tex for this page load — once Quest has blitted AV1, native
    // VideoTexture stays unreliable; canvas path must continue after Files.
    if (xrIsPresenting()) {
      xrScheduleDisposeAv1Gpu();
      return;
    }
    xrDisposeAv1Gpu();
    __xrDs.suspendBlit = false;
  }
  window.xrIsPresenting = xrIsPresenting;
  window.xrLog = xrLog;
  window.xrSuspendAv1Pipeline = xrSuspendAv1Pipeline;
  window.xrScheduleDisposeAv1Gpu = xrScheduleDisposeAv1Gpu;
  window.xrPrepareNewClip = xrPrepareNewClip;
  window.xrResetPlaybackPipeline = xrResetPlaybackPipeline;
  // Quest's 2D canvas draw of an AV1 <video> copies the decoder tile atlas
  // (one wide tile on top, two tiles splitting the bottom), not the picture.
  // A GPU pass that samples the whole video texture forces every tile to update.
  function xrWatchAv1(video) {
    var src = (video && (video.currentSrc || video.src)) || "";
    if (!src) return false;
    if (__xrDs.av1Known && __xrDs.codecSrc === src) return __xrDs.av1 === true;
    var nowMs = Date.now();
    if (__xrDs.codecPending === src) return __xrDs.av1 === true;
    if (__xrDs.codecRetrySrc === src && __xrDs.codecRetryAfter && nowMs < __xrDs.codecRetryAfter) {
      return __xrDs.av1 === true;
    }
    __xrDs.codecPending = src;
    __xrDs.codecSrc = src;
    __xrDs.av1Known = false;
    // Do not keep the previous clip's AV1 flag while the new probe runs.
    // Leave __xrDs.resolved up so the dome holds the last picture until this probe finishes.
    __xrDs.av1 = false;
    function hasAv01(buf) {
      // Box type only. A raw "av01" scan false-positives inside HEVC mdat and then
      // the dome stays on the AV1 blit path (blank after a real AV1 clip).
      var u8 = new Uint8Array(buf);
      for (var i = 0; i + 8 <= u8.length; i++) {
        var size = (u8[i] << 24) | (u8[i + 1] << 16) | (u8[i + 2] << 8) | u8[i + 3];
        if (size < 8 || size > 16777216) continue;
        if (u8[i + 4] === 97 && u8[i + 5] === 118 && u8[i + 6] === 48 && u8[i + 7] === 49) return true;
      }
      return false;
    }
    function finish(isAv1) {
      if (__xrDs.codecSrc !== src && __xrDs.codecPending !== src) return;
      __xrDs.codecSrc = src;
      __xrDs.av1 = !!isAv1;
      __xrDs.av1Known = true;
      __xrDs.codecPending = "";
      // HEVC must not keep sampling the previous AV1 render target.
      // Do not dispose the VideoTexture here — on Quest that poisons the same
      // <video> for A-Frame preview/AR and both stay black until a full reload.
      if (!isAv1) {
        __xrDs.resolved = null;
        __xrDs.lastBlitTime = -1;
        if (__xrVideoTex) {
          try { __xrVideoTex.needsUpdate = false; } catch (eStop) {}
        }
      }
      __xrDs.needsMaterialKick = true;
      try { xrLog("codec", { av1: !!isAv1, sawAv1Tex: !!__xrDs.sawAv1Tex, src: (src || "").slice(-60) }); } catch (eLog) {}
    }
    function fail() {
      if (__xrDs.codecSrc !== src && __xrDs.codecPending !== src) return;
      __xrDs.av1 = false;
      __xrDs.av1Known = false;
      __xrDs.codecPending = "";
      __xrDs.codecSrc = "";
      __xrDs.codecRetrySrc = src;
      __xrDs.codecRetryAfter = Date.now() + 1200;
    }
    fetch(src, { headers: { Range: "bytes=0-524287" } }).then(function (r) {
      if (!r.ok && r.status !== 206) throw new Error("range");
      var total = 0;
      var cr = r.headers.get("Content-Range") || "";
      var m = /\/(\d+)\s*$/.exec(cr);
      if (m) total = parseInt(m[1], 10) || 0;
      return r.arrayBuffer().then(function (buf) { return { buf: buf, total: total }; });
    }).then(function (pack) {
      if (__xrDs.codecSrc !== src && __xrDs.codecPending !== src) return;
      if (hasAv01(pack.buf)) { finish(true); return; }
      var tailReq = null;
      if (pack.total > 524288) {
        var start = pack.total - 524288;
        tailReq = fetch(src, { headers: { Range: "bytes=" + start + "-" + (pack.total - 1) } });
      } else if (!pack.total) {
        tailReq = fetch(src, { headers: { Range: "bytes=-524288" } });
      }
      if (!tailReq) { finish(false); return; }
      return tailReq.then(function (r2) {
        if (!r2.ok && r2.status !== 206) throw new Error("tail");
        return r2.arrayBuffer();
      }).then(function (tail) { finish(hasAv01(tail)); });
    }).catch(function () { fail(); });
    return __xrDs.av1 === true;
  }
  function xrBlitFullVideo(renderer, video) {
    if (!renderer || !video || !video.videoWidth) return null;
    // Never blit while exiting AR/VR or after the session has ended.
    if (__xrDs.suspendBlit) return null;
    var xr = renderer.xr;
    if (!xr || !xr.isPresenting) return null;
    if (__xrDs.blitting) return __xrDs.resolved || null;
    var tex = xrEnsureVideoTexture(video);
    if (!tex) return null;
    // Quest lenses do not need a 4K+ blit every frame — that was crushing AR fps.
    var maxW = 6144;
    var scale = Math.min(maxW / video.videoWidth, maxW / video.videoHeight, 1);
    var w = Math.max(2, Math.floor(video.videoWidth * scale / 2) * 2);
    var h = Math.max(2, Math.floor(video.videoHeight * scale / 2) * 2);
    if (!__xrDs.rt || __xrDs.rtW !== w || __xrDs.rtH !== h) {
      try { if (__xrDs.rt) __xrDs.rt.dispose(); } catch (eRt) {}
      __xrDs.rt = new THREE.WebGLRenderTarget(w, h, {
        minFilter: THREE.LinearFilter,
        magFilter: THREE.LinearFilter,
        depthBuffer: false,
        stencilBuffer: false
      });
      __xrDs.rt.texture.generateMipmaps = false;
      if (THREE.LinearSRGBColorSpace && "colorSpace" in __xrDs.rt.texture) {
        __xrDs.rt.texture.colorSpace = THREE.LinearSRGBColorSpace;
      }
      __xrDs.rtW = w;
      __xrDs.rtH = h;
    }
    if (!__xrDs.blitCam) {
      __xrDs.blitCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 2);
      __xrDs.blitScene = new THREE.Scene();
      // Copy the video texels unchanged. Do not flip V — that inverted AV1 in AR.
      __xrDs.blitMat = new THREE.RawShaderMaterial({
        uniforms: { tex: { value: tex } },
        vertexShader: [
          "attribute vec3 position;",
          "attribute vec2 uv;",
          "uniform mat4 projectionMatrix;",
          "uniform mat4 modelViewMatrix;",
          "varying vec2 vUv;",
          "void main(){",
          "  vUv = uv;",
          "  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);",
          "}"
        ].join("\n"),
        fragmentShader: [
          "precision highp float;",
          "uniform sampler2D tex;",
          "varying vec2 vUv;",
          "void main(){ gl_FragColor = texture2D(tex, vUv); }"
        ].join("\n"),
        depthTest: false,
        depthWrite: false
      });
      __xrDs.blitScene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), __xrDs.blitMat));
    }
    __xrDs.blitMat.uniforms.tex.value = tex;
    tex.needsUpdate = true;
    var wasEnabled = !!xr.enabled;
    var prev = renderer.getRenderTarget();
    var prevClear = renderer.autoClear;
    if (!__xrDs.viewport) __xrDs.viewport = new THREE.Vector4();
    if (!__xrDs.scissor) __xrDs.scissor = new THREE.Vector4();
    var prevScissorTest = false;
    try { renderer.getViewport(__xrDs.viewport); } catch (eVp) {}
    try { renderer.getScissor(__xrDs.scissor); } catch (eSc) {}
    try { prevScissorTest = !!renderer.getScissorTest(); } catch (eSt) {}
    function restoreBlit() {
      try { renderer.setRenderTarget(prev); } catch (eSet) {}
      try {
        renderer.setViewport(__xrDs.viewport.x, __xrDs.viewport.y, __xrDs.viewport.z, __xrDs.viewport.w);
      } catch (eVp2) {}
      try {
        renderer.setScissor(__xrDs.scissor.x, __xrDs.scissor.y, __xrDs.scissor.z, __xrDs.scissor.w);
      } catch (eSc2) {}
      try { renderer.setScissorTest(prevScissorTest); } catch (eSt2) {}
      renderer.autoClear = prevClear;
      // Only restore XR if the session is still live — enabling during teardown hangs Quest.
      try {
        if (xr.isPresenting) xr.enabled = wasEnabled;
      } catch (eXr) {}
      __xrDs.blitting = false;
    }
    __xrDs.blitting = true;
    try {
      xr.enabled = false;
      renderer.autoClear = true;
      renderer.setRenderTarget(__xrDs.rt);
      renderer.render(__xrDs.blitScene, __xrDs.blitCam);
    } catch (eBlit) {
      restoreBlit();
      return null;
    }
    restoreBlit();
    __xrDs.sawAv1Tex = true;
    return __xrDs.rt ? __xrDs.rt.texture : null;
  }
  // Quest flat preview. drawImage of AV1 is the tile atlas, and xr-chroma on a
  // video texture stays black. Blit a small keyed frame and hand A-Frame a canvas.
  function xrKeyedPreviewCanvas(renderer, video, chroma) {
    if (!renderer || !video || !video.videoWidth || !chroma) return null;
    if (__xrDs.exiting || __xrDs.suspendBlit || __xrDs.blitting) return null;
    var tex = xrEnsureVideoTexture(video);
    if (!tex) return null;
    var limit = 1280;
    var scale = Math.min(limit / video.videoWidth, limit / video.videoHeight, 1);
    var w = Math.max(2, Math.floor(video.videoWidth * scale / 2) * 2);
    var h = Math.max(2, Math.floor(video.videoHeight * scale / 2) * 2);
    var srcNow = xrVideoSrc(video);
    var bag = xrSlotBag("flat");
    var stamp = (video.currentTime || 0).toFixed(3) + "|" + w + "x" + h + "|gpuc" + (chroma.keyColor || "") + "|" + srcNow;
    if (bag.stamp === stamp && bag.canvas && bag.canvas.width === w && bag.src === srcNow) return bag.canvas;
    var nowMs = Date.now();
    if (bag.canvas && bag.src === srcNow && __xrDs.previewReadAt && (nowMs - __xrDs.previewReadAt) < 120) {
      return bag.canvas;
    }
    var key = new THREE.Color(chroma.keyColor || "#00ff00");
    var sim = (chroma.similarity == null) ? 0.3 : chroma.similarity;
    var smo = (chroma.smoothness == null) ? 0.08 : chroma.smoothness;
    if (!__xrDs.previewRt || __xrDs.previewW !== w || __xrDs.previewH !== h) {
      try { if (__xrDs.previewRt) __xrDs.previewRt.dispose(); } catch (eRt) {}
      __xrDs.previewRt = new THREE.WebGLRenderTarget(w, h, {
        minFilter: THREE.LinearFilter,
        magFilter: THREE.LinearFilter,
        type: THREE.UnsignedByteType,
        format: THREE.RGBAFormat,
        depthBuffer: false,
        stencilBuffer: false
      });
      __xrDs.previewRt.texture.generateMipmaps = false;
      __xrDs.previewW = w;
      __xrDs.previewH = h;
      __xrDs.previewBuf = null;
    }
    if (!__xrDs.previewMat) {
      __xrDs.previewCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 2);
      __xrDs.previewScene = new THREE.Scene();
      __xrDs.previewMat = new THREE.RawShaderMaterial({
        uniforms: {
          tex: { value: tex },
          keyColor: { value: key },
          similarity: { value: sim },
          smoothness: { value: smo }
        },
        vertexShader: [
          "attribute vec3 position;",
          "attribute vec2 uv;",
          "uniform mat4 projectionMatrix;",
          "uniform mat4 modelViewMatrix;",
          "varying vec2 vUv;",
          "void main(){",
          "  vUv = vec2(uv.x, 1.0 - uv.y);",
          "  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);",
          "}"
        ].join("\n"),
        fragmentShader: [
          "precision highp float;",
          "uniform sampler2D tex;",
          "uniform vec3 keyColor;",
          "uniform float similarity;",
          "uniform float smoothness;",
          "varying vec2 vUv;",
          "void main(){",
          "  vec4 videoColor = texture2D(tex, vUv);",
          "  float cr = 0.5 * videoColor.r - 0.4187 * videoColor.g - 0.0813 * videoColor.b;",
          "  float cb = -0.1687 * videoColor.r - 0.3313 * videoColor.g + 0.5 * videoColor.b;",
          "  float keyCr = 0.5 * keyColor.r - 0.4187 * keyColor.g - 0.0813 * keyColor.b;",
          "  float keyCb = -0.1687 * keyColor.r - 0.3313 * keyColor.g + 0.5 * keyColor.b;",
          "  float dist = sqrt((cr - keyCr) * (cr - keyCr) + (cb - keyCb) * (cb - keyCb));",
          "  float blend = smoothstep(similarity, similarity + smoothness, dist);",
          "  gl_FragColor = vec4(videoColor.rgb * blend, blend);",
          "}"
        ].join("\n"),
        depthTest: false,
        depthWrite: false
      });
      __xrDs.previewScene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), __xrDs.previewMat));
    } else {
      __xrDs.previewMat.uniforms.tex.value = tex;
      __xrDs.previewMat.uniforms.keyColor.value.copy(key);
      __xrDs.previewMat.uniforms.similarity.value = sim;
      __xrDs.previewMat.uniforms.smoothness.value = smo;
    }
    tex.needsUpdate = true;
    var prevTarget = renderer.getRenderTarget();
    var prevClear = renderer.autoClear;
    var xr = renderer.xr;
    var wasEnabled = !!(xr && xr.enabled);
    if (!__xrDs.viewport) __xrDs.viewport = new THREE.Vector4();
    if (!__xrDs.scissor) __xrDs.scissor = new THREE.Vector4();
    var prevScissorTest = false;
    try { renderer.getViewport(__xrDs.viewport); } catch (eVp) {}
    try { renderer.getScissor(__xrDs.scissor); } catch (eSc) {}
    try { prevScissorTest = !!renderer.getScissorTest(); } catch (eSt) {}
    function restorePreview() {
      try { renderer.setRenderTarget(prevTarget); } catch (eSet) {}
      try {
        renderer.setViewport(__xrDs.viewport.x, __xrDs.viewport.y, __xrDs.viewport.z, __xrDs.viewport.w);
      } catch (eVp2) {}
      try {
        renderer.setScissor(__xrDs.scissor.x, __xrDs.scissor.y, __xrDs.scissor.z, __xrDs.scissor.w);
      } catch (eSc2) {}
      try { renderer.setScissorTest(prevScissorTest); } catch (eSt2) {}
      renderer.autoClear = prevClear;
      try { if (xr && xr.isPresenting) xr.enabled = wasEnabled; } catch (eXr) {}
      __xrDs.blitting = false;
    }
    __xrDs.blitting = true;
    try {
      if (xr && xr.isPresenting) xr.enabled = false;
      renderer.autoClear = true;
      renderer.setRenderTarget(__xrDs.previewRt);
      renderer.render(__xrDs.previewScene, __xrDs.previewCam);
      if (!__xrDs.previewBuf || __xrDs.previewBuf.length !== w * h * 4) {
        __xrDs.previewBuf = new Uint8Array(w * h * 4);
      }
      renderer.readRenderTargetPixels(__xrDs.previewRt, 0, 0, w, h, __xrDs.previewBuf);
    } catch (ePreview) {
      restorePreview();
      return null;
    }
    restorePreview();
    var canvas = bag.canvas || document.getElementById("xr-ds-canvas");
    if (!canvas) {
      canvas = document.createElement("canvas");
      canvas.id = "xr-ds-canvas";
      canvas.width = 16;
      canvas.height = 16;
      document.body.appendChild(canvas);
    }
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
      bag.ctx = null;
    }
    if (!bag.ctx) bag.ctx = canvas.getContext("2d", { alpha: true });
    var img = bag.ctx.createImageData(w, h);
    img.data.set(__xrDs.previewBuf);
    bag.ctx.putImageData(img, 0, 0);
    bag.canvas = canvas;
    bag.src = srcNow;
    bag.stamp = stamp;
    bag.pendingUpload = true;
    __xrDs.previewReadAt = Date.now();
    __xrDs.sawAv1Tex = true;
    return canvas;
  }
  function xrApplyChromaKey(ctx, cw, ch, keyHex, similarity, smoothness) {
    var img = ctx.getImageData(0, 0, cw, ch);
    var d = img.data;
    var key = new THREE.Color(keyHex || "#00ff00");
    var keyCr = 0.5 * key.r - 0.4187 * key.g - 0.0813 * key.b;
    var keyCb = -0.1687 * key.r - 0.3313 * key.g + 0.5 * key.b;
    var sim = (similarity == null) ? 0.3 : similarity;
    var smo = (smoothness == null) ? 0.08 : smoothness;
    if (smo < 0.0001) smo = 0.0001;
    var edge = sim + smo;
    for (var i = 0; i < d.length; i += 4) {
      var r = d[i] / 255;
      var g = d[i + 1] / 255;
      var b = d[i + 2] / 255;
      var cr = 0.5 * r - 0.4187 * g - 0.0813 * b;
      var cb = -0.1687 * r - 0.3313 * g + 0.5 * b;
      var dist = Math.sqrt((cr - keyCr) * (cr - keyCr) + (cb - keyCb) * (cb - keyCb));
      var blend = dist <= sim ? 0 : (dist >= edge ? 1 : (dist - sim) / smo);
      d[i + 3] = (blend * 255) | 0;
    }
    ctx.putImageData(img, 0, 0);
  }
  function xrSlotBag(slot) {
    var key = slot === "ar" ? "ar" : "flat";
    if (!__xrDs.bags) __xrDs.bags = {};
    if (!__xrDs.bags[key]) {
      __xrDs.bags[key] = { canvas: null, ctx: null, stamp: "", src: "", readFreq: false, pendingUpload: false };
    }
    return __xrDs.bags[key];
  }
  function xrVideoSrc(video) {
    return (video && (video.currentSrc || video.src)) || "";
  }
  function xrClearBagPixels(bag) {
    if (!bag) return;
    bag.stamp = "";
    bag.src = "";
    bag.pendingUpload = false;
    try {
      if (bag.ctx && bag.canvas) bag.ctx.clearRect(0, 0, bag.canvas.width, bag.canvas.height);
    } catch (e) {}
  }
  // Clip changes must not leave the previous picture in the dome canvas.
  function xrForgetStaleCanvases(video) {
    var src = xrVideoSrc(video);
    if (!__xrDs.bags) return;
    ["flat", "ar"].forEach(function (key) {
      var bag = __xrDs.bags[key];
      if (!bag || !bag.src || bag.src === src) return;
      xrClearBagPixels(bag);
    });
  }
  // Enter VR often cannot draw the <video> yet. Copy the live preview canvas
  // so the dome does not keep the previous attempt's frame.
  function xrSeedArFromFlat(video) {
    var src = xrVideoSrc(video);
    var flat = xrSlotBag("flat");
    if (!flat.canvas || !flat.canvas.width || !flat.src || flat.src !== src) return null;
    var ar = xrSlotBag("ar");
    var canvas = ar.canvas || document.getElementById("xr-ds-ar");
    if (!canvas) {
      canvas = document.createElement("canvas");
      canvas.id = "xr-ds-ar";
      canvas.width = 16;
      canvas.height = 16;
      document.body.appendChild(canvas);
    }
    if (canvas.width !== flat.canvas.width || canvas.height !== flat.canvas.height) {
      canvas.width = flat.canvas.width;
      canvas.height = flat.canvas.height;
      ar.ctx = null;
    }
    if (!ar.ctx) ar.ctx = canvas.getContext("2d", { alpha: true, willReadFrequently: !!ar.readFreq });
    try { ar.ctx.drawImage(flat.canvas, 0, 0); } catch (e) { return null; }
    ar.canvas = canvas;
    ar.src = src;
    ar.stamp = "";
    ar.pendingUpload = true;
    return canvas;
  }
  function xrDrawDownscale(video, limit, chroma, slot) {
    if (!video || !video.videoWidth) return null;
    // CPU chroma reads every pixel. The headset keys on the GPU; this cap is the
    // flat preview and the blit-failure fallback. Preview stays smaller so the page does not hitch.
    if (chroma && slot !== "ar" && limit > 1280) limit = 1280;
    if (chroma && limit > 2048) limit = 2048;
    var bag = xrSlotBag(slot);
    var canvasId = slot === "ar" ? "xr-ds-ar" : "xr-ds-canvas";
    var canvas = bag.canvas || document.getElementById(canvasId);
    if (!canvas) {
      canvas = document.createElement("canvas");
      canvas.id = canvasId;
      canvas.width = 16;
      canvas.height = 16;
      document.body.appendChild(canvas);
    }
    var wantRead = !!chroma;
    if (!bag.ctx || (wantRead && !bag.readFreq)) {
      if (bag.ctx && wantRead && !bag.readFreq) {
        var fresh = document.createElement("canvas");
        fresh.id = canvasId;
        if (canvas.parentNode) canvas.parentNode.replaceChild(fresh, canvas);
        else document.body.appendChild(fresh);
        canvas = fresh;
        bag.ctx = null;
      }
      bag.ctx = canvas.getContext("2d", { alpha: true, willReadFrequently: wantRead });
      bag.readFreq = wantRead;
    }
    bag.canvas = canvas;
    var srcNow = xrVideoSrc(video);
    if (bag.src && bag.src !== srcNow) xrClearBagPixels(bag);
    bag.canvas = canvas;
    var scale = Math.min(limit / video.videoWidth, limit / video.videoHeight, 1);
    var cw = Math.max(2, Math.floor(video.videoWidth * scale / 2) * 2);
    var ch = Math.max(2, Math.floor(video.videoHeight * scale / 2) * 2);
    var stamp = (video.currentTime || 0).toFixed(3) + "|" + cw + "x" + ch + "|" + (chroma ? ("c" + (chroma.keyColor || "")) : "o") + "|" + srcNow;
    if (bag.stamp === stamp && canvas.width === cw && bag.src === srcNow) return canvas;
    if (canvas.width !== cw || canvas.height !== ch) {
      canvas.width = cw;
      canvas.height = ch;
    }
    try {
      bag.ctx.drawImage(video, 0, 0, cw, ch);
    } catch (e1) {
      return null;
    }
    if (chroma) {
      xrApplyChromaKey(bag.ctx, cw, ch, chroma.keyColor, chroma.similarity, chroma.smoothness);
    }
    bag.stamp = stamp;
    bag.src = srcNow;
    bag.pendingUpload = true;
    return canvas;
  }


  /**
   * GPU chroma key. A-Frame owns the video texture (a hand-made VideoTexture shader stays black on Quest).
   * No canvas readback — that read was stalling AR playback and Enter VR.
   */
  AFRAME.registerShader("xr-chroma", {
    schema: {
      src: { type: "map", is: "uniform" },
      keyColor: { type: "color", is: "uniform", default: "#00ff00" },
      similarity: { type: "number", is: "uniform", default: 0.3 },
      smoothness: { type: "number", is: "uniform", default: 0.08 }
    },
    vertexShader: [
      "varying vec2 vUv;",
      "void main() {",
      "  vUv = uv;",
      "  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);",
      "}"
    ].join("\n"),
    fragmentShader: [
      "uniform sampler2D src;",
      "uniform vec3 keyColor;",
      "uniform float similarity;",
      "uniform float smoothness;",
      "varying vec2 vUv;",
      "void main() {",
      "  vec4 videoColor = texture2D(src, vUv);",
      "  float cr = 0.5 * videoColor.r - 0.4187 * videoColor.g - 0.0813 * videoColor.b;",
      "  float cb = -0.1687 * videoColor.r - 0.3313 * videoColor.g + 0.5 * videoColor.b;",
      "  float keyCr = 0.5 * keyColor.r - 0.4187 * keyColor.g - 0.0813 * keyColor.b;",
      "  float keyCb = -0.1687 * keyColor.r - 0.3313 * keyColor.g + 0.5 * keyColor.b;",
      "  float dist = sqrt((cr - keyCr) * (cr - keyCr) + (cb - keyCb) * (cb - keyCb));",
      "  float blend = smoothstep(similarity, similarity + smoothness, dist);",
      "  gl_FragColor = vec4(videoColor.rgb, blend);",
      "}"
    ].join("\n")
  });
  (function () {
    var shader = AFRAME.shaders && AFRAME.shaders["xr-chroma"];
    if (!shader || !shader.prototype || !shader.prototype.init) return;
    var baseInit = shader.prototype.init;
    shader.prototype.init = function (data) {
      baseInit.call(this, data);
      if (!this.material) return;
      this.material.transparent = true;
      this.material.depthWrite = false;
      this.material.toneMapped = false;
      this.material.side = THREE.DoubleSide;
      this.material.alphaTest = 0.08;
    };
  })();

  /**
   * eye: "left" | "right" | "both"
   * SBS VR (Quest and PC): left dome on layer 1, right dome on layer 2. three.js WebXR
   * renders layer 1 only in the left eye and layer 2 only in the right eye, so no
   * per-draw eye detection is needed. AR and mono stay on layer 0 (left dome only).
   */
  AFRAME.registerComponent("chroma-stereo-sbs", {
    schema: {
      keyColor: { type: "color", default: "#00ff00" },
      similarity: { type: "number", default: 0.3 },
      smoothness: { type: "number", default: 0.08 },
      chroma: { type: "boolean", default: false },
      sbs: { type: "boolean", default: true },
      eye: { type: "string", default: "both" },
      // desktop = flat a-video for PC/magic-window; dome = immersive 180° hemisphere
      role: { type: "string", default: "dome" }
    },
    init: function () {
      this.video = document.querySelector("#chroma-stream");
      this._dsCanvas = null;
      this._dsTex = null;
      this._retries = 0;
      this._onApply = this.applyMaterial.bind(this);
      this._onEnterVr = function () {
        var self = this;
        self._yawLocked = false;
        self._poseFrames = 0;
        __xrDs.disposeToken = (__xrDs.disposeToken || 0) + 1;
        __xrDs.exiting = false;
        __xrDs.suspendBlit = false;
        // Drop the blit only when it belongs to another clip. Clearing it on every
        // Enter VR left the dome with no frame until the next blit landed.
        var srcNow = xrVideoSrc(self.video);
        if (__xrDs.resolvedSrc && __xrDs.resolvedSrc !== srcNow) {
          __xrDs.resolved = null;
          __xrDs.resolvedSrc = "";
          __xrDs.lastBlitTime = -1;
        }
        var keepRt = !!(__xrDs.resolved && __xrDs.resolvedSrc === srcNow);
        var seeded = null;
        try { xrForgetStaleCanvases(self.video); } catch (eBag) {}
        // A canvas copy of AV1 is the decoder tile atlas. Keep the blit instead.
        if (!keepRt) {
          try { seeded = xrSeedArFromFlat(self.video); } catch (eSeed) {}
        }
        if (seeded && !self.isDesktopRole()) {
          self._dsCanvas = seeded;
          self._dsSrc = srcNow;
        }
        if (__xrDs.resumeAfterExit && self.video) {
          __xrDs.resumeAfterExit = false;
          try {
            var rp = self.video.play();
            if (rp && rp.catch) rp.catch(function () {});
          } catch (ePlay) {}
        }
        if (__xrVideoTex && (keepRt || (__xrDs.av1Known && __xrDs.av1 === true) || !!self.data.chroma)) {
          try { __xrVideoTex.needsUpdate = true; } catch (eTex) {}
        }
        self._mode = "";
        self._gpuSig = "";
        self._uvZoom = null;
        self._uvEyeApplied = null;
        try { xrLog("enter-vr", { eye: self.data.eye, role: self.data.role, ar: self.isArMode(), seeded: !!seeded, rt: keepRt }); } catch (eL) {}
        function kick() {
          try { self.applySbsUVs(); } catch (eUv) {}
          self.applyMaterial();
          self.syncEyeLayers();
        }
        // Quest AR session startup often resets layers/materials — re-bind a few times.
        kick();
        setTimeout(kick, 50);
        setTimeout(kick, 250);
        setTimeout(kick, 800);
        if (self.data.eye === "left") {
          __xrDs._probeTicks = 0;
          __xrDs._xrFixes = 0;
          setTimeout(function () { self.logXrProbe("1.5s"); }, 1500);
          setTimeout(function () { self.logXrProbe("4s"); }, 4000);
        }
      }.bind(this);
      this._onExitVr = function () {
        // Stop AV1/canvas GPU work first. Never applyMaterial / dispose RT while
        // WebXR is still tearing down — that kills Quest Browser after AV1→HEVC.
        __xrDs.exiting = true;
        __xrDs.suspendBlit = true;
        try { xrLog("exit-vr begin", { eye: this.data.eye, sawAv1: !!__xrDs.sawAv1Tex }); } catch (eL0) {}
        xrSuspendAv1Pipeline();
        __xrDs.exiting = true;
        __xrDs.suspendBlit = true;
        this._yawLocked = false;
        this._poseFrames = 0;
        this._mode = "";
        this._gpuSig = "";
        // Pause only through teardown. The blit stays alive for the next Enter VR.
        if (__xrDs.sawAv1Tex && this.video && !this.video.paused) {
          __xrDs.resumeAfterExit = true;
          try { this.video.pause(); } catch (eP) {}
        }
        try { this.syncEyeLayers(); } catch (eLay) {}
        var self = this;
        setTimeout(function () {
          if (xrIsPresenting()) return;
          __xrDs.exiting = false;
          __xrDs.suspendBlit = false;
          try { xrLog("exit-vr settled"); } catch (eL1) {}
          if (__xrDs.resumeAfterExit && self.video) {
            __xrDs.resumeAfterExit = false;
            try {
              var rp = self.video.play();
              if (rp && rp.catch) rp.catch(function () {});
            } catch (eR) {}
          }
          try { self.applyMaterial(); } catch (eMat) {}
        }, 900);
      }.bind(this);
      this.el.addEventListener("object3dset", this._onApply);
      this.el.addEventListener("materialtextureloaded", this._onApply);
      if (this.el.sceneEl) {
        this.el.sceneEl.addEventListener("loaded", this._onApply);
        this.el.sceneEl.addEventListener("enter-vr", this._onEnterVr);
        this.el.sceneEl.addEventListener("exit-vr", this._onExitVr);
      }
      if (this.video) {
        this.video.addEventListener("loadeddata", this._onApply);
        this.video.addEventListener("loadedmetadata", this._onApply);
        this.video.addEventListener("play", this._onApply);
      }
      this.ensureDomeGeometry();
      this.applyMaterial();
    },
    update: function () {
      this.ensureDomeGeometry();
      this.applyMaterial();
      this.syncEyeLayers();
    },
    remove: function () {
      this.el.removeEventListener("object3dset", this._onApply);
      this.el.removeEventListener("materialtextureloaded", this._onApply);
      if (this.el.sceneEl) {
        this.el.sceneEl.removeEventListener("enter-vr", this._onEnterVr);
        this.el.sceneEl.removeEventListener("exit-vr", this._onExitVr);
      }
      try { if (this._dsTex) this._dsTex.dispose(); } catch (e) {}
    },
    tick: function () {
      if (this.data.eye === "left") {
        __xrDs._probeTicks = (__xrDs._probeTicks || 0) + 1;
        this.ensureXrEnabled();
      }
      var quest = this.isQuestBrowser();
      // Uploading the video texture on the flat page steals Quest's only WebGL consumer,
      // so the preview element stays blank while the shader draws nothing.
      if (__xrVideoTex && this.isImmersiveStereo() && !__xrDs.suspendBlit && !__xrDs.exiting
          && ((__xrDs.av1Known && __xrDs.av1 === true) || (quest && !!this.data.chroma))) {
        __xrVideoTex.needsUpdate = true;
      }
      var flatOverlay = false;
      if (this.isDesktopRole()) {
        if (this.isImmersiveStereo()) {
          if (this.video) this.video.classList.remove("xr-flat-preview");
          var offCanvas = document.getElementById("xr-ds-canvas");
          if (offCanvas) {
            offCanvas.classList.remove("xr-keyed-preview");
            offCanvas.style.cssText = "";
          }
        } else {
          // A fullscreen <video> takes the AV1 preview path on every browser, with Chroma
          // on or off: Quest would blank it on a WebGL upload, and PC would keep updating
          // a plane nobody can see.
          var videoFull = this.videoIsFullscreen();
          var showKeyed = quest && !!this.data.chroma && !videoFull;
          var showVideo = videoFull || (quest && !showKeyed && __xrDs.av1Known && __xrDs.av1 === true);
          flatOverlay = !!(showKeyed || showVideo);
          if (!showKeyed) {
            var offKeyed = document.getElementById("xr-ds-canvas");
            if (offKeyed) {
              offKeyed.classList.remove("xr-keyed-preview");
              offKeyed.style.cssText = "";
            }
          }
          if (this.video && !showKeyed) this.video.classList.toggle("xr-flat-preview", !!showVideo);
          if (showVideo) this._mode = "flat-video";
          if (this.el.object3D) this.el.object3D.visible = !flatOverlay;
        }
      }
      // Probe AV1 even with Chroma on — keyed AV1 still needs the full-frame blit.
      if (quest && this.video) xrWatchAv1(this.video);
      this.followHead();
      if (__xrDs.needsMaterialKick) {
        // The flat player ticks first. Leave the flag for a dome or the kick never reaches AR.
        if (!this.isDesktopRole()) __xrDs.needsMaterialKick = false;
        try { this.applyMaterial(); } catch (eKick) {}
      }
      var av1Immersive = quest && this.isImmersiveStereo()
        && !__xrDs.suspendBlit
        && __xrDs.av1Known && __xrDs.av1 === true;
      // HEVC chroma uses the same blit. The canvas readback stuttered, and the
      // video-texture chroma shader stays black on Quest (preview and AR).
      var questGpu = av1Immersive || (
        quest && this.isImmersiveStereo() && !__xrDs.suspendBlit && !__xrDs.exiting && !!this.data.chroma
      );
      var flatChroma = quest && this.isDesktopRole() && !this.isImmersiveStereo() && this.data.chroma
        && this.drawsSharedFrame() && !__xrDs.exiting && !__xrDs.suspendBlit && !this.videoIsFullscreen();
      if (flatChroma) {
        var prevRenderer = this.el.sceneEl && this.el.sceneEl.renderer;
        var previewFrame = xrKeyedPreviewCanvas(prevRenderer, this.video, this.chromaArgs());
        if (!previewFrame && !(__xrDs.av1Known && __xrDs.av1 === true)) {
          previewFrame = xrDrawDownscale(this.video, this.downscaleTarget(), this.chromaArgs(), "flat");
        }
        var keyedEl = document.getElementById("xr-ds-canvas");
        if (previewFrame && keyedEl && keyedEl.width > 16) {
          keyedEl.classList.add("xr-keyed-preview");
          keyedEl.style.position = "fixed";
          keyedEl.style.left = "0";
          keyedEl.style.top = "0";
          keyedEl.style.width = "100vw";
          keyedEl.style.height = "calc(100vh - 6.5rem)";
          keyedEl.style.maxHeight = "none";
          keyedEl.style.opacity = "1";
          keyedEl.style.zIndex = "2";
          keyedEl.style.objectFit = "contain";
          keyedEl.style.background = "#111";
          if (this.video) this.video.classList.remove("xr-flat-preview");
          this._mode = "canvas";
        } else {
          if (keyedEl) {
            keyedEl.classList.remove("xr-keyed-preview");
            keyedEl.style.cssText = "";
          }
          if (this.video) this.video.classList.add("xr-flat-preview");
          try { if (__xrVideoTex) __xrVideoTex.needsUpdate = false; } catch (eHold) {}
          this._mode = "flat-video";
        }
      } else if (questGpu && this.drawsSharedFrame()) {
        var renderer = this.el.sceneEl && this.el.sceneEl.renderer;
        var v = this.video;
        var t = v ? v.currentTime : -1;
        var blitSrc = xrVideoSrc(v);
        // Blit only when the decoder advances — tick is faster than the video.
        if (__xrDs.resolved && __xrDs.resolvedSrc === blitSrc && __xrDs.lastBlitTime === t) {
          this.applyAv1Resolve(__xrDs.resolved);
        } else {
          var resolved = xrBlitFullVideo(renderer, v);
          if (resolved) {
            __xrDs.resolved = resolved;
            __xrDs.resolvedSrc = blitSrc;
            __xrDs.lastBlitTime = t;
            this.applyAv1Resolve(resolved);
          } else if (__xrDs.resolved && __xrDs.resolvedSrc === blitSrc) {
            this.applyAv1Resolve(__xrDs.resolved);
          } else if (this.data.chroma) {
            var fallback = xrDrawDownscale(v, this.downscaleTarget(), this.chromaArgs(), "ar");
            if (fallback) this.applyPostAv1Canvas(fallback);
            else this.holdPreviewCanvas();
          }
        }
      } else if (questGpu && this.data.eye === "right" && __xrDs.resolved) {
        this.applyAv1Resolve(__xrDs.resolved);
      } else if (!flatOverlay && this.needsPostAv1Canvas() && this.drawsSharedFrame()) {
        var postSlot = this.isDesktopRole() ? "flat" : "ar";
        var postCanvas = xrDrawDownscale(this.video, this.downscaleTarget(), this.chromaArgs(), postSlot);
        if (postCanvas) this.applyPostAv1Canvas(postCanvas);
        else if (this._dsCanvas && this._dsSrc === xrVideoSrc(this.video)) this.applyPostAv1Canvas(this._dsCanvas);
      } else if (!flatOverlay && this._mode === "canvas" && this.drawsSharedFrame()) {
        this.refreshDownscaleCanvas(true);
      }
      try {
        var mesh = this.el.getObject3D("mesh");
        var frameBag = xrSlotBag(this.isDesktopRole() ? "flat" : "ar");
        var mat = mesh && mesh.material;
        var tex = (mat && mat.uniforms && mat.uniforms.src && mat.uniforms.src.value) || (mat && mat.map);
        var upload = this._mode === "canvas" ? true : (this._mode !== "av1rt" && this._mode !== "gpu");
        if (this._mode === "gpu" && tex) upload = true;
        if (this.video && this.video.classList.contains("xr-flat-preview")) upload = false;
        if (upload && tex) {
          tex.needsUpdate = true;
          if (this._mode === "canvas") frameBag.pendingUpload = false;
        }
        if (this.isDesktopRole() && this.el.object3D && !this.isImmersiveStereo()) {
          var keyedOn = false;
          try {
            var keyedNode = document.getElementById("xr-ds-canvas");
            keyedOn = !!(keyedNode && keyedNode.classList.contains("xr-keyed-preview"));
          } catch (eKeyVis) {}
          var videoOn = !!(this.video && this.video.classList.contains("xr-flat-preview"));
          this.el.object3D.visible = !(keyedOn || videoOn);
        }
      } catch (eTick) {}
      // Eye layers change only with the session, a material bind, or the dome mesh.
      // Those paths call syncEyeLayers; it is not polled here.
    },
    followHead: function () {
      if (this.isDesktopRole() || !this.isImmersiveStereo()) return;
      var sceneEl = this.el.sceneEl;
      var cam = sceneEl && sceneEl.camera;
      var obj = this.el.object3D;
      if (!cam || !obj) return;
      try {
        if (!this._seatPos) this._seatPos = new THREE.Vector3();
        cam.getWorldPosition(this._seatPos);
        obj.position.copy(this._seatPos);
        // AR's reference yaw is not VR's. Lock once to the headset heading so the
        // 180 opening is in front of the user instead of the previous session's -Z.
        if (!this.isArMode() && !this._yawLocked) {
          var xrRef = sceneEl.renderer && sceneEl.renderer.xr;
          var head = xrRef && xrRef.getCamera && xrRef.getCamera();
          var stereo = !!(xrRef && xrRef.isPresenting && head && head.cameras && head.cameras.length >= 2);
          if (stereo) {
            this._poseFrames = (this._poseFrames || 0) + 1;
            if (this._poseFrames >= 8) {
              if (!this._yawEuler) this._yawEuler = new THREE.Euler(0, 0, 0, "YXZ");
              this._yawEuler.setFromQuaternion(head.quaternion, "YXZ");
              this._lockedYaw = this._yawEuler.y;
              this._yawLocked = true;
              try {
                xrLog("dome-yaw", {
                  yaw: Math.round(this._lockedYaw * 180 / Math.PI),
                  frames: this._poseFrames
                });
              } catch (eYaw) {}
            }
          }
        }
        var yaw = (!this.isArMode() && this._yawLocked) ? (this._lockedYaw || 0) : 0;
        obj.rotation.set(0, yaw, 0);
        var dist = this.domeDistance();
        if (dist > 0) obj.translateZ(-dist);
      } catch (eFollow) {}
    },
    videoIsFullscreen: function () {
      return !!this.video && document.fullscreenElement === this.video;
    },
    isDesktopRole: function () {
      return this.data.role === "desktop" || this.data.eye === "both";
    },
    drawsSharedFrame: function () {
      if (this.data.eye === "right") return false;
      if (this.isImmersiveStereo() && this.isDesktopRole()) return false;
      if (!this.isImmersiveStereo() && !this.isDesktopRole()) return false;
      return true;
    },
    chromaArgs: function () {
      if (!this.data.chroma) return null;
      var key = "#00ff00";
      try { key = "#" + new THREE.Color(this.data.keyColor).getHexString(); } catch (eKey) {}
      return { keyColor: key, similarity: this.data.similarity, smoothness: this.data.smoothness };
    },
    // Show the current preview canvas until an AV1 blit exists. Returning with no
    // material is what left Enter VR black.
    holdPreviewCanvas: function () {
      var now = xrVideoSrc(this.video);
      if (__xrDs.resolved && __xrDs.resolvedSrc === now) {
        this.applyAv1Resolve(__xrDs.resolved);
        return true;
      }
      // drawImage of an AV1 <video> is the tile atlas, not the picture.
      if (__xrDs.av1Known && __xrDs.av1 === true) return false;
      var hold = (this._dsSrc === now) ? this._dsCanvas : null;
      if (!hold) {
        var flat = xrSlotBag("flat");
        if (flat.src === now && flat.canvas) hold = flat.canvas;
      }
      if (!hold) return false;
      this._dsCanvas = hold;
      this._dsSrc = now;
      this.applyCanvasVideo();
      return true;
    },
    isQuestBrowser: function () {
      try {
        return /OculusBrowser|Quest|Pacific/i.test(navigator.userAgent || "");
      } catch (e) {
        return false;
      }
    },
    domeZoom: function () {
      var z = Number(window.__xrZoom);
      if (!(z > 0)) z = 1;
      return Math.max(0.4, Math.min(1, z));
    },
    domeDistance: function () {
      var d = Number(window.__xrDist);
      if (!(d > 0)) return 0;
      return Math.max(0, Math.min(12, d));
    },
    // Arc Zoom packs the whole frame onto a shorter FOV. Dist (Skybox-style)
    // leaves the 180° shell alone and only moves it farther from the head.
    domeAngles: function () {
      var zoom = this.isDesktopRole() ? 1 : this.domeZoom();
      var span = Math.PI * zoom;
      return {
        phiLen: span,
        thetaLen: span,
        phiStart: (Math.PI * 1.5) - span / 2,
        thetaStart: (Math.PI - span) / 2
      };
    },
    // A-Frame videosphere ignored phi-length → VR180 stretched to 360. Own the BufferGeometry.
    ensureDomeGeometry: function () {
      if (this.isDesktopRole()) return;
      var mesh = this.el.getObject3D("mesh");
      if (!mesh) return;
      var zoom = this.domeZoom();
      var ready = mesh.geometry && mesh.geometry.userData && mesh.geometry.userData._xrHemi;
      if (ready && this._domeGeoReady && this._domeZoom === zoom) return;
      try {
        var old = mesh.geometry;
        // Zoom 1 is a 180° hemisphere. Lower values pack the full frame into a smaller arc.
        var ang = this.domeAngles();
        var phiLen = ang.phiLen;
        var thetaLen = ang.thetaLen;
        var phiStart = ang.phiStart;
        var thetaStart = ang.thetaStart;
        var geo = new THREE.SphereGeometry(20, 80, 60, phiStart, phiLen, thetaStart, thetaLen);
        geo.userData._xrHemi = true;
        mesh.geometry = geo;
        if (old && old !== geo) {
          try { old.dispose(); } catch (e0) {}
        }
        // Keep A-Frame's geometry component in sync so it does not regenerate a 360° sphere.
        try {
          if (this.el.components.geometry) {
            this.el.components.geometry.geometry = geo;
            var gd = this.el.components.geometry.data;
            gd.phiStart = phiStart * 180 / Math.PI;
            gd.phiLength = phiLen * 180 / Math.PI;
            gd.thetaStart = thetaStart * 180 / Math.PI;
            gd.thetaLength = thetaLen * 180 / Math.PI;
            gd.radius = 20;
          }
        } catch (eSync) {}
        // Negative X = inward-facing + correct equirect UV orientation for VR180.
        this.el.object3D.scale.set(-1, 1, 1);
        try { this.el.setAttribute("scale", "-1 1 1"); } catch (eAttr) {}
        this._domeGeoReady = true;
        this._domeZoom = zoom;
        mesh.traverse(function (node) {
          if (node.geometry && node.geometry.userData) {
            delete node.geometry.userData._xrBaseUv;
          }
        });
        this.applySbsUVs();
      } catch (e) {}
    },
    maxWebGLTextureSize: function () {
      var maxTex = 4096;
      try {
        var r = this.el.sceneEl && this.el.sceneEl.renderer;
        if (r && r.capabilities && r.capabilities.maxTextureSize) {
          maxTex = r.capabilities.maxTextureSize;
        }
      } catch (e) {}
      // Headroom — drivers often fail video uploads at the exact max.
      var limit = Math.max(512, maxTex - 64);
      // Quest 3 max texture is 8192+. 6K SBS already plays natively; only 8K needs a shrink.
      // Cap the native path at 6144 so 6K stays a video texture (AR can show it).
      if (this.isQuestBrowser()) limit = Math.min(limit, 6144);
      return limit;
    },
    downscaleTarget: function () {
      var maxTex = 4096;
      try {
        var r = this.el.sceneEl && this.el.sceneEl.renderer;
        if (r && r.capabilities && r.capabilities.maxTextureSize) {
          maxTex = r.capabilities.maxTextureSize;
        }
      } catch (e) {}
      // Quest 3 can upload a 4096 canvas in AR. 1536 was crushing both clips and still blanked AR.
      var cap = this.isQuestBrowser() ? 4096 : Math.max(512, maxTex - 64);
      return Math.min(cap, Math.max(512, maxTex - 64));
    },
    setTexNote: function (msg) {
      try { window.__xrTexNote = msg || ""; } catch (e) {}
      var el = document.getElementById("xr-tex-note");
      if (!el) return;
      if (msg) {
        el.hidden = false;
        el.textContent = msg;
      } else {
        el.hidden = true;
        el.textContent = "";
      }
    },
    // Quest/PC: huge SBS exceeds reliable WebGL video tex size → shared canvas texture.
    refreshDownscaleCanvas: function (onlyUpdate) {
      var video = this.video;
      if (!video) return null;
      if (!video.videoWidth) {
        if (!onlyUpdate && video.readyState >= 1) {
          this.setTexNote("No decoded frames yet — codec may be unsupported here");
        }
        return null;
      }
      var slot = this.isDesktopRole() ? "flat" : "ar";
      var limit = this.maxWebGLTextureSize();
      var needsScale = video.videoWidth > limit || video.videoHeight > limit;
      // Chroma is a GPU key. This canvas is only a size shrink, never a pixel readback.
      if (!needsScale) {
        if (!onlyUpdate) this.setTexNote("");
        try { if (video) video.classList.remove("xr-pip"); } catch (e0) {}
        return null;
      }
      var srcNow = xrVideoSrc(video);
      if (!this.drawsSharedFrame()) {
        var existingBag = xrSlotBag(slot);
        var existing = (existingBag.src === srcNow) ? existingBag.canvas : null;
        if (!existing && slot === "ar") {
          var flatBag = xrSlotBag("flat");
          if (flatBag.src === srcNow) existing = flatBag.canvas;
        }
        this._dsCanvas = existing || null;
        this._dsSrc = existing ? srcNow : "";
        return this._dsCanvas;
      }
      var target = this.downscaleTarget();
      var canvas = xrDrawDownscale(video, target, this.chromaArgs(), slot);
      if (!canvas && slot === "ar") {
        var flatOk = xrSlotBag("flat");
        if (flatOk.src === srcNow && flatOk.canvas) {
          canvas = flatOk.canvas;
          // Dome samples the live preview canvas when the immersive copy fails.
          xrSlotBag("ar").pendingUpload = true;
        }
      }
      if (canvas) {
        this._dsCanvas = canvas;
        this._dsSrc = srcNow;
      } else if (this._dsSrc !== srcNow) {
        this._dsCanvas = null;
        this._dsSrc = "";
      }
      if (!canvas) {
        try { video.classList.add("xr-pip"); } catch (e2) {}
        if (!onlyUpdate) this.setTexNote("8K WebGL downscale failed — HTML preview");
        return null;
      }
      if (!onlyUpdate) {
        try { video.classList.remove("xr-pip"); } catch (e5) {}
        this.setTexNote(
          "Downscaling "
          + video.videoWidth + "×" + video.videoHeight
          + " → " + canvas.width + "×" + canvas.height
        );
      }
      return canvas;
    },
    // three allocates a canvas texture once, at its first size, and never grows it. The
    // shared canvas jumps from 1280 (chroma preview) to 4096 (plain clip), and those frames
    // no longer fit: black preview, blank dome. dispose() makes three allocate again.
    resetCanvasTexture: function (sizeKey) {
      var comp = this.el.components && this.el.components.material;
      var mat = comp && comp.material;
      var map = mat && mat.map;
      if (!map || !sizeKey) return;
      var from = map.userData._xrSize;
      if (from === sizeKey) return;
      map.userData._xrSize = sizeKey;
      try { map.dispose(); } catch (eDisp) {}
      map.needsUpdate = true;
      mat.needsUpdate = true;
      if (!from) return;
      try {
        xrLog("canvas-tex-reset", { role: this.data.role, eye: this.data.eye, from: from, to: sizeKey, presenting: !!xrIsPresenting() });
      } catch (eLog) {}
    },
    applyCanvasVideo: function () {
      this.ensureDomeGeometry();
      this.applySbsUVs();
      var canvas = this._dsCanvas;
      var src = (canvas && canvas.id) ? ("#" + canvas.id) : (this.isDesktopRole() ? "#xr-ds-canvas" : "#xr-ds-ar");
      var sizeKey = canvas ? (canvas.width + "x" + canvas.height) : "";
      var chromaOn = !!this.data.chroma;
      if (this._mode === "canvas" && this._canvasSrc === src && this._canvasSize === sizeKey) return true;
      this._mode = "canvas";
      this._canvasSrc = src;
      this._canvasSize = sizeKey;
      // A-Frame canvas material. Chroma alpha is punched in the canvas (the VideoTexture shader stays black on Quest).
      try {
        this.el.setAttribute("material", {
          shader: "flat",
          src: src,
          color: "#ffffff",
          side: "double",
          transparent: chromaOn,
          opacity: 1,
          depthWrite: !chromaOn,
          alphaTest: chromaOn ? 0.08 : 0,
          npot: true
        });
      } catch (e) {}
      try {
        var mesh = this.el.getObject3D("mesh");
        if (mesh && mesh.material && mesh.material.map) mesh.material.map.needsUpdate = true;
      } catch (e2) {}
      this.restoreAFrameMaterial();
      this.resetCanvasTexture(sizeKey);
      if (this.isDesktopRole() && this.el.object3D && !this.isImmersiveStereo()) {
        this.el.object3D.visible = true;
      }
      this.syncEyeLayers();
      return true;
    },
    needsPostAv1Canvas: function () {
      // After an AV1 blit, Quest VideoTexture stays black for the rest of the page.
      // Use a 2D canvas copy (A-Frame flat/chroma material) for flat + immersive.
      if (!this.isQuestBrowser() || !__xrDs.sawAv1Tex) return false;
      if (__xrDs.exiting || __xrDs.suspendBlit) return false;
      if (__xrDs.av1Known && __xrDs.av1 === true) return false;
      // Immersive chroma is the blit shader. A per-frame canvas readback is what stuttered HEVC.
      if (this.data.chroma && this.isImmersiveStereo()) return false;
      if (this.isDesktopRole()) return !this.isImmersiveStereo();
      return this.isImmersiveStereo();
    },
    applyPostAv1Canvas: function (canvas) {
      if (!canvas) return false;
      this._dsCanvas = canvas;
      // A-Frame canvas material — ShaderMaterial on the flat preview was black on Quest.
      this.applyCanvasVideo();
      var video = this.video;
      var src = (video && (video.currentSrc || video.src)) || "";
      if (video && video.videoWidth) {
        this.setTexNote("post-AV1 canvas " + video.videoWidth + "×" + video.videoHeight
          + (this.data.chroma ? " + chroma" : ""));
      }
      // Tick calls this every frame. One line per role/eye/size/clip, or the ring
      // fills with duplicates and drops enter-vr.
      var sig = (this.data.role || "") + "|" + (this.data.eye || "") + "|"
        + canvas.width + "x" + canvas.height + "|" + (this.data.chroma ? "1" : "0") + "|" + src;
      if (this._postAv1Log === sig) return true;
      this._postAv1Log = sig;
      try { xrLog("post-av1-canvas", { role: this.data.role, eye: this.data.eye, w: canvas.width, h: canvas.height }); } catch (eL) {}
      return true;
    },
    // One line per check, so the first VR after AR can be compared with the second.
    // The dome and blit fields separate "not drawn" from "drawn with a black frame".
    // The first VR after AR starts with xr.enabled false, so three never renders through
    // the headset cameras: black, with no head tracking. /xr does not cause it (HEVC with
    // no blit does the same). A-Frame clears the flag just before exit-vr, and exit-vr
    // sets __xrDs.exiting, so this never turns XR back on during teardown.
    ensureXrEnabled: function () {
      var renderer = this.el.sceneEl && this.el.sceneEl.renderer;
      var xr = renderer && renderer.xr;
      if (!xr || !xr.isPresenting || xr.enabled || __xrDs.exiting || __xrDs.blitting) return;
      xr.enabled = true;
      __xrDs._xrFixes = (__xrDs._xrFixes || 0) + 1;
      if (__xrDs._xrFixes <= 3) {
        try {
          xrLog("xr-enabled-fixed", { ticks: __xrDs._probeTicks || 0, n: __xrDs._xrFixes, ar: this.isArMode() });
        } catch (eLog) {}
      }
    },
    logXrProbe: function (tag) {
      var sceneEl = this.el.sceneEl;
      var renderer = sceneEl && sceneEl.renderer;
      var xr = renderer && renderer.xr;
      if (!xr || !xr.isPresenting) return;
      var out = { at: tag, ticks: __xrDs._probeTicks || 0, xrOn: !!xr.enabled, fixes: __xrDs._xrFixes || 0 };
      try {
        var session = xr.getSession && xr.getSession();
        var state = session && session.renderState;
        out.blend = session && session.environmentBlendMode;
        out.vis = session && session.visibilityState;
        out.base = !!(state && state.baseLayer);
        out.projLayers = state && state.layers ? state.layers.length : 0;
        var xrCam = xr.getCamera();
        var cams = (xrCam && xrCam.cameras) || [];
        out.masks = [xrCam ? xrCam.layers.mask : 0].concat(cams.map(function (c) { return c.layers.mask; }));
        out.clearA = renderer.getClearAlpha();
        var bg = sceneEl.object3D.background;
        out.bg = bg && bg.getHexString ? bg.getHexString() : null;
        var sky = document.getElementById("virtual-sky");
        out.sky = !!(sky && sky.object3D && sky.object3D.visible);
      } catch (eSession) { out.sessionErr = String(eSession); }
      out.domes = ["chroma-sphere", "chroma-sphere-right"].map(function (id) {
        var el = document.getElementById(id);
        var comp = el && el.components && el.components["chroma-stereo-sbs"];
        var mesh = el && el.getObject3D("mesh");
        var mat = mesh && mesh.material;
        var tex = mat && (mat.map || (mat.uniforms && mat.uniforms.tex && mat.uniforms.tex.value));
        var img = tex && tex.image;
        return {
          obj: !!(el && el.object3D.visible),
          mesh: !!(mesh && mesh.visible),
          mask: mesh ? mesh.layers.mask : 0,
          mode: (comp && comp._mode) || "",
          mat: mat ? mat.type : "",
          op: mat ? mat.opacity : -1,
          tr: !!(mat && mat.transparent),
          tex: !!tex,
          img: img ? (img.videoWidth || img.width || 0) : 0,
          verts: mesh && mesh.geometry && mesh.geometry.attributes.position ? mesh.geometry.attributes.position.count : 0,
          pos: el ? el.object3D.position.toArray().map(function (n) { return Math.round(n * 10) / 10; }) : []
        };
      });
      var video = this.video;
      if (video) {
        out.video = { paused: !!video.paused, ready: video.readyState, t: Math.round((video.currentTime || 0) * 10) / 10 };
      }
      out.blitT = __xrDs.lastBlitTime;
      try {
        if (__xrDs.rt && __xrDs.resolved) {
          var px = new Uint8Array(4);
          renderer.readRenderTargetPixels(__xrDs.rt, Math.floor(__xrDs.rtW / 4), Math.floor(__xrDs.rtH / 2), 1, 1, px);
          out.rtPx = Array.prototype.slice.call(px);
        }
      } catch (ePx) { out.rtPxErr = String(ePx); }
      try { xrLog("xr-probe", out); } catch (eLog) {}
    },
    applyAv1Resolve: function (tex) {
      this.ensureDomeGeometry();
      var zoom = this.isDesktopRole() ? 1 : this.domeZoom();
      if (this._uvZoom !== zoom || this._uvEyeApplied !== this.data.eye) {
        this.applySbsUVs();
        this._uvZoom = zoom;
        this._uvEyeApplied = this.data.eye;
      }
      var mesh = this.el.getObject3D("mesh");
      if (!mesh || !tex) return;
      // Sample the blitted full frame (not the Quest AV1 tile atlas). Optional GPU key.
      var chromaOn = !!this.data.chroma;
      var keyCol = new THREE.Color("#00ff00");
      try { keyCol = new THREE.Color(this.data.keyColor); } catch (eKey) {}
      if (!this._av1Mat) {
        this._av1Mat = new THREE.ShaderMaterial({
          uniforms: {
            tex: { value: tex },
            keyColor: { value: keyCol },
            similarity: { value: this.data.similarity },
            smoothness: { value: this.data.smoothness },
            chromaEnabled: { value: chromaOn ? 1.0 : 0.0 }
          },
          vertexShader: "varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }",
          fragmentShader: [
            "uniform sampler2D tex;",
            "uniform vec3 keyColor;",
            "uniform float similarity;",
            "uniform float smoothness;",
            "uniform float chromaEnabled;",
            "varying vec2 vUv;",
            "void main(){",
            "  vec4 videoColor = texture2D(tex, vUv);",
            "  if (chromaEnabled < 0.5) { gl_FragColor = videoColor; return; }",
            "  float cr = 0.5 * videoColor.r - 0.4187 * videoColor.g - 0.0813 * videoColor.b;",
            "  float cb = -0.1687 * videoColor.r - 0.3313 * videoColor.g + 0.5 * videoColor.b;",
            "  float keyCr = 0.5 * keyColor.r - 0.4187 * keyColor.g - 0.0813 * keyColor.b;",
            "  float keyCb = -0.1687 * keyColor.r - 0.3313 * keyColor.g + 0.5 * keyColor.b;",
            "  float dist = sqrt((cr - keyCr) * (cr - keyCr) + (cb - keyCb) * (cb - keyCb));",
            "  float blend = smoothstep(similarity, similarity + smoothness, dist);",
            "  gl_FragColor = vec4(videoColor.rgb * blend, blend);",
            "}"
          ].join("\n"),
          side: THREE.DoubleSide,
          toneMapped: false,
          transparent: chromaOn,
          premultipliedAlpha: chromaOn,
          depthWrite: !chromaOn,
          alphaTest: 0
        });
      } else {
        this._av1Mat.uniforms.tex.value = tex;
        this._av1Mat.uniforms.keyColor.value.copy(keyCol);
        this._av1Mat.uniforms.similarity.value = this.data.similarity;
        this._av1Mat.uniforms.smoothness.value = this.data.smoothness;
        this._av1Mat.uniforms.chromaEnabled.value = chromaOn ? 1.0 : 0.0;
        this._av1Mat.transparent = chromaOn;
        this._av1Mat.premultipliedAlpha = chromaOn;
        this._av1Mat.depthWrite = !chromaOn;
        this._av1Mat.alphaTest = 0;
      }
      var mat = this._av1Mat;
      this._gpuSig = "";
      if (this._mode !== "av1rt" || mesh.material !== mat) {
        mesh.traverse(function (node) {
          if (!node.isMesh) return;
          node.material = mat;
        });
      }
      if (this._mode !== "av1rt") {
        var video = this.video;
        this.setTexNote("AV1 full frame " + (video && video.videoWidth ? video.videoWidth : "?")
          + "×" + (video && video.videoHeight ? video.videoHeight : "?")
          + (chromaOn ? " + chroma" : ""));
        this._mode = "av1rt";
        this.syncEyeLayers();
      } else {
        this._mode = "av1rt";
      }
    },
    eyeLayer: function () {
      if (this.data.eye === "left") return 1;
      if (this.data.eye === "right") return 2;
      return 0;
    },
    isImmersiveStereo: function () {
      var sceneEl = this.el.sceneEl;
      if (!sceneEl) return false;
      try {
        if (sceneEl.is && (sceneEl.is("vr-mode") || sceneEl.is("ar-mode"))) return true;
      } catch (e) {}
      try {
        var xr = sceneEl.renderer && sceneEl.renderer.xr;
        if (xr && xr.isPresenting) return true;
      } catch (e2) {}
      return false;
    },
    applySbsUVs: function (eyeOverride) {
      var mesh = this.el.getObject3D("mesh");
      if (!mesh) return;
      var eye = eyeOverride || this.data.eye;
      var sbs = !!(this.data.sbs && !this.isDesktopRole());
      mesh.traverse(function (node) {
        if (!node.isMesh || !node.geometry || !node.geometry.attributes || !node.geometry.attributes.uv) return;
        var geo = node.geometry;
        if (!geo.userData) geo.userData = {};
        var uv = geo.attributes.uv;
        if (!geo.userData._xrBaseUv) {
          geo.userData._xrBaseUv = Float32Array.from(uv.array);
        }
        var base = geo.userData._xrBaseUv;
        var arr = uv.array;
        var u0 = 0;
        var uSpan = 1;
        if (sbs && eye === "left") uSpan = 0.5;
        else if (sbs && eye === "right") { u0 = 0.5; uSpan = 0.5; }
        for (var i = 0; i < arr.length; i += 2) {
          var u = base[i];
          var v = base[i + 1];
          arr[i] = u0 + uSpan * u;
          arr[i + 1] = v;
        }
        uv.needsUpdate = true;
      });
    },
    isArMode: function () {
      try {
        var sceneEl = this.el.sceneEl;
        return !!(sceneEl && sceneEl.is && sceneEl.is("ar-mode"));
      } catch (e) {
        return false;
      }
    },
    syncEyeLayers: function () {
      // Stereo VR: left dome on layer 1, right dome on layer 2. three.js WebXR enables
      // layer 1 only on the left eye camera and layer 2 only on the right one, so each
      // eye draws its own dome. The XR cameras are never edited here; their defaults
      // are what makes this work, and nothing carries over from an AR session.
      // AR, mono and not-yet-presenting: layer 0, left dome only (left half, both eyes).
      var mesh = this.el.getObject3D("mesh");
      var immersive = this.isImmersiveStereo();
      var desktop = this.isDesktopRole();
      var isAR = this.isArMode();
      var presenting = false;
      try {
        var sceneEl = this.el.sceneEl;
        presenting = !!(sceneEl && sceneEl.renderer && sceneEl.renderer.xr && sceneEl.renderer.xr.isPresenting);
      } catch (e0) {}
      var stereo = !desktop && immersive && presenting && !isAR && !!this.data.sbs;
      var layerBit = stereo ? this.eyeLayer() : 0;
      if (mesh) {
        mesh.traverse(function (node) {
          if (node && node.layers) node.layers.set(layerBit);
        });
      }
      if (this.el.object3D) this.el.object3D.layers.set(layerBit);
      var show;
      if (desktop) {
        // Flat a-video: PC / magic-window only. The HTML preview covers the page except
        // the bottom strip; leaving the plane on paints a second copy in that strip.
        show = !immersive;
        if (show && this.isQuestBrowser()) {
          var flatVid = !!(this.video && this.video.classList.contains("xr-flat-preview"));
          var keyedPrev = false;
          try {
            var keyedNode = document.getElementById("xr-ds-canvas");
            keyedPrev = !!(keyedNode && keyedNode.classList.contains("xr-keyed-preview"));
          } catch (ePlane) {}
          if (flatVid || keyedPrev) show = false;
        }
      } else if (this.data.eye === "right") {
        show = stereo;
      } else {
        // Domes are immersive only (an always-on left dome overlays the flat screen).
        show = immersive;
      }
      if (this.el.object3D) this.el.object3D.visible = show;
      var sig = layerBit + "|" + (show ? 1 : 0) + "|" + (isAR ? 1 : 0);
      if (!desktop && this._eyeLayerSig !== sig) {
        this._eyeLayerSig = sig;
        try { xrLog("eye-layers", { eye: this.data.eye, layer: layerBit, visible: show, ar: isAR }); } catch (eLog) {}
      }
    },
    bindMaterial: function (mat) {
      var mesh = this.el.getObject3D("mesh");
      if (!mesh || !mat) return false;
      mesh.traverse(function (node) {
        if (!node.isMesh) return;
        node.material = mat;
        try { delete node.onBeforeRender; } catch (eHook) {}
      });
      if (this.el.components.material) {
        this.el.components.material.material = mat;
      }
      this.syncEyeLayers();
      return true;
    },
    // AV1 puts a ShaderMaterial on the mesh directly. A later setAttribute("material")
    // with the same flat/chroma schema is a no-op, so the dome stays on the blit RT
    // and the next HEVC clip looks blank. Put A-Frame's material back on the mesh.
    restoreAFrameMaterial: function () {
      if (!(__xrDs.av1Known && __xrDs.av1 === false)) return false;
      var comp = this.el.components && this.el.components.material;
      var mat = comp && comp.material;
      if (!mat || mat === this._av1Mat) return false;
      var mesh = this.el.getObject3D("mesh");
      if (!mesh) return false;
      var av1Mat = this._av1Mat;
      var stuck = this._mode === "av1rt";
      mesh.traverse(function (node) {
        if (node.isMesh && av1Mat && node.material === av1Mat) stuck = true;
      });
      if (!stuck && mesh.material !== av1Mat) return false;
      try { if (mat.map) mat.map.needsUpdate = true; } catch (eMap) {}
      return this.bindMaterial(mat);
    },
    applyNativeVideo: function () {
      this._mode = "native";
      this._gpuSig = "";
      this.ensureDomeGeometry();
      this.applySbsUVs();
      // Desktop: keep A-Frame's own video material (VideoTexture MeshBasic was black on PC).
      // Domes (immersive-only callers): same attribute path once session starts.
      try {
        this.el.setAttribute("material", {
          shader: "flat",
          src: "#chroma-stream",
          color: "#ffffff",
          side: "double",
          transparent: false,
          npot: true
        });
      } catch (e) {}
      this.restoreAFrameMaterial();
      // Ensure flat screen is on after material bind (dome thrash used to leave it hidden/black).
      if (this.isDesktopRole() && this.el.object3D && !this.isImmersiveStereo()) {
        this.el.object3D.visible = true;
      }
      this.syncEyeLayers();
      return true;
    },
    applyGpuChroma: function (canvas) {
      this.ensureDomeGeometry();
      this.applySbsUVs();
      var src = (canvas && canvas.id) ? ("#" + canvas.id) : "#chroma-stream";
      var sizeKey = canvas ? (canvas.width + "x" + canvas.height) : "video";
      var key = "#00ff00";
      try { key = "#" + new THREE.Color(this.data.keyColor).getHexString(); } catch (eK) {}
      var sig = src + "|" + sizeKey + "|" + key + "|" + this.data.similarity + "|" + this.data.smoothness;
      if (this._gpuSig === sig && (this._mode === "gpu" || (canvas && this._mode === "canvas"))) return true;
      this._gpuSig = sig;
      this._dsCanvas = canvas || null;
      this._mode = canvas ? "canvas" : "gpu";
      this._canvasSrc = src;
      this._canvasSize = sizeKey;
      try {
        this.el.setAttribute("material", {
          shader: "xr-chroma",
          src: src,
          keyColor: key,
          similarity: this.data.similarity,
          smoothness: this.data.smoothness,
          side: "double",
          transparent: true,
          opacity: 1,
          depthWrite: false,
          alphaTest: 0.08,
          npot: true
        });
      } catch (e) {}
      try {
        var mesh = this.el.getObject3D("mesh");
        if (mesh && mesh.material) {
          mesh.material.transparent = true;
          mesh.material.depthWrite = false;
          mesh.material.toneMapped = false;
          if ("alphaTest" in mesh.material) mesh.material.alphaTest = 0.08;
        }
      } catch (e2) {}
      if (!canvas) this.setTexNote("");
      this.restoreAFrameMaterial();
      if (this.isDesktopRole() && this.el.object3D && !this.isImmersiveStereo()) {
        this.el.object3D.visible = true;
      }
      this.syncEyeLayers();
      return true;
    },
    applyMaterial: function () {
      // Domes must not touch A-Frame's shared video material until immersive.
      // Otherwise they thrash #chroma-stream and the PC flat a-video goes black.
      if (!this.isDesktopRole() && !this.isImmersiveStereo()) {
        this.syncEyeLayers();
        return;
      }
      this.ensureDomeGeometry();
      var mesh = this.el.getObject3D("mesh");
      if (!mesh) {
        if (this._retries++ < 100) setTimeout(this._onApply, 50);
        return;
      }
      this.syncEyeLayers();
      // The browser player owns the video. Exiting fullscreen rebinds the preview.
      if (this.isDesktopRole() && this.videoIsFullscreen()) return;
      // Flat AV1 preview is the <video> element. A canvas copy is the tile atlas,
      // and a WebGL upload here blanks that element.
      if (this.isDesktopRole() && !this.isImmersiveStereo() && this.isQuestBrowser()
          && __xrDs.av1Known && __xrDs.av1 === true && !this.data.chroma) {
        return;
      }
      if (this.isDesktopRole() && !this.isImmersiveStereo() && this.isQuestBrowser()
          && this.data.chroma && this.drawsSharedFrame()) {
        var rendererP = this.el.sceneEl && this.el.sceneEl.renderer;
        var preview = xrKeyedPreviewCanvas(rendererP, this.video, this.chromaArgs());
        if (!preview && !(__xrDs.av1Known && __xrDs.av1 === true)) {
          preview = xrDrawDownscale(this.video, this.downscaleTarget(), this.chromaArgs(), "flat");
        }
        if (preview) this.applyPostAv1Canvas(preview);
        return;
      }
      // Quest dome: AV1, and HEVC when chroma is on, sample the blit (GPU key).
      var srcNowMat = xrVideoSrc(this.video);
      var questDomeGpu = this.isQuestBrowser() && !this.isDesktopRole() && !__xrDs.suspendBlit
        && ((__xrDs.av1Known && __xrDs.av1 === true) || !!this.data.chroma);
      if (questDomeGpu && __xrDs.resolved && __xrDs.resolvedSrc === srcNowMat) {
        this.applyAv1Resolve(__xrDs.resolved);
        return;
      }
      if (questDomeGpu) {
        this.holdPreviewCanvas();
        return;
      }
      // Quest VideoTexture stays black once this session has blitted AV1.
      if (this.needsPostAv1Canvas()) {
        if (this.drawsSharedFrame()) {
          var postSlot2 = this.isDesktopRole() ? "flat" : "ar";
          var postCanvas = xrDrawDownscale(this.video, this.downscaleTarget(), this.chromaArgs(), postSlot2);
          if (postCanvas && this.applyPostAv1Canvas(postCanvas)) return;
          if (this._dsCanvas && this._dsSrc === xrVideoSrc(this.video) && this.applyPostAv1Canvas(this._dsCanvas)) return;
        } else {
          this.holdPreviewCanvas();
        }
        return;
      }
      if (this.data.chroma) {
        if (this.isQuestBrowser()) {
          // xr-chroma on a Quest video texture stays black. Key into a canvas
          // and bind A-Frame's flat material. The headset already returned above.
          if (this.drawsSharedFrame()) {
            var keyed = xrDrawDownscale(this.video, this.downscaleTarget(), this.chromaArgs(), this.isDesktopRole() ? "flat" : "ar");
            if (keyed && this.applyPostAv1Canvas(keyed)) return;
          } else if (this.holdPreviewCanvas()) return;
          this.applyNativeVideo();
          return;
        }
        var scaled = null;
        var video = this.video;
        if (video && video.videoWidth) {
          var limit = this.maxWebGLTextureSize();
          if (video.videoWidth > limit || video.videoHeight > limit) {
            scaled = this.refreshDownscaleCanvas(false);
          }
        }
        this.applyGpuChroma(scaled);
        return;
      }
      // 8K / huge SBS: downscale into canvas so WebGL can upload (native video tex → black).
      var dsTex = this.refreshDownscaleCanvas(false);
      if (dsTex) {
        this.applyCanvasVideo();
        return;
      }
      this.applyNativeVideo();
    },
    applyShader: function () {
      this.applyMaterial();
    }
  });

  // Quest often re-injects a gaze fuse ring (center donut). Strip it on load / enter-VR.
  AFRAME.registerComponent("no-gaze-cursor", {
    init: function () {
      var sceneEl = this.el;
      function kill() {
        try {
          sceneEl.querySelectorAll("a-cursor, [cursor]").forEach(function (el) {
            if (el.parentNode) el.parentNode.removeChild(el);
          });
          var camEl = sceneEl.camera && sceneEl.camera.el;
          if (camEl) {
            camEl.querySelectorAll("a-cursor, [cursor]").forEach(function (el) {
              if (el.parentNode) el.parentNode.removeChild(el);
            });
            if (camEl.components && camEl.components.cursor) {
              try { camEl.removeAttribute("cursor"); } catch (e) {}
            }
          }
        } catch (e) {}
      }
      this._kill = kill;
      sceneEl.addEventListener("loaded", kill);
      sceneEl.addEventListener("enter-vr", kill);
      sceneEl.addEventListener("exit-vr", kill);
      setTimeout(kill, 0);
      setTimeout(kill, 500);
    },
    tick: function () {
      // Cheap: only act if a cursor node crept back in.
      if (this.el.querySelector("a-cursor, [cursor]")) this._kill();
    },
    remove: function () {
      var sceneEl = this.el;
      if (!this._kill) return;
      sceneEl.removeEventListener("loaded", this._kill);
      sceneEl.removeEventListener("enter-vr", this._kill);
      sceneEl.removeEventListener("exit-vr", this._kill);
    }
  });

  AFRAME.registerComponent("env-toggle", {
    init: function () {
      var sky = document.querySelector("#virtual-sky");
      var sceneEl = this.el.sceneEl;
      var hudEl = this.el;
      var isPassthrough = false;
      function immersiveNow() {
        try {
          return !!(sceneEl && sceneEl.is && (sceneEl.is("vr-mode") || sceneEl.is("ar-mode")));
        } catch (e) {
          return false;
        }
      }
      function syncHudVisible() {
        var ar = false;
        try { ar = !!(sceneEl && sceneEl.is && sceneEl.is("ar-mode")); } catch (e) {}
        // Enter AR is already passthrough — hide the green toggle there (VR-only).
        var on = immersiveNow() && !ar;
        try { hudEl.setAttribute("visible", on ? "true" : "false"); } catch (e2) {}
        if (hudEl.object3D) hudEl.object3D.visible = on;
      }
      function applyPassthrough(on) {
        isPassthrough = !!on;
        if (isPassthrough) {
          if (sky) sky.setAttribute("visible", "false");
          if (sceneEl) {
            try { sceneEl.setAttribute("background", "transparent: true"); } catch (e) {}
            if (sceneEl.renderer) sceneEl.renderer.setClearColor("#000", 0);
          }
          var t1 = document.querySelector("#btn-text");
          if (t1) t1.setAttribute("value", "VR Void");
        } else {
          if (sky) sky.setAttribute("visible", "true");
          if (sceneEl) {
            try { sceneEl.setAttribute("background", "color: #0a0a0a; transparent: false"); } catch (e) {}
            if (sceneEl.renderer) sceneEl.renderer.setClearColor("#000", 1);
          }
          var t0 = document.querySelector("#btn-text");
          if (t0) t0.setAttribute("value", "Passthrough");
        }
      }
      var lastToggleMs = 0;
      function toggle() {
        if (!immersiveNow()) return;
        var now = Date.now();
        if (now - lastToggleMs < 280) return;
        lastToggleMs = now;
        applyPassthrough(!isPassthrough);
      }
      this.el.addEventListener("click", toggle);
      this.el.addEventListener("triggerdown", toggle);
      if (sceneEl) {
        sceneEl.addEventListener("enter-vr", function () {
          syncHudVisible();
          function apply() {
            var ar = !!(sceneEl.is && sceneEl.is("ar-mode"));
            applyPassthrough(ar);
          }
          // The first VR session after AR can run before the clear color flips back.
          apply();
          setTimeout(apply, 50);
          setTimeout(apply, 300);
        });
        sceneEl.addEventListener("exit-vr", function () {
          applyPassthrough(false);
          syncHudVisible();
        });
      }
      syncHudVisible();
      window.__xrSetPassthrough = applyPassthrough;
      window.__xrSyncPassthroughHud = syncHudVisible;
    }
  });
})();

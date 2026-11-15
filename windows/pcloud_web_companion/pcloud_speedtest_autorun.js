// On my.pcloud.com/#/speedtest (companion Chromium start URL), click Start once the SPA paints.
(() => {
  const MATCH = /#\/speedtest(?:\/|\?|$)/i;
  const DEADLINE_MS = 45000;
  const TICK_MS = 800;
  let clicked = false;
  let startedAt = 0;

  function onSpeedtestRoute() {
    return MATCH.test(String(location.hash || ""));
  }

  function looksLikeStartControl(el) {
    if (!el || el.disabled) return false;
    const tag = (el.tagName || "").toLowerCase();
    if (tag !== "button" && tag !== "a" && !(tag === "input" && /^(button|submit)$/i.test(el.type || ""))) {
      return false;
    }
    const label = `${el.textContent || ""} ${el.getAttribute("aria-label") || ""} ${el.title || ""} ${el.value || ""}`
      .replace(/\s+/g, " ")
      .trim()
      .toLowerCase();
    if (!label) return false;
    if (/stop|cancel|close|back|retry|again|share|copy/.test(label)) return false;
    return /^(start|begin|run)\b/.test(label) || /\b(start|begin)\s+(test|speed)/.test(label) || label === "go";
  }

  function tryClickStart() {
    if (clicked || !onSpeedtestRoute()) return false;
    const nodes = document.querySelectorAll("button, a[role='button'], a.btn, input[type='button'], input[type='submit']");
    for (const el of nodes) {
      if (!looksLikeStartControl(el)) continue;
      try {
        el.click();
        clicked = true;
        return true;
      } catch {
        /* keep scanning */
      }
    }
    return false;
  }

  function tick() {
    if (!onSpeedtestRoute()) {
      clicked = false;
      startedAt = 0;
      return;
    }
    if (!startedAt) startedAt = Date.now();
    if (clicked) return;
    if (Date.now() - startedAt > DEADLINE_MS) return;
    tryClickStart();
  }

  function arm() {
    startedAt = 0;
    clicked = false;
    tick();
  }

  arm();
  window.addEventListener("hashchange", arm);
  setInterval(tick, TICK_MS);
})();

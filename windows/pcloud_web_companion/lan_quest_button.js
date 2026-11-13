// Adds "Open on Quest" and "Quest control" next to Night mode on the phone LAN page (PC Chromium only).
// Open on Quest: background -> 127.0.0.1:18765 companion sink -> adb opens this page in Quest Browser.
// Quest control: background opens the companion's Quest control page (127.0.0.1:questControlPort)
// in a tab here, signed in by the extension.
(() => {
  const BTN_ID = "lan-open-on-quest";
  const CONTROL_ID = "lan-quest-control";
  const STATUS_ID = "lan-open-on-quest-status";

  function isLanPage() {
    return !!document.getElementById("lan-night-toggle");
  }

  function setStatus(text, isErr) {
    const el = document.getElementById(STATUS_ID);
    if (!el) return;
    el.textContent = text;
    try {
      el.style.color = window.__lanStatusColor ? window.__lanStatusColor(isErr) : isErr ? "#b00020" : "";
    } catch {
      el.style.color = isErr ? "#b00020" : "";
    }
  }

  async function onClick(ev) {
    const btn = ev.currentTarget;
    btn.disabled = true;
    setStatus("Opening on Quest…", false);
    try {
      const res = await chrome.runtime.sendMessage({ type: "quest-open-lan-tab" });
      const msg = res?.message || (res?.ok ? "Opened on Quest." : "Quest open failed.");
      setStatus(res?.ok ? msg : `${msg}${res?.detail ? ` (${res.detail})` : ""}`, !res?.ok);
    } catch (err) {
      setStatus(`Companion extension not reachable: ${err?.message || err}`, true);
    } finally {
      btn.disabled = false;
    }
  }

  async function onControlClick(ev) {
    const btn = ev.currentTarget;
    btn.disabled = true;
    setStatus("Opening the Quest control page…", false);
    try {
      const res = await chrome.runtime.sendMessage({ type: "quest-open-control-page" });
      setStatus(res?.message || (res?.ok ? "Opened." : "Could not open the Quest control page."), !res?.ok);
    } catch (err) {
      setStatus(`Companion extension not reachable: ${err?.message || err}`, true);
    } finally {
      btn.disabled = false;
    }
  }

  function ensureButton() {
    if (!isLanPage() || document.getElementById(BTN_ID)) return;
    const anchor = document.getElementById("lan-night-toggle");
    const btn = document.createElement("button");
    btn.type = "button";
    btn.id = BTN_ID;
    btn.textContent = "Open on Quest";
    btn.title = "Open this LAN page in Quest Browser over adb (PC companion)";
    btn.style.marginLeft = "0.5rem";
    btn.addEventListener("click", onClick);
    const status = document.createElement("span");
    status.id = STATUS_ID;
    status.className = "muted";
    status.setAttribute("role", "status");
    status.style.marginLeft = "0.5rem";
    const control = document.createElement("button");
    control.type = "button";
    control.id = CONTROL_ID;
    control.textContent = "Quest control";
    control.title = "Open the Quest control page (SKYBOX, LAN bandwidth) in a tab here, signed in (PC companion)";
    control.style.marginLeft = "0.5rem";
    control.addEventListener("click", onControlClick);
    anchor.insertAdjacentElement("afterend", btn);
    btn.insertAdjacentElement("afterend", control);
    control.insertAdjacentElement("afterend", status);
  }

  ensureButton();
  // The dashboard re-renders parts of the page; put the button back if it is dropped.
  new MutationObserver(() => ensureButton()).observe(document.documentElement, {
    childList: true,
    subtree: true,
  });
})();

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "copy-to-clipboard") return;

  (async () => {
    try {
      await navigator.clipboard.writeText(message.text);
      sendResponse({ ok: true });
    } catch (err) {
      // Fallback for environments where Clipboard API is blocked
      const ta = document.createElement("textarea");
      ta.value = message.text;
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand("copy");
      ta.remove();
      sendResponse(ok ? { ok: true } : { ok: false, error: String(err) });
    }
  })();

  return true;
});

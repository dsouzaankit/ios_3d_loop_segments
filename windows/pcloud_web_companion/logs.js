function render(logs) {
  const list = document.getElementById("list");
  const meta = document.getElementById("meta");
  meta.textContent = `${logs.length} entries · disk log: windows\\pcloud_web_companion\\rest.log`;
  list.replaceChildren();
  for (const entry of logs) {
    const div = document.createElement("div");
    div.className = "entry " + (entry.ok ? "ok" : "err");
    div.textContent = JSON.stringify(entry, null, 2);
    list.appendChild(div);
  }
}

async function load() {
  const { restLogs = [] } = await chrome.storage.local.get("restLogs");
  render(restLogs);
}

document.getElementById("refresh").addEventListener("click", () => void load());
document.getElementById("clear").addEventListener("click", async () => {
  await chrome.storage.local.set({ restLogs: [] });
  render([]);
});
let openPBusy = false;
document.getElementById("openP").addEventListener("click", async () => {
  if (openPBusy) return;
  openPBusy = true;
  const btn = document.getElementById("openP");
  const meta = document.getElementById("meta");
  btn.disabled = true;
  meta.textContent = "Opening pCloud Drive folder…";
  try {
    const result = await chrome.runtime.sendMessage({ type: "open-pcloud-on-p" });
    meta.textContent = result?.ok
      ? `Opened ${result.path || "pCloud Drive"}`
      : `pCloud Drive: ${result?.error || "failed"}`;
  } catch (err) {
    meta.textContent = `pCloud Drive: ${err && err.message ? err.message : err}`;
  } finally {
    openPBusy = false;
    btn.disabled = false;
  }
});

void load();

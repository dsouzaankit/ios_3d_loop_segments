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

let writeHybridBusy = false;
document.getElementById("writeHybrid").addEventListener("click", async () => {
  if (writeHybridBusy) return;
  writeHybridBusy = true;
  const btn = document.getElementById("writeHybrid");
  const meta = document.getElementById("meta");
  btn.disabled = true;
  meta.textContent = "Writing web_compann_plst media_files.txt…";
  try {
    const result = await chrome.runtime.sendMessage({
      type: "write-hybrid-media-list",
    });
    if (result?.ok) {
      let msg = `Wrote ${result.written} path(s)`;
      if (result.missingOnDisk) msg += ` (${result.missingOnDisk} missing on Drive)`;
      if (result.skippedNonVideo) msg += `; skipped ${result.skippedNonVideo} non-batch`;
      if (result.mediaListFile) msg += ` → ${result.mediaListFile}`;
      if (result.explorerOpened) msg += " (Explorer)";
      meta.textContent = msg;
    } else {
      meta.textContent = `Hybrid list: ${result?.error || "failed"}`;
    }
  } catch (err) {
    meta.textContent = `Hybrid list: ${err && err.message ? err.message : err}`;
  } finally {
    writeHybridBusy = false;
    btn.disabled = false;
  }
});

void load();

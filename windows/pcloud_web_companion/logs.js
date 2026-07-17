function render(logs) {
  const list = document.getElementById("list");
  const meta = document.getElementById("meta");
  meta.textContent = `${logs.length} entries · disk log: %LOCALAPPDATA%\\pcloud_web_companion\\rest.log`;
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

void load();

import { STATUS_ENDPOINT } from "./config.js";

const content = document.getElementById("content");
const sendBtn = document.getElementById("send-now");

async function refresh() {
  try {
    const res = await fetch(STATUS_ENDPOINT, { cache: "no-store" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const status = await res.json();
    render(status);
  } catch (err) {
    content.className = "err";
    content.textContent =
      "Helper isn't running. Open the Send to X4 menu-bar app.";
  }
}

function render(s) {
  const dotClass = s.x4Reachable ? "status-up" : "status-down";
  const dotText = s.x4Reachable ? "X4 reachable" : "X4 not on network";
  const next = s.lastUploadAt
    ? new Date(s.lastUploadAt).toLocaleString()
    : "never";

  content.className = "";
  content.innerHTML = `
    <div class="row">
      <span class="label"><span class="status-dot ${dotClass}"></span>${dotText}</span>
    </div>
    <div class="row">
      <span class="label">Queued</span>
      <span class="value">${s.queueLength ?? 0}</span>
    </div>
    <div class="row">
      <span class="label">Last upload</span>
      <span class="value">${next}</span>
    </div>
  `;
}

sendBtn.addEventListener("click", async () => {
  sendBtn.disabled = true;
  sendBtn.textContent = "Sending…";
  try {
    const reply = await chrome.runtime.sendMessage({ type: "capture-active-tab" });
    if (!reply?.ok) throw new Error(reply?.error || "Failed");
    sendBtn.textContent = "Queued ✓";
    setTimeout(() => window.close(), 600);
  } catch (e) {
    sendBtn.textContent = "Failed";
    content.className = "err";
    content.textContent = e.message || String(e);
    setTimeout(() => {
      sendBtn.disabled = false;
      sendBtn.textContent = "Send this page";
    }, 1200);
  }
});

refresh();

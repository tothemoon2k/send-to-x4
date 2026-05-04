import { CAPTURE_ENDPOINT } from "./config.js";

const MENU_ID_PAGE = "send-to-x4-page";

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU_ID_PAGE,
      title: "Send to X4",
      contexts: ["page"],
      documentUrlPatterns: ["http://*/*", "https://*/*"]
    });
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  try {
    await capturePage(tab);
  } catch (err) {
    notifyError(err.message);
  }
});

chrome.action.onClicked.addListener(async (tab) => {
  try {
    await capturePage(tab);
  } catch (err) {
    notifyError(err.message);
  }
});

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type === "capture-active-tab") {
    chrome.tabs
      .query({ active: true, currentWindow: true })
      .then(([tab]) => capturePage(tab))
      .then(() => sendResponse({ ok: true }))
      .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true; // async response
  }
});

async function capturePage(tab) {
  if (!tab?.id || !tab.url || !/^https?:/.test(tab.url)) {
    throw new Error("This page can't be captured.");
  }

  // Step 1: load Readability into the tab's isolated world.
  await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    files: ["lib/Readability.js"]
  });

  // Step 2: run extraction inline; same isolated world, so Readability is available.
  const [{ result }] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: extractInPage
  });

  if (!result || result.error) {
    throw new Error(result?.error || "Extraction failed.");
  }

  await postCapture({
    url: tab.url,
    capturedAt: new Date().toISOString(),
    source: "page",
    ...result
  });
  notifyQueued(result.title || tab.title || tab.url);
}

// Runs in the page (isolated world). Must be self-contained.
function extractInPage() {
  try {
    const docClone = document.cloneNode(true);
    const reader = new Readability(docClone, { keepClasses: false, debug: false });
    const article = reader.parse();
    if (!article) return { error: "Readability returned null." };

    // Pull a few extras Readability doesn't always surface.
    const meta = (name) =>
      document.querySelector(`meta[property="${name}"]`)?.getAttribute("content") ||
      document.querySelector(`meta[name="${name}"]`)?.getAttribute("content") ||
      null;

    return {
      title: article.title,
      byline: article.byline,
      siteName: article.siteName,
      lang: article.lang || document.documentElement.lang || null,
      content: article.content,
      textContent: article.textContent,
      excerpt: article.excerpt,
      publishedTime:
        article.publishedTime || meta("article:published_time") || meta("og:article:published_time"),
      ogImage: meta("og:image"),
      length: article.length
    };
  } catch (e) {
    return { error: String(e?.message || e) };
  }
}

async function postCapture(payload) {
  let res;
  try {
    res = await fetch(CAPTURE_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
  } catch (e) {
    throw new Error(
      "Send to X4 helper isn't running. Open the menu-bar app and try again."
    );
  }
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`Helper rejected capture (${res.status}): ${text}`);
  }
}

function notifyQueued(title) {
  chrome.notifications?.create({
    type: "basic",
    iconUrl: "icons/icon-128.png",
    title: "Queued for X4",
    message: title || "Article queued",
    silent: true
  });
}

function notifyError(message) {
  chrome.notifications?.create({
    type: "basic",
    iconUrl: "icons/icon-128.png",
    title: "Send to X4 — error",
    message
  });
}

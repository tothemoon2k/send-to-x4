import { CAPTURE_ENDPOINT } from "./config.js";

const MENU_ID_PAGE = "send-to-x4-page";
const MENU_ID_LINK = "send-to-x4-link";
const MENU_ID_SELECTION = "send-to-x4-selection";
const MENU_ID_BOOK = "send-to-x4-book";

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: MENU_ID_PAGE,
    title: "Send to X4",
    contexts: ["page"],
    documentUrlPatterns: ["http://*/*", "https://*/*"]
  });
  chrome.contextMenus.create({
    id: MENU_ID_LINK,
    title: "Send link to X4",
    contexts: ["link"],
    targetUrlPatterns: ["http://*/*", "https://*/*"]
  });
  chrome.contextMenus.create({
    id: MENU_ID_SELECTION,
    title: "Send selection to X4",
    contexts: ["selection"],
    documentUrlPatterns: ["http://*/*", "https://*/*"]
  });
  chrome.contextMenus.create({
    id: MENU_ID_BOOK,
    title: "Send book to X4",
    contexts: ["page"],
    documentUrlPatterns: ["http://*/*", "https://*/*"]
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  try {
    if (info.menuItemId === MENU_ID_LINK) {
      await captureLink(info.linkUrl, tab);
    } else if (info.menuItemId === MENU_ID_SELECTION) {
      await captureSelection(tab, info.selectionText);
    } else if (info.menuItemId === MENU_ID_BOOK) {
      await captureBook(tab);
    } else {
      await capturePage(tab);
    }
  } catch (err) {
    notifyError(err.message);
  }
});

chrome.action.onClicked.addListener(async (tab) => {
  // Toolbar button also captures the active page (popup is the default,
  // but if the popup is replaced with onClicked behavior, this fires).
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
  if (msg?.type === "capture-active-tab-as-book") {
    chrome.tabs
      .query({ active: true, currentWindow: true })
      .then(([tab]) => captureBook(tab))
      .then(() => sendResponse({ ok: true }))
      .catch((err) => sendResponse({ ok: false, error: err.message }));
    return true;
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

async function captureBook(tab) {
  if (!tab?.id || !tab.url || !/^https?:/.test(tab.url)) {
    throw new Error("This page can't be captured.");
  }

  // Pull a small page-text snippet — Readability is overkill for book ID,
  // and book detail pages (Goodreads, Amazon, Gutenberg) often have
  // metadata that Readability would discard as chrome.
  const [{ result }] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: extractBookSnippetInPage
  });
  if (!result || result.error) {
    throw new Error(result?.error || "Couldn't read page.");
  }

  await postCapture({
    kind: "book",
    url: tab.url,
    capturedAt: new Date().toISOString(),
    source: "book",
    title: result.title,
    lang: result.lang,
    textContent: result.snippet,
    siteName: result.siteName,
    ogImage: result.ogImage
  });
  notifyQueued("book: " + (result.title || tab.title || tab.url));
}

async function captureLink(url, tab) {
  await postCapture({
    url,
    capturedAt: new Date().toISOString(),
    source: "link",
    title: url,
    content: null,
    needsServerFetch: true,
    referrer: tab?.url || null
  });
  notifyQueued(url);
}

async function captureSelection(tab, selectionText) {
  if (!tab?.id || !tab.url) throw new Error("Tab unavailable.");

  await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    files: ["lib/Readability.js"]
  });
  const [{ result }] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: extractSelectionInPage
  });
  if (!result) throw new Error("Couldn't read selection.");

  await postCapture({
    url: tab.url,
    capturedAt: new Date().toISOString(),
    source: "selection",
    title: result.title || (selectionText || "").slice(0, 80) || tab.title,
    byline: result.byline,
    siteName: result.siteName,
    lang: document?.documentElement?.lang || null,
    content: result.content,
    textContent: result.textContent,
    excerpt: result.excerpt
  });
  notifyQueued(result.title || tab.title);
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

function extractBookSnippetInPage() {
  try {
    const meta = (name) =>
      document.querySelector(`meta[property="${name}"]`)?.getAttribute("content") ||
      document.querySelector(`meta[name="${name}"]`)?.getAttribute("content") ||
      null;

    // Cover candidates, in priority order:
    //   1. og:image (Goodreads, Project Gutenberg, most publishers)
    //   2. twitter:image
    //   3. the largest <img> on the page (Amazon: #landingImage / #imgBlkFront)
    let cover = meta("og:image") || meta("twitter:image");
    if (!cover) {
      const candidates = [
        document.querySelector("#landingImage"),
        document.querySelector("#imgBlkFront"),
        document.querySelector("img[itemprop='image']")
      ].filter(Boolean);
      const fromIds = candidates[0];
      if (fromIds) {
        cover = fromIds.getAttribute("data-old-hires") || fromIds.src || null;
      }
    }
    // Resolve relative URLs against the document.
    if (cover) {
      try { cover = new URL(cover, location.href).toString(); } catch { /* leave as-is */ }
    }

    return {
      title: document.title || null,
      lang: document.documentElement.lang || null,
      siteName: location.hostname,
      ogImage: cover,
      // 6 KB is enough for the LLM to recognize the book; saves tokens
      // vs sending the whole DOM.
      snippet: (document.body?.innerText || "").slice(0, 6000)
    };
  } catch (e) {
    return { error: String(e?.message || e) };
  }
}

function extractSelectionInPage() {
  try {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.toString().trim().length === 0) {
      return null;
    }
    const range = sel.getRangeAt(0);
    const wrapper = document.createElement("div");
    wrapper.appendChild(range.cloneContents());

    // Use Readability on the page for metadata, but content is the selection.
    let metaResult = null;
    try {
      const docClone = document.cloneNode(true);
      metaResult = new Readability(docClone).parse();
    } catch {
      /* ignore — metadata is best-effort */
    }

    return {
      title: metaResult?.title || document.title,
      byline: metaResult?.byline || null,
      siteName: metaResult?.siteName || location.hostname,
      content: `<div>${wrapper.innerHTML}</div>`,
      textContent: sel.toString(),
      excerpt: sel.toString().slice(0, 240)
    };
  } catch (e) {
    return null;
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

# Send to X4 — Specification

A "Send to X4" pipeline for the Xteink X4 e-reader. Right-click any web
article in Chrome or Safari and a clean, typographically tuned EPUB
lands on the device the next time it enters File Transfer mode.

Status as of 2026-05-03: pipeline end-to-end functional via the headless
daemon plus Chrome and Safari extensions. The book pipeline (Claude
identification → Anna's Archive → cover-injected EPUB) is implemented
and active in the daemon, but the browser surfaces are intentionally
articles-only for now — the "Send book to X4" menu entry, the link /
selection menu entries, and the macOS Share Extension target have all
been retired (see § 4.2 / D10 for the share-sheet rationale and § 4.1
for the simplified extension surface).

---

## 1. Product

### What it does

The user is reading an essay, blog post, or longform piece in a
browser. They invoke "Send to X4" through one of two surfaces:

- **Safari Web Extension or Chrome extension** — right-click context
  menu on a page; the only entry is "Send to X4" (no submenu).
- **Toolbar popup** in either browser — a single "Send this page"
  button alongside the queue/X4-status readout.

The captured DOM is converted to a single-chapter (or multi-chapter,
for long pieces) EPUB tuned for the X4's 4.3" e-ink panel — with
grayscale-dithered images and a stylesheet that matches the device's
renderer. The EPUB lands in a local queue.

The book pipeline still exists in the daemon and is automatically
exercised when the article path's `BookIdentifier` returns a
high-confidence yes on a book detail page (Amazon `/dp/`, Goodreads
`/book/show/`, Project Gutenberg, …). On a book hit it reroutes to the
book pipeline (Claude identification → Anna's Archive HTML-scraped
search → member fast-download → EPUB pass-through / Claude PDF reflow
/ native TXT / optional Calibre fallback → cover injection from
`og:image` with Open Library ISBN fallback). The user-facing menu
entry that used to invoke this directly was removed; the auto-detect
path is the only way it fires today.

The user later puts the X4 into File Transfer mode (it joins WiFi and
exposes an HTTP server on port 80). A background process on the Mac
notices the device, uploads anything in the queue idempotently, and
marks each item as sent. From the user's perspective it's "I right-click
when I'm reading; it's on my X4 next time I plug in."

### Who it's for

The literal user is Justin, who owns an Xteink X4 running open-source
CrossPoint firmware and reads a lot of online longform. The pattern this
fits is anyone who:

- Owns an Xteink X4 (a $69, pocket-size 4.3" e-ink reader).
- Reads essays/blogs/Substacks at the desk and wants them on the device.
- Doesn't want to manually drag EPUBs through Calibre or a web upload UI.

The shape of the tool is "Send to Kindle for the X4." Difference vs.
existing options:

- **Calibre's CrossPoint plugin** exists, but Calibre is heavyweight and
  requires you to already have an EPUB.
- **Web upload UI on the device** works, but is manual every time.
- **No browser-integrated solution** exists for the X4. This is that.

---

## 2. The X4 device — what we're targeting

These facts shape every design decision below.

**Hardware**

- 4.3" e-ink display, 480×800 px @ 220 ppi.
- No touchscreen, no frontlight, no Bluetooth.
- WiFi only when explicitly entered into File Transfer mode.
- ESP32-C3 SoC, very limited memory.

**Firmware: CrossPoint** ([crosspoint-reader/crosspoint-reader](https://github.com/crosspoint-reader/crosspoint-reader))

- Open-source replacement for the stock Xteink firmware.
- File Transfer mode: device joins WiFi → displays its IP on screen →
  hosts a plain-HTTP webserver on **port 80**, **no auth**, **no mDNS**.

**API surface (per `docs/webserver-endpoints.md`)**

| Method | Path           | Purpose                                       |
|--------|----------------|-----------------------------------------------|
| GET    | `/api/status`  | Device status JSON (`version`, `ip`, `mode`…) |
| GET    | `/api/files`   | List files at `?path=` (default `/`)          |
| POST   | `/upload`      | Multipart upload, field `file`, opt `?path=`  |
| POST   | `/mkdir`       | Form-encoded `name`, opt `path`               |
| POST   | `/delete`      | Form-encoded `path`, opt `type`               |

**Renderer constraints**

- Only EPUB 2 / EPUB 3 are supported. No PDF, no HTML.
- Internal representation (per `docs/file-formats.md`): the device
  imports an EPUB into binary `book.bin` + `section.bin` formats that
  retain only **word-level styles** (regular / bold / italic / bold-italic)
  and **block-level alignment** (justified / left / center / right).
- Most CSS is therefore advisory and gets discarded on import. Image
  tone-mapping is **not** done by the device — input must arrive as
  proper grayscale.

---

## 3. Architecture overview

```
┌───────────────────────────────────────────────────────────────┐
│  Browser (Safari / Chrome)                                    │
│                                                               │
│  Content script — Mozilla Readability runs on rendered DOM    │
│  Background — single "Send to X4" context-menu entry          │
│  Captures: { url, title, byline, content (XHTML), … }         │
└──────────────────────────┬────────────────────────────────────┘
                           │ POST /capture
                           │ (JSON, loopback)
                           ▼
┌───────────────────────────────────────────────────────────────┐
│  Mac helper app (menubar) — listens on 127.0.0.1:47821        │
│                                                               │
│  HTTPServer (Network.framework, loopback-only)                │
│  QueueStore (JSON manifest + per-item EPUB on disk)           │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  BuildPipeline                                          │  │
│  │     HTMLSanitizer  →  ClaudePolish (cached)             │  │
│  │       → ImageProcessor (grayscale + Atkinson dither)    │  │
│  │       → EpubWriter (pure Swift)  → queue/<id>.epub      │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                               │
│  X4Probe (last-known IP → /24 scan, looks for CrossPoint sig) │
│  X4Uploader (idempotent: GET /api/files → POST /upload)       │
└───────────────────────────────────────────────────────────────┘
                            │
                            │ multipart upload over LAN
                            ▼
                   Xteink X4 (HTTP, port 80, no auth)
```

**Process model.** Both browser entry points POST to the same loopback
HTTP daemon. The daemon owns persistence, conversion, probing, and
upload. There is no cloud component. Everything works offline except
the optional Claude polish call.

---

## 4. Components

### 4.1 Browser extensions

Both Chrome (`ChromeExtension/`) and Safari Web Extension
(`SafariWebExtension/Resources/`) are the same Manifest V3 codebase:

- `manifest.json` — MV3, with Safari adding `browser_specific_settings`.
- `background.js` — registers a single context-menu item (`page`),
  handles clicks via `chrome.scripting.executeScript` injection of
  `lib/Readability.js`, runs extraction in the page's isolated world,
  POSTs the result to the daemon. Calls
  `chrome.contextMenus.removeAll()` before `create()` on `onInstalled`
  so older menu IDs (book / link / selection) are evicted on update.
- `content extraction` — `Readability(document.cloneNode(true)).parse()`,
  augmented with a few `<meta>` lookups (og:image, published time).
- `popup.html` / `popup.js` — toolbar UI showing queue length, X4
  reachability, last upload time, and a single "Send this page" button.
- `lib/Readability.js` — Mozilla's Readability, vendored.

The Safari and Chrome extensions are byte-for-byte identical other than
the `manifest.json`'s `browser_specific_settings` key. Today the
extensions only surface article capture; the link, selection, and book
menu entries that used to live here were removed (see § 5 / D10 for
the rationale and § 8 for revival notes).

### 4.2 Share Extension (removed)

A macOS Share Extension target previously surfaced "Send to X4" in
Safari's native share sheet by AppleScript-driving Safari to read
`document.documentElement.outerHTML` from the matching tab. It was
removed in 2026-05 — the AppleScript path required two separate
permission grants (Privacy & Security → Automation, plus Safari →
Develop → Allow JavaScript from Apple Events) and silently failed
when either was missing, with no surfaced error to the user. The
`ShareExtension/` source directory is left in the tree for reference
but is not built or embedded by `project.yml`. See decision **D10**
for the longer story.

### 4.3 Mac helper app (`SendToX4/Sources/App/`)

SwiftUI menubar app. Configured as `LSUIElement` so there's no Dock
icon. Targets macOS 14. The Xcode target also compiles
`Sources/Daemon/HTTPServer.swift` and `Sources/Daemon/StatusModels.swift`
(via `project.yml`'s `sources:` with `main.swift` excluded), so the
HTTP server, `Request/Response` types, and ack structs (`CaptureAck`,
`FlushAck`, `StatusJSON`) are physically the same code as the headless
daemon — only route registration is duplicated.

- `SendToX4App.swift` — `@main`. Declares only the `Settings` scene;
  the menu-bar item is set up in `AppDelegate` (see below).
- `AppDelegate.swift` — boots the embedded HTTP server, the worker
  task, and the probe ticker on launch. Same routes as the headless
  `sendtox4d` daemon; the menubar app *is* the daemon. Also creates
  an `NSStatusItem` (rather than using `MenuBarExtra`, which doesn't
  expose a right-click menu): left-click toggles an `NSPopover`
  hosting `MenuView`, right-click pops an `NSMenu` containing
  Settings… and Quit.
- `MenuView.swift` — the popover content. X4 reachability dot at the
  top, then a Spotify-style queue list: per-row 44-pt thumbnail (from
  `Capture.ogImage` via `AsyncImage`, with a `book.closed` /
  `doc.text` placeholder), title above subtitle (byline → siteName
  fallback) in a lighter gray, error text in red below if any, and a
  small monospaced status word (`queued` / `building` / `ready` /
  `sending` / `sent` / `failed`) on the right. No footer — Settings
  and Quit are reachable only via the right-click menu on the status
  item.
- `SettingsView.swift` — last-known IP, probe interval, subnet scan
  toggle, LLM toggle, Anthropic API key (writes through to Keychain).
- `AppState.swift` — `@MainActor` `ObservableObject` polling
  `QueueStore` so the UI stays live.

### 4.4 Headless daemon (`SendToX4/Sources/Daemon/`)

Identical pipeline to the menubar app, runnable without Xcode via
`swift run sendtox4d`. Used during development and as a CI smoke
target.

- `HTTPServer.swift` — minimal HTTP/1.1 over `Network.framework`
  `NWListener`. `acceptLocalOnly = true` and `requiredInterfaceType =
  .loopback`. Connection-close, JSON in / JSON out, CORS headers for
  extension origins.
- `main.swift` — registers routes, starts a worker task driven by an
  `AsyncStream<Void>` signal, plus a probe ticker that fires the
  signal every `probeIntervalSeconds`.

### 4.5 Build pipeline (`SendToX4/Sources/Core/BuildPipeline.swift`)

For each pending `QueueItem`:

1. **Sanitize** — `HTMLSanitizer.sanitize` parses captured HTML via
   `XMLDocument(.documentTidyHTML)`, applies a tag allowlist, strips
   scripts/iframes/forms/event handlers, prunes empty wrapper `<div>`s,
   and rewrites `<img src>` to local placeholders while collecting the
   remote image URLs.
2. **Polish** (optional) — `ClaudePolish.polish` calls Claude Sonnet
   4.6 with a long system prompt cached via `cache_control: ephemeral`.
   The model returns structured JSON: `{ title, author, chapters: [{ heading, html }] }`.
   A 95%-of-input word-count guardrail enforces the no-rewrite rule;
   if violated we silently fall back to unpolished sanitized HTML.
3. **Images** — `ImageProcessor` downloads each referenced image,
   converts to 8-bit grayscale, fits to ≤480×800, applies Atkinson
   dither (6/8 error-diffusion) to a 16-level palette, encodes PNG.
   Failed downloads cause the corresponding `<img>` to be dropped from
   the chapter HTML.
4. **Assemble** — `EpubWriter` produces a complete EPUB 3 in memory:
   - `mimetype` (STORED, first entry, offset 38)
   - `META-INF/container.xml`
   - `OEBPS/{content.opf, nav.xhtml, style.css, chapter-NNN.xhtml, img-NNN.png}`
   - Zipped via `ZipWriter` (DEFLATE for everything except mimetype).
   - No cover page — articles open directly into the body. The nav
     document is always in the manifest (EPUB 3 requires it) but only
     appears in the spine when there's more than one chapter, so a
     single-chapter article doesn't get a useless one-link TOC page.
5. **Persist** — `build()` returns EPUB bytes in memory.
   `QueueStore.attachEpub` writes them to
   `~/Library/Application Support/SendToX4/queue/<slug>-<id>.epub`
   atomically with flipping `QueueItem.status = .ready`. If the item
   was evicted (same-URL re-enqueue) while the build was in flight,
   the bytes are dropped — no orphan `.epub` lands in the queue dir.

On failure: increment `attempts`, drop back to `.pending` for retry up
to `maxAttempts = 4`, then `.failed`.

### 4.6 X4 probe (`X4Probe.swift`)

1. Try `GET http://<lastKnownX4IP>/api/status` with a 1 s timeout.
   Verify response has a non-empty `version` field (CrossPoint signature).
2. If that fails and `subnetScanEnabled`, derive the local /24 from the
   primary IPv4 (via `getifaddrs`), fire 254 parallel `GET /api/status`
   requests with 1.5 s timeouts, first valid CrossPoint response wins.
3. Cache the winning IP back into settings.

### 4.7 X4 uploader (`X4Uploader.swift`)

Idempotent flush, grouped by destination directory. Articles
(`Capture.kind == .article`) route into `/essays`; books stay at root.
The mapping lives in `destinationPath(for:)`.

1. Group `.ready` items by destination path.
2. For each non-root destination, ensure the directory exists. If a
   `GET /api/files?path=/` listing already shows it as a directory, skip
   mkdir. Otherwise `POST /mkdir` (form-encoded `name`); tolerate any
   non-2xx (firmware may error when the directory already exists).
3. For each group, `GET /api/files?path=<dir>` once to build a per-path
   name → size map.
4. For each item: if its EPUB filename + size already exists at that
   path, mark `.uploaded` and skip.
5. Otherwise `POST /upload?path=<dir>` (multipart, field `file`).
6. Confirm with another `GET /api/files?path=<dir>` showing the entry;
   only then mark `.uploaded`. If the listing doesn't show it, drop back
   to `.ready` with a warning.
7. On any HTTP failure, drop back to `.ready` with the error stored and
   break the loop (likely WiFi dropped).

### 4.8 Persistence

`~/Library/Application Support/SendToX4/`

- `queue.json` — `[QueueItem]` array, atomically rewritten on each mutation.
- `queue/<id>.capture.json` — raw capture for retry/debug.
- `queue/<slug>.epub` — built EPUBs awaiting upload (with `-2`, `-3`, …
  on slug collisions across queue items; see D8).
- `settings.json` — non-secret prefs.

Same-URL re-enqueue evicts the older pending/ready/building item *and*
deletes its `.capture.json` and `.epub` from disk, so rapid re-clicks
on Send to X4 don't pile up debris.

API keys live in macOS Keychain under service `com.justingarner.sendtox4`:

- `anthropic.api.key` — Claude polish + book identification + PDF reflow.
- `annas-archive.api.key` — Anna's Archive member fast-download key.

Neither key ever touches disk in plaintext. `tools/setkey.sh` and
`tools/setaakey.sh` post them through the loopback daemon to the
matching `/settings/...` route, which writes through to Keychain.

### 4.9 HTTP API (loopback)

```
GET  /healthz                 → "ok"
GET  /status                  → { queueLength, x4Reachable, lastUploadAt, items[] }
POST /capture                 → enqueue Capture, signal worker
POST /flush                   → trigger immediate upload attempt
POST /settings/x4-ip          → { ip: "192.168.x.y" }
POST /settings/api-key        → { key: "sk-ant-…" } (Anthropic, Keychain)
POST /settings/aa-key         → { key: "…" }         (Anna's Archive member key, Keychain)
```

`Capture.id` is optional in the POST `/capture` body; the daemon mints
a UUID when absent. Only `url` is strictly required. `Capture.kind`
defaults to `"article"`; book captures POST `{ kind: "book", url, title,
textContent (snippet ≤ 6 KB), lang, ogImage, … }`. Browser extensions
don't generate IDs — server owns them.

Default port `47821`, overridable with `SENDTOX4_PORT`. No auth. Loopback
listening only.

### 4.10 Book pipeline (`Capture.kind == .book`)

A second pipeline runs alongside the article path. It's invoked when
the browser sends `kind: "book"`, and also as an auto-detect at the top
of the article path: clicking "Send to X4" on a book detail page calls
`BookIdentifier` first, persists `kind = .book` to the queue manifest
on a high-confidence match (≥ 0.75), and reroutes — so the user doesn't
have to remember which menu entry to use.

The chain (`SendToX4/Sources/Core/`):

1. **`BookIdentifier.swift`** — Claude Sonnet 4.6 with `cache_control:
   ephemeral` returns canonical `{ isBookPage, title, authors, isbn13,
   lang, year, confidence }` from URL + page title + a 4 KB
   page-text snippet. Conservative — confidence below 0.6 fails the
   build with "not a book page" rather than guessing.
2. **`AnnasArchive.swift`** — three responsibilities, one actor:
   - **Mirror discovery.** AA domains rotate due to takedowns. Once per
     daemon session, scrape Wikipedia's "Anna's Archive" page for
     `annas-archive.<tld>` URLs, probe each, cache the first reachable
     one. Hardcoded fallback list (`.org/.se/.li`) if Wikipedia is
     unreachable.
   - **Search.** AA exposes only the fast-download endpoint as JSON;
     search is HTML-scraped. We do an EPUB-first pass (`?ext=epub`) so
     popular books never need conversion, falling back to unfiltered
     only if zero candidates. The parser reads format hints from both
     rendered text and raw attribute values (alt/title/data-*) and
     unwraps comment-deferred result rows.
   - **Fast download.** `GET /dyn/api/fast_download.json?md5=…&key=…`
     (member-key gated) returns the partner-server URL. The URL points
     to the raw file bytes; we stream + return them.
3. **`pickBest`** — composite score over format (EPUB → AZW3 → MOBI →
   FB2 → DOCX → TXT → DJVU → PDF), language match, and size band.
   Drops `format == "unknown"` candidates outright rather than
   downloading an unidentifiable blob.
4. **`BookConverter.swift`** — strategy chain over the downloaded bytes.
   File-magic byte-sniffing overrides the search-page format claim so
   "the bytes are EPUB" trumps "the row said unknown":
   - **EPUB**: pass-through (`EpubCoverInjector` ensures cover, see below).
   - **TXT**: native pure-Swift converter — paragraphs split on blank
     lines, EpubWriter from there.
   - **PDF**: Claude PDF understanding via `document` content blocks
     returns structured chapters → EpubWriter. Better text reflow on
     small e-ink than Calibre's PDF→EPUB. Calibre fallback if Claude
     unavailable.
   - **Everything else** (MOBI / AZW3 / DJVU / DOCX / FB2 / …): shell
     out to Calibre's `ebook-convert` with `--cover` so it embeds our
     cover instead of generating its placeholder. If Calibre isn't
     installed, surfaces a clear actionable error rather than crashing.
5. **`BookCoverFetcher.swift` + `EpubCoverInjector.swift`** — the cover.
   Browser-side, the book extractor pulls `og:image`, `twitter:image`,
   or Amazon's `#landingImage`/`#imgBlkFront` (resolving relative URLs).
   Server-side, `BookCoverFetcher` falls back to Open Library covers
   (`covers.openlibrary.org/b/isbn/<isbn>-L.jpg?default=false`,
   no-auth, free). Image goes through `ImageProcessor` (grayscale +
   Atkinson dither + fit to 480×800 — same pipeline as inline article
   images) and is then attached: built EPUBs receive it via
   `EpubWriter.Input.coverPNG`, pass-through EPUBs via
   `EpubCoverInjector` (uses `/usr/bin/unzip` to extract, strips ALL
   pre-existing cover declarations before patching ours in, repacks via
   `ZipWriter` with mimetype STORED first per spec). Always replaces —
   the og:image from the source page is virtually always better than
   what's embedded (notably, AA carries many calibre 0.7.3 placeholder
   covers from old uploads).

---

## 5. Key architectural decisions

Numbered for cross-reference.

**D1. Browser extension + local Mac helper, not pure-browser, not cloud.**
Browser extensions can't do reliable LAN access (no raw sockets, CORS
blocks plain HTTP from HTTPS pages, mixed-content rules). A cloud
service can't reach a LAN-only device. The local helper is the only
architecture where the auto-flush UX is feasible.

**D2. Capture rendered DOM in the browser, not re-fetch the URL.**
Re-fetching breaks on paywalls, logged-in content, JS-heavy SPAs, and
anti-bot. The page in front of the user already has their auth.

**D3. Mozilla Readability for extraction.**
Battle-tested across thousands of websites. We add a small wrapper that
also pulls `og:image` and `article:published_time`.

**D4. Pure-Swift EPUB writer.**
No Node dependency, no native libraries, no SwiftPM transitive deps.
EPUB 3 is well-defined and our `ZipWriter` + `EpubWriter` total ~600
lines of Swift. Trade-off: we don't get features like fixed-layout
EPUBs or DRM, neither of which we need.

**D5. Claude Sonnet 4.6 for polish, with a strict no-rewrite contract.**
The catastrophic failure mode of LLM-driven content conversion is silent
paragraph drops on a small e-ink reader where the user reads offline
and never notices. Sonnet 4.6 gets the structured-JSON shape right
reliably; the 95% length guardrail catches the rare regressions.

**D6. Prompt caching on the system prompt.**
The polish system prompt is large (~2 KB) and identical every call.
`cache_control: ephemeral` gives ~10× cost reduction after the first
call within the 5-minute TTL.

**D7. Atkinson dithering, not Floyd-Steinberg.**
6/8 error diffusion (vs. 16/16 of FS) preserves contrast and produces
the classic Mac-Plus look that reads well on e-ink. On the X4's panel,
mid-tones from Floyd-Steinberg muddy quickly.

**D8. Idempotent uploads keyed by filename + size at a path.**
The X4 has no per-file checksums or modification times exposed. Name +
size collision at a destination path is good enough; articles upload
into `/essays` and books stay at root, so the namespaces don't overlap.
EPUB filenames are clean title slugs (`great-hackers.epub`) — two
different captures that resolve to the same slug get a `-2`, `-3`, …
suffix only on actual queue-side collision (see
`BuildPipeline.epubFilename`). Same-URL re-enqueue evicts the prior
item before this check, so retries reuse the same filename.

**D9. Probe = last-known IP first, /24 scan as fallback.**
The device has no mDNS/Bonjour, so there's no clean discovery. Caching
the last-known IP makes steady-state hit on the first probe; the
subnet scan is the fallback for when the user's router reassigned the
DHCP lease. We tell the user in Settings to set a DHCP reservation —
that's the real fix, but the scan handles the case where they haven't.

**D10. Web Extension is the only capture surface; the macOS Share
Extension was removed.** The native share sheet only hands the
extension a URL, so to recover the rendered DOM we previously had the
Share Extension AppleScript-drive Safari (`do JavaScript "…outerHTML"`
in the matching tab). That worked but required *two* opt-ins —
Automation permission for our app to control Safari (System Settings
→ Privacy & Security → Automation), AND Safari's "Allow JavaScript
from Apple Events" toggle (Develop menu) — both with no first-class
discoverability and no surfaced error path when either was off. The
share-sheet UX kept silently no-op'ing for users who hadn't found
both toggles. We removed the Share Extension entirely (2026-05) and
now lean on the Web Extension exclusively, which has no permission
gates beyond the host-permission grant. The `ShareExtension/`
directory is preserved on disk so the AppleScript shape is
recoverable if we ever revisit.

**D11. Swift menubar over Go daemon.**
Considered Go for a single-binary helper. Swift wins because (a) the
Share Extension and menubar UI are native Swift anyway, (b) all macOS
APIs we need (Keychain, AppleScript, Network.framework, ImageIO) are
first-class in Swift, (c) we ship one toolchain instead of two.

**D12. Loopback-only, no daemon auth.**
The daemon listens on 127.0.0.1 and refuses non-loopback connections.
Any local process can hit it, which matches the trust model of macOS
desktop apps. Adding a token would create a shared-secret problem
between extension and daemon that's hard to solve without UI we don't
want to build.

**D13. JSON queue manifest, not SQLite.**
The queue is at most O(100) items in steady state. Atomic JSON rewrite
on each mutation is fine and dramatically simpler than a SQLite
dependency. We can switch later if the queue grows.

**D14. CSS is structural, not stylistic.**
Per the X4 renderer constraints (D14a: only word-level bold/italic and
block-level alignment survive), the stylesheet's job is to look right
in *generic* EPUB readers (Books.app, Calibre, KOReader) — the X4 will
honor the structural HTML and a tiny subset of the CSS regardless. We
write a clean stylesheet anyway because viewing in Books.app is
how the user previews builds before sending.

**D15. Anna's Archive over Project Gutenberg / OpenLibrary / etc.**
AA is the only source that consistently has both modern paywalled books
and public-domain classics in EPUB form, with a stable JSON API for
downloads (member-key gated). Project Gutenberg has clean public-domain
EPUBs but nothing copyrighted. Library Genesis is upstream of AA but
worse to scrape. The trade-off is that AA's *search* has no JSON API —
we HTML-scrape — and the active mirror domain rotates due to
takedowns. We mitigate the rotation by scraping the Wikipedia page for
the current canonical mirror list once per daemon session.

**D16. EPUB-first search + byte-magic detection, not Calibre by default.**
AA returns heterogeneous formats (EPUB / PDF / MOBI / AZW3 / DJVU / …).
Two failure modes drove us away from Calibre as a hard dep: (a) it's a
heavy install most users don't have, and (b) AA's search HTML
sometimes hides format in attributes our scraper missed, leading to
"format=unknown" downloads of mystery bytes. Filtering search to
`?ext=epub` first means popular books never need conversion at all;
byte-magic sniffing on the downloaded bytes (PK + `application/
epub+zip` mimetype, `%PDF`, `BOOKMOBI`, `AT&TFORM`, `<FictionBook`,
high-printable-ASCII for TXT) means the converter trusts the bytes
over the search-page label. Native pure-Swift TXT converter for the
trivial case. Calibre is now an optional fallback for the rare
MOBI/AZW3/DJVU paths only, with a clear error if it's missing.

**D17. Auto-detect book pages on the article path.**
Clicking "Send to X4" on an Amazon book page should not produce an EPUB
of the Amazon page chrome. The article path runs `BookIdentifier`
before sanitize/polish; on a high-confidence yes (≥ 0.75, stricter than
the explicit-book-click threshold of 0.6) it persists `kind = .book` to
the queue manifest and reroutes to `buildBook`. Skipped without an
Anthropic key — articles still work without an LLM key, the auto-route
just doesn't fire.

**D18. Replace book covers, don't merge.**
AA EPUBs frequently carry placeholder covers (notably Calibre 0.7.3
"stack of books with watermark"). The og:image we pull from the source
page (Amazon / Goodreads / Gutenberg) is the canonical book cover. So
`EpubCoverInjector` strips every pre-existing cover declaration from
the OPF (`properties="cover-image"` tokens, `<meta name="cover">`,
prior injections) before patching ours in. Always replaces. Falls back
to leaving the EPUB untouched on any parse failure rather than
producing a broken file.

**D19. Reuse the article image pipeline for book covers.**
Same `ImageProcessor` (grayscale + Atkinson dither + fit to 480×800)
used for inline article images is used for book covers. Keeps the
visual style consistent on the X4 panel, and we don't grow a second
image pipeline.

---

## 6. Constraints we're working within

- **Device discovery**: no mDNS, plain HTTP, dynamic DHCP. Mitigated by
  D9 + DHCP-reservation prompt.
- **Device offline most of the time**: only on during File Transfer
  mode. The probe loop is short-timeout to avoid noisy retries.
- **Device API has no auth, no HTTPS**: matches the local-network trust
  model. Anyone on the same LAN can upload to your X4 today.
- **EPUB-only**: the device rejects PDFs and raw HTML. PDFs would be a
  separate render pipeline; not in scope.
- **Renderer drops most CSS**: we lean on tags + structural elements.
- **Xcode + signing required for the Mac app**: the user has Xcode but
  needs to switch `xcode-select` and install `xcodegen`. Not blocking
  the Chrome-extension-only path.
- **Anthropic API outages**: the polish call has a generous timeout
  (120 s) and the pipeline silently falls back to unpolished output, so
  even a multi-hour Anthropic incident doesn't stop the queue.

---

## 7. What's implemented

(Pointers are repo paths from the project root.)

**Browser**
- ✅ Chrome MV3 extension — single page-context "Send to X4" entry,
  Readability injection, popup with queue status
  (`ChromeExtension/`).
- ✅ Safari Web Extension target — same code as Chrome with
  Safari-specific manifest, bundled into the menubar app's `.appex`
  (`SafariWebExtension/`).
- 🗄️  macOS Share Extension — retired (see § 4.2 / D10). Source kept
  in `ShareExtension/` for reference; not built.

**Daemon / pipeline**
- ✅ Localhost HTTP server, loopback-only, JSON in/out
  (`SendToX4/Sources/Daemon/HTTPServer.swift`).
- ✅ Persistent queue, atomic JSON manifest
  (`Sources/Core/QueueStore.swift`).
- ✅ Settings store + Keychain-backed API keys (Anthropic + Anna's
  Archive member key) (`Sources/Core/SettingsStore.swift`).
- ✅ HTML sanitizer with tag allowlist + empty-wrapper pruning
  (`Sources/Core/HTMLSanitizer.swift`).
- ✅ Image processor: grayscale + Atkinson dither + resize
  (`Sources/Core/ImageProcessor.swift`).
- ✅ Pure-Swift EPUB writer + X4-tuned stylesheet
  (`Sources/Core/{ZipWriter,EpubWriter,X4Stylesheet}.swift`).
- ✅ Claude Sonnet 4.6 polish with prompt caching + 95% guardrail
  (`Sources/Core/ClaudePolish.swift`).
- ✅ Book pipeline: identification, AA mirror discovery + search +
  fast download, byte-magic format detection, native TXT converter,
  Claude PDF reflow, optional Calibre fallback, cover fetcher, OPF
  cover injector
  (`Sources/Core/{BookIdentifier,AnnasArchive,BookConverter,BookCoverFetcher,EpubCoverInjector,JSONHelpers}.swift`).
- ✅ X4 client + probe + idempotent uploader
  (`Sources/Core/{X4Client,X4Probe,X4Uploader,LocalNetwork}.swift`).
- ✅ End-to-end build pipeline glued together (article path + book
  branch with auto-detect) (`Sources/Core/BuildPipeline.swift`).

**App**
- ✅ Menubar app shell — manual `NSStatusItem` (left-click popover,
  right-click NSMenu) + SwiftUI `Settings` scene; queue list rendered
  Spotify-style (thumbnail + title above subtitle) (`Sources/App/`).
- ✅ XcodeGen `project.yml` for app + Safari Web Extension targets.
  Web-extension assets are listed individually under the target's
  `sources:` with `buildPhase: resources` (top-level files) and
  `type: folder` (`icons/`, `lib/`); the deceptively-named
  `resources:` target field is *not* a real XcodeGen key and ships
  an empty `.appex` if used (cf. CLAUDE.md).

**Tooling**
- ✅ Smoke test executable (`Sources/SmokeTest/main.swift`) that builds
  a real EPUB and validates structure with `/usr/bin/unzip`, plus
  offline regression cases for the AA HTML parser, candidate ranker,
  byte-magic format sniffer, and cover injector.
- ✅ `tools/setkey.sh` — Keychain-safe Anthropic API key entry.
- ✅ `tools/setaakey.sh` — Keychain-safe Anna's Archive member key entry.

**Verification**
- ✅ Smoke test passes: builds both a single-chapter and a multi-chapter
  EPUB, unzip accepts both, and the OPF spine asserts that the nav
  document is included only when there's more than one chapter; AA
  parser + ranker + byte sniffer + cover-injector regression cases all
  pass.
- ✅ Daemon roundtrip verified end-to-end: POST `/capture` →
  HTMLSanitizer strips `<script>`/`<iframe>`/Subscribe-Share buttons →
  EPUB lands in `~/Library/Application Support/SendToX4/queue/`.
- ✅ Book pipeline verified end-to-end on a real Amazon book page:
  Send-to-X4 → BookIdentifier → AnnasArchive (EPUB-first) →
  BookCoverFetcher (og:image) → EpubCoverInjector → queue.

---

## 8. What's left to build

**Operational (before first real use)**

- Switch `xcode-select` to full Xcode and install `xcodegen` so the Mac
  app and extension targets actually build.
- Run `xcodegen generate` and configure signing (Apple Developer Team)
  for both targets in Xcode.
- First-run UX: detect missing API key / missing X4 IP and offer a
  guided Settings panel.
- Test on the actual X4 device (the upload path is unexercised against
  real hardware).

**Quality**

- Run produced EPUBs through `epubcheck` (currently only structural
  unzip validation).
- Test against real-world sources at scale: NYT, Substack, Medium,
  Atlantic, Hacker News linkbait, Wikipedia, archive.org. Each tends to
  break Readability or the sanitizer in its own way.
- Notification on successful upload, not just on capture.
- Better error UX in the menubar popup when the X4 has been offline for
  more than N hours (suggest re-checking IP, etc.).

**Polish**

- Keyboard shortcut for "Send active tab" in both browsers.
- "Open last EPUB in Books.app" preview action — useful before sending.
- "Re-build with polish" action on a queued item that initially failed
  the 95% guardrail.
- "Skip polish" toggle in the right-click context menu.

**Future, deliberately out of scope today**

- Long-book splitting into multi-volume EPUBs.
- Cross-device queue sync (pretty much defeats the local-helper model).
- Linux / Windows daemon — possible (the Core targets are mostly
  Foundation), but `ImageProcessor`, the Calibre shell-out, and the
  `/usr/bin/unzip` calls in `EpubCoverInjector` lean on AppKit /
  ImageIO + macOS-specific paths. Would need a replacement.
- Send-to-Kindle reuse — different device, different format pipeline,
  but the same architecture would work.
- Reviving the "Send book to X4" browser entry — the daemon-side book
  pipeline (BookIdentifier → Anna's Archive → cover-injected EPUB) is
  fully implemented and exercised by the article path's auto-detect
  on book pages. Re-adding the menu entry + popup button is a small,
  deliberately-deferred UX change (we want to use articles-only for a
  while before re-introducing it).
- Reviving the macOS Share Extension — see D10. Would need both
  Automation and "Allow JavaScript from Apple Events" granted, plus
  surfaced errors when either toggle is off, before this is worth
  shipping again.

---

## 9. Trade-offs and tricky decisions worth remembering

**The LLM polish nearly didn't ship.**
The first instinct was Readability + LLM polish + EPUB, with the LLM
doing most of the cleanup. After thinking through reliability, we
nearly removed the LLM from the critical path entirely. The compromise:
LLM does structural normalization only, body text is verbatim, output
is validated for length, and the unpolished path is always a working
fallback. This makes the worst-case "Anthropic is down for 4 hours"
scenario invisible to the user — articles still ship, just
slightly less tidy. It also means a misbehaving model can't drop
chapter 7 of a book and have you not notice.

**The macOS share sheet requires more than a WebExtension.**
This was a real fork in the road. The user explicitly wanted the share
sheet (per the original screenshot), which forced us into a native
Share Extension target. The reliability tax is real — Xcode
configuration, code signing, AppleScript automation grant, etc.
Mitigated by also shipping the Web Extension path, which is the
recommended fast path during onboarding.

**Re-fetching URLs server-side was strongly considered and rejected.**
It's tempting for the Share Extension to just take the URL and curl it.
But losing paywall/auth/JS-rendering was unacceptable. The AppleScript
bridge into Safari to read live `outerHTML` is uglier but correct.

**JSON queue, not SQLite.**
SQLite would have been correct if we ever expected hundreds of items in
flight. We don't. The whole queue is bounded by "articles the user
captured between two File Transfer sessions" — typically <20.

**Loopback HTTP, not Unix-domain socket or XPC.**
A unix-domain socket would be ergonomically nicer between the daemon
and a CLI, but extensions can't use them. XPC can't be reached from
WebExtensions either. Loopback HTTP is the lowest common denominator
that all three surfaces (Chrome ext, Safari ext, Share ext) can hit.

**No code signing of the Chrome extension.**
The Chrome extension is unpacked-loaded by the user. We could publish
to the Chrome Web Store, but for v1 the user is the only user, and
local install is fine. Same for Safari — it'll be developer-signed but
not distributed.

**No automated test suite (yet).**
We have a smoke executable that builds a real EPUB and validates
structure. We do not have unit tests for the sanitizer, polish output
parser, dither algorithm, or probe logic. Adding XCTest requires the
same Xcode dev tools the user hasn't fully set up yet. Worth doing
once the Xcode flow is unblocked.

---

## 10. Build & run

**Today (no Xcode setup required) — Chrome + headless daemon**

```sh
# Terminal 1
cd ~/Desktop/code/send-to-x4
swift run sendtox4d
```

In Chrome: `chrome://extensions` → Developer mode → Load unpacked →
select `ChromeExtension/`.

```sh
# Terminal 2 — set API keys
~/Desktop/code/send-to-x4/tools/setkey.sh     # Anthropic (optional for articles, required for books)
~/Desktop/code/send-to-x4/tools/setaakey.sh   # Anna's Archive member key (required for books)
```

Right-click any article → Send to X4 → EPUB lands in
`~/Library/Application Support/SendToX4/queue/`. Right-click a book
detail page → Send book to X4 → identification + AA download +
conversion → same queue.

**To build the Mac app + Safari + Share extensions**

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
brew install xcodegen
cd ~/Desktop/code/send-to-x4
xcodegen generate
open SendToX4.xcodeproj
```

In Xcode: select your Apple Developer Team in *Signing & Capabilities*
on `SendToX4`, `SafariWebExtension`, and `ShareExtension`. Build and
run the `SendToX4` scheme. Enable in **System Settings → Extensions →
Sharing** (Share Extension) and **Safari → Settings → Extensions**
(Web Extension). Grant Automation permission to Safari on first share.

**Smoke-test the EPUB pipeline**

```sh
swift run sendtox4-smoke
# → wrote /var/folders/.../sendtox4-smoke/good-writing.epub
# → PASS — EPUB structure looks good
```

---

## 11. Repo

GitHub: <https://github.com/tothemoon2k/send-to-x4>

Layout:

```
ChromeExtension/                MV3 web extension
SafariWebExtension/             Safari Web Extension target
  Resources/                       (mirrors ChromeExtension/)
ShareExtension/                 macOS Share Sheet extension
SendToX4/
  Sources/
    App/                          SwiftUI menubar app (Xcode-only)
    Core/                         Pipeline library (SwiftPM target)
    Daemon/                       Headless `sendtox4d` (SwiftPM target)
    SmokeTest/                    EPUB pipeline smoke (SwiftPM target)
  SendToX4.entitlements
tools/
  setkey.sh                       Keychain-safe API key entry
Package.swift                   SwiftPM (Core + daemon + smoke)
project.yml                     XcodeGen (app + extensions)
SPEC.md                         This document.
```

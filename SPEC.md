# Send to X4 — Specification

A "Send to X4" pipeline for the Xteink X4 e-reader. Right-click any web
article in Chrome or Safari (or use the macOS share sheet), and a clean,
typographically tuned EPUB lands on the device the next time it enters
File Transfer mode.

Status as of 2026-05-02: pipeline end-to-end functional via the headless
daemon + Chrome extension. Mac app, Safari Web Extension, and Share
Extension targets are written but require Xcode + XcodeGen + signing to
build (see "Build & run").

---

## 1. Product

### What it does

The user is reading an essay, blog post, or longform piece in a browser.
They invoke "Send to X4" through any of three surfaces:

- **macOS Safari share sheet** — the native share button drops down
  options including "Send to X4."
- **Safari Web Extension or Chrome extension** — right-click context menu
  on a page, link, or selection.
- **Toolbar popup** in either browser — explicit "Send this page" button.

The captured article is converted to a single-chapter (or multi-chapter,
for long pieces) EPUB tuned for the X4's 4.3" e-ink panel — including a
hand-drawn cover, grayscale-dithered images, and a stylesheet that
matches the device's renderer. The EPUB lands in a local queue.

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
│  Background — context menu + toolbar action                   │
│  Captures: { url, title, byline, content (XHTML), … }         │
└────────────┬───────────────────────────────────┬──────────────┘
             │ POST /capture                     │ macOS share sheet
             │ (JSON, loopback)                  │ (URL only)
             ▼                                   ▼
                                        ┌────────────────┐
                                        │ ShareExtension │
                                        │ AppleScript →  │
                                        │ outerHTML from │
                                        │ front Safari   │
                                        └────────┬───────┘
                                                 │ POST /capture
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
│  │       → CoverGenerator                                  │  │
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

**Process model.** All three browser/share entry points POST to the same
loopback HTTP daemon. The daemon owns persistence, conversion, probing,
and upload. There is no cloud component. Everything works offline except
the optional Claude polish call.

---

## 4. Components

### 4.1 Browser extensions

Both Chrome (`ChromeExtension/`) and Safari Web Extension
(`SafariWebExtension/Resources/`) are the same Manifest V3 codebase:

- `manifest.json` — MV3, with Safari adding `browser_specific_settings`.
- `background.js` — registers context-menu items (`page`, `link`,
  `selection`), handles clicks via `chrome.scripting.executeScript`
  injection of `lib/Readability.js`, runs extraction in the page's
  isolated world, POSTs the result to the daemon.
- `content extraction` — `Readability(document.cloneNode(true)).parse()`,
  augmented with a few `<meta>` lookups (og:image, published time).
- `popup.html` / `popup.js` — toolbar UI showing queue length, X4
  reachability, last upload time, and a "Send this page" button.
- `lib/Readability.js` — Mozilla's Readability, vendored.

The Safari and Chrome extensions are byte-for-byte identical other than
the `manifest.json`'s `browser_specific_settings` key.

### 4.2 Share Extension (`ShareExtension/`)

A macOS Share Extension target that appears in the system share sheet
(matching the screenshot the user shared). Its principal class is
`ShareViewController`:

1. Reads the shared URL from `NSExtensionContext.inputItems`.
2. Runs an AppleScript against Safari that walks `windows`, finds the
   tab whose URL matches, and runs `do JavaScript "document.documentElement.outerHTML"`
   in it. Falls back to `front document` if no match.
3. POSTs the captured HTML to the loopback daemon at `/capture`.
4. Calls `completeRequest`.

The trade-off: AppleScript automation needs a one-time user grant
("System Settings → Privacy & Security → Automation") for our app to
control Safari. We accept this because we get the user's
authenticated, JS-rendered DOM, which the alternative (server-side
re-fetch) cannot.

### 4.3 Mac helper app (`SendToX4/Sources/App/`)

SwiftUI menubar app. Configured as `LSUIElement` so there's no Dock
icon. Targets macOS 14.

- `SendToX4App.swift` — `@main`, `MenuBarExtra` + `Settings` scene.
- `AppDelegate.swift` — boots the embedded HTTP server, the worker
  task, and the probe ticker on launch. Same routes as the headless
  `sendtox4d` daemon; the menubar app *is* the daemon.
- `MenuView.swift` — popup showing X4 reachability dot, queue list,
  per-item status icon (pending / building / ready / uploading /
  uploaded / failed), "Send queue now" + "Settings" + "Quit" footer.
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
4. **Cover** — `CoverGenerator` draws a Library-of-America-style
   title card via Core Graphics + Core Text: title in Hoefler Text,
   italic byline, source domain in tracked uppercase. Pure typography
   on cream — photographic covers look muddy on the panel.
5. **Assemble** — `EpubWriter` produces a complete EPUB 3 in memory:
   - `mimetype` (STORED, first entry, offset 38)
   - `META-INF/container.xml`
   - `OEBPS/{content.opf, nav.xhtml, style.css, cover.{xhtml,png}, chapter-NNN.xhtml, img-NNN.png}`
   - Zipped via `ZipWriter` (DEFLATE for everything except mimetype).
6. **Persist** — `build()` returns EPUB bytes in memory.
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

Idempotent flush:

1. `GET /api/files` once to build a name → size map.
2. For each `.ready` queue item: if its EPUB filename + size already
   exists on the device, mark `.uploaded` and skip.
3. Otherwise `POST /upload` (multipart, field `file`).
4. Confirm with another `GET /api/files` showing the entry; only then
   mark `.uploaded`. If the listing doesn't show it, drop back to
   `.ready` with a warning.
5. On any HTTP failure, drop back to `.ready` with the error stored
   and break the loop (likely WiFi dropped).

### 4.8 Persistence

`~/Library/Application Support/SendToX4/`

- `queue.json` — `[QueueItem]` array, atomically rewritten on each mutation.
- `queue/<id>.capture.json` — raw capture for retry/debug.
- `queue/<slug>-<id>.epub` — built EPUBs awaiting upload.
- `settings.json` — non-secret prefs.

Same-URL re-enqueue evicts the older pending/ready/building item *and*
deletes its `.capture.json` and `.epub` from disk, so rapid re-clicks
on Send to X4 don't pile up debris.

Anthropic API key is stored in macOS Keychain under service
`com.justingarner.sendtox4`, account `anthropic.api.key`. Never on disk
in plaintext.

### 4.9 HTTP API (loopback)

```
GET  /healthz                 → "ok"
GET  /status                  → { queueLength, x4Reachable, lastUploadAt, items[] }
POST /capture                 → enqueue Capture, signal worker
POST /flush                   → trigger immediate upload attempt
POST /settings/x4-ip          → { ip: "192.168.x.y" }
POST /settings/api-key        → { key: "sk-ant-…" } (writes to Keychain)
```

`Capture.id` is optional in the POST `/capture` body; the daemon mints
a UUID when absent. Only `url` is strictly required. Browser
extensions don't generate IDs — server owns them.

Default port `47821`, overridable with `SENDTOX4_PORT`. No auth. Loopback
listening only.

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

**D8. Idempotent uploads keyed by filename + size.**
The X4 has no per-file checksums or modification times exposed. Name +
size collision is good enough; an article that gets re-captured and
produces a new EPUB will get a new short suffix in the filename.

**D9. Probe = last-known IP first, /24 scan as fallback.**
The device has no mDNS/Bonjour, so there's no clean discovery. Caching
the last-known IP makes steady-state hit on the first probe; the
subnet scan is the fallback for when the user's router reassigned the
DHCP lease. We tell the user in Settings to set a DHCP reservation —
that's the real fix, but the scan handles the case where they haven't.

**D10. Three capture surfaces, but the Web Extension is the reliable one.**
The macOS share sheet only gets the URL. To preserve auth/paywall
context we re-enter Safari via AppleScript. That works but requires the
user to grant Automation permission once. The Web Extension flow has
no such permission step. We ship both because the user explicitly
wanted the share-sheet UX, but the Web Extension is the path we steer
power users toward.

**D11. Swift menubar over Go daemon.**
Considered Go for a single-binary helper. Swift wins because (a) the
Share Extension and menubar UI are native Swift anyway, (b) all macOS
APIs we need (Keychain, AppleScript, Network.framework, ImageIO,
NSAttributedString cover rendering) are first-class in Swift, (c) we
ship one toolchain instead of two.

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
- **macOS share sheet requires native bundle**: a pure WebExtension
  cannot populate it. Hence the Share Extension target.
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
- ✅ Chrome MV3 extension — context menu (page/link/selection),
  Readability injection, popup, queue status (`ChromeExtension/`).
- ✅ Safari Web Extension target — same code as Chrome with
  Safari-specific manifest (`SafariWebExtension/`).
- ✅ macOS Share Extension target — AppleScript bridge to Safari
  (`ShareExtension/`).

**Daemon / pipeline**
- ✅ Localhost HTTP server, loopback-only, JSON in/out
  (`SendToX4/Sources/Daemon/HTTPServer.swift`).
- ✅ Persistent queue, atomic JSON manifest
  (`Sources/Core/QueueStore.swift`).
- ✅ Settings store + Keychain-backed API key
  (`Sources/Core/SettingsStore.swift`).
- ✅ HTML sanitizer with tag allowlist + empty-wrapper pruning
  (`Sources/Core/HTMLSanitizer.swift`).
- ✅ Image processor: grayscale + Atkinson dither + resize
  (`Sources/Core/ImageProcessor.swift`).
- ✅ Pure-Swift EPUB writer, X4-tuned stylesheet, cover generator
  (`Sources/Core/{ZipWriter,EpubWriter,X4Stylesheet,CoverGenerator}.swift`).
- ✅ Claude Sonnet 4.6 polish with prompt caching + 95% guardrail
  (`Sources/Core/ClaudePolish.swift`).
- ✅ X4 client + probe + idempotent uploader
  (`Sources/Core/{X4Client,X4Probe,X4Uploader,LocalNetwork}.swift`).
- ✅ End-to-end build pipeline glued together
  (`Sources/Core/BuildPipeline.swift`).

**App**
- ✅ Menubar app shell — `MenuBarExtra` + Settings window — sources
  written, builds via Xcode (`Sources/App/`).
- ✅ XcodeGen `project.yml` for app + Safari + Share targets.

**Tooling**
- ✅ Smoke test executable (`Sources/SmokeTest/main.swift`) that builds
  a real EPUB and validates structure with `/usr/bin/unzip`.
- ✅ `tools/setkey.sh` — Keychain-safe API key entry.

**Verification**
- ✅ Smoke test passes: 21 KB EPUB with cover, OPF, nav, chapter, all
  required entries; `unzip -l` accepts.
- ✅ Daemon roundtrip verified end-to-end: POST `/capture` →
  HTMLSanitizer strips `<script>`/`<iframe>`/Subscribe-Share buttons →
  EPUB lands in `~/Library/Application Support/SendToX4/queue/`.
- ✅ Cover render visually inspected.

---

## 8. What's left to build

**Operational (before first real use)**

- Switch `xcode-select` to full Xcode and install `xcodegen` so the Mac
  app and extension targets actually build.
- Run `xcodegen generate` and configure signing (Apple Developer Team)
  for all three targets in Xcode.
- First-run UX: detect missing API key / missing X4 IP and offer a
  guided Settings panel.
- Test on the actual X4 device (the upload path is unexercised against
  real hardware).
- Validate the AppleScript permission grant flow on first share-sheet
  use.

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
- Cover variant: option to use `og:image` (dithered) instead of pure
  typography for image-heavy posts.

**Future, deliberately out of scope today**

- PDF support — would need a separate Core Graphics + PDF rasterization
  pipeline; the X4 renderer doesn't support PDFs anyway.
- Long-book splitting into multi-volume EPUBs.
- Cross-device queue sync (pretty much defeats the local-helper model).
- Linux / Windows daemon — possible (the Core targets are mostly
  Foundation), but `CoverGenerator` and `ImageProcessor` lean on
  AppKit / ImageIO. Would need replacements.
- Send-to-Kindle reuse — different device, different format pipeline,
  but the same architecture would work.

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
# Terminal 2 — set API key (optional; falls back to no-LLM)
~/Desktop/code/send-to-x4/tools/setkey.sh
```

Right-click any article → Send to X4. EPUB lands in
`~/Library/Application Support/SendToX4/queue/`.

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

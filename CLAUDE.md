# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read this first

`SPEC.md` is the source of truth for what this project is, why it's built
this way, and what's left to do. Read it before making non-trivial
changes — it documents the X4 device's quirks, the no-rewrite contract
on the LLM polish step, the discovery strategy, and the trade-offs
behind every architectural fork.

## The two-world build

The repo splits into two parallel build systems intentionally:

- **SwiftPM** (`Package.swift`) — builds `SendToX4Core` (the conversion
  pipeline as a library), `sendtox4d` (headless daemon), and
  `sendtox4-smoke` (EPUB pipeline smoke test). Compiles with the
  Command Line Tools alone; useful for fast iteration.
- **XcodeGen** (`project.yml`) — generates `SendToX4.xcodeproj` with
  three targets: the menubar app, the Safari Web Extension, and the
  Share Extension. Requires the full Xcode and depends on the SwiftPM
  package via `packages: SendToX4Core: { path: . }`.

Both worlds share the same `SendToX4Core` source tree. The headless
daemon and the menubar app both wrap it with HTTP routes plus a worker
loop — `Sources/Daemon/main.swift` and `Sources/App/AppDelegate.swift`
register near-identical routes. **Keep them in sync** when changing
the HTTP API.

The `HTTPServer` class and `StatusModels` (`CaptureAck`, `FlushAck`,
`StatusJSON`) live under `Sources/Daemon/` but are *shared*: the
SwiftPM `sendtox4d` executable target compiles the whole directory,
and the XcodeGen app target compiles the same directory with
`main.swift` excluded (see `project.yml` → `targets.SendToX4.sources`).
Don't move them into Core — `HTTPServer` imports `Network.framework`
and is server-flavored, not part of the conversion library; keeping
it in `Daemon/` and reusing it via the path-with-excludes is the
deliberate seam.

**Don't add `info: { path: ... }` blocks under the Safari/Share
extension targets in `project.yml`.** That tells XcodeGen to *generate*
the Info.plist from scratch on every `xcodegen generate`, silently
clobbering the hand-crafted `NSExtension` dict (which is what makes
macOS recognize them as a Web Extension / Share Extension at all).
The extension targets use `INFOPLIST_FILE: <path>` only; the build
copies the file as-is.

## Common commands

```sh
# Build the SwiftPM side (no Xcode needed)
swift build

# Run the headless daemon (loopback HTTP on :47821)
swift run sendtox4d

# Smoke-test the EPUB pipeline end-to-end (writes & validates an EPUB,
# plus offline regression cases for AA parser, byte sniffer, cover injector)
swift run sendtox4-smoke

# Set the Anthropic API key without leaking it into shell history
tools/setkey.sh

# Set the Anna's Archive member key (for the book pipeline)
tools/setaakey.sh

# Generate the Xcode project (after `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
# and `brew install xcodegen`)
xcodegen generate
```

`swift test` does **not** work in the default environment because
`xcode-select` typically points at CommandLineTools and XCTest isn't
available there. That's why we use a `sendtox4-smoke` executable
instead of an XCTest target.

## Architecture nuances worth knowing

**Two pipelines, one queue, discriminated by `Capture.kind`.**
`Capture` (`Sources/Core/Capture.swift`) carries `kind: .article | .book`
(default `.article` for back-compat with old browser payloads).
`BuildPipeline.build()` switches on `kind` — articles go through
`HTMLSanitizer` → `ClaudePolish` (optional) → `ImageProcessor` →
`EpubWriter`; books go through `BookIdentifier` → `AnnasArchive` (mirror
discovery + search + fast-download) → `BookConverter` (with byte-magic
detection) → `EpubCoverInjector`. Each step is independently testable;
none mutate the queue except the last one. Articles don't get a cover
page — the EPUB opens straight into the body — and the TOC (nav doc)
only appears in the spine when there's more than one chapter, since a
TOC for a single-chapter article is pure noise. **Books always get a
cover** — see "Book covers" below.

**The article path auto-detects book pages and reroutes.** Clicking
"Send to X4" on an Amazon `/dp/` or Goodreads `/book/show/` page would
otherwise produce an EPUB of the page chrome. `buildArticle` calls
`BookIdentifier.identify` first; on a high-confidence yes (≥ 0.75,
stricter than the explicit-book-click threshold of 0.6) it persists
`kind = .book` to the queue manifest and tail-calls `buildBook` with
the prefetched identification (so we don't pay for a second LLM call).
Skipped without a Claude key — the article path stays useful for
users without an LLM key.

**The polish step has a hard contract.** `ClaudePolish` MUST NOT
paraphrase or rewrite article body text. The 95%-of-input word-count
guardrail enforces this — if the model returns less than 95% of the
input word count, the pipeline silently falls back to unpolished
sanitized HTML. The catastrophic failure mode it prevents is "model
silently dropped chapter 7 of a long article and the user never
notices on the offline e-ink reader." Don't loosen this without
serious thought. The same no-rewrite contract applies to `BookConverter`
PDF reflow (Claude PDF understanding): body text is verbatim, never
paraphrased.

**Anna's Archive contract: search is HTML-scrape, downloads are JSON.**
AA's only stable JSON endpoint is `/dyn/api/fast_download.json` (member
key gated). Search is HTML-scraped. Class names rotate on the live
site, so `AnnasArchive.parseSearchHTML` keys off the `/md5/<hash>` href
and reads format hints from BOTH rendered text AND raw attribute values
(alt/title/data-*) — don't make it stricter without verifying against
the live site. The active mirror domain rotates due to takedowns;
`resolveMirror` scrapes the Wikipedia "Anna's Archive" page once per
daemon session and probes each domain. Hardcoded fallback list if
Wikipedia is unreachable. AA member key lives in Keychain under account
`annas-archive.api.key`.

**Book format detection: trust the bytes, not the search-page label.**
`BookConverter.sniffFormat` reads file magic from the first KB of the
download (PK + `application/epub+zip` mimetype, `%PDF`, `BOOKMOBI`,
`AT&TFORM`, `<FictionBook`, high-printable-ASCII for TXT). Search-page
format claims are advisory — when bytes say EPUB but the search row
said unknown, we pass through; when bytes say PDF but the row said
EPUB, we use the Claude PDF reflow path. This is the layer of defense
that survives AA HTML-shape regressions. Also: `pickBest` drops
unknown-format candidates outright — better to fail with "no
candidates" than ship random bytes to the converter.

**Book covers are always replaced, never merged.**
`EpubCoverInjector.ensureCover` is the only writer. It strips ALL
pre-existing cover declarations (`properties="cover-image"` tokens,
`<meta name="cover">`, our own previously-injected entries) before
patching ours in. Reason: AA EPUBs frequently carry placeholder covers
(notably Calibre 0.7.3 "stack of books with watermark" auto-generated
defaults) — the og:image we pull from the source page is virtually
always better. Cover sourcing is two-tier: browser sends `og:image` /
`twitter:image` / Amazon `#landingImage`; `BookCoverFetcher` falls back
to Open Library by ISBN-13 (`covers.openlibrary.org/b/isbn/<isbn>-L.jpg
?default=false`, no-auth). All covers go through the same
`ImageProcessor` (grayscale + Atkinson dither + fit to 480×800) used
for inline article images. The injector uses `/usr/bin/unzip` to
extract + `ZipWriter` to repack; it falls back to the original bytes
on any parse failure rather than producing a broken EPUB.

**Calibre is an optional fallback, not a hard dep.** The book pipeline
handles EPUB pass-through, PDF (Claude reflow), and TXT (native pure-
Swift) without external tools. Calibre's `ebook-convert` is invoked
only for MOBI/AZW3/DJVU/DOCX/FB2 etc., which are rare for popular books
once `?ext=epub` AA filter is tried first. If Calibre isn't installed,
the build fails with a clear actionable error. When Calibre IS
invoked, ALWAYS pass `--cover <path>` so it embeds our cover instead
of generating its placeholder.

**Three browser surfaces, one daemon.** Chrome extension
(`ChromeExtension/`), Safari Web Extension
(`SafariWebExtension/Resources/`), and macOS Share Extension
(`ShareExtension/`) all POST to the same loopback `/capture` endpoint.
Chrome and Safari extensions are byte-for-byte identical except for
`manifest.json`'s `browser_specific_settings`. **Keep their JS
in sync** — if you fix a bug in one, copy it to the other. The book
flow has its own context-menu entry (`MENU_ID_BOOK = "send-to-x4-book"`)
and popup button; both POST `{ kind: "book", url, title, textContent
(snippet ≤ 6 KB), lang, ogImage, … }`. Share Extension is article-only
(see SPEC § 8 "out of scope").

**The daemon owns capture IDs.** `Capture.init(from:)` mints a fresh
UUID when the JSON omits `id`; only `url` is strictly required.
Browser extensions don't generate IDs — don't tighten that contract
without updating all three clients. (The original Chrome bug was the
synthesized decoder rejecting browser POSTs for missing `id`.)

**The Share Extension uses AppleScript to read Safari's live DOM**
(`ShareExtension/ShareViewController.swift`). This is deliberate, not
expedient — see decision D10 in SPEC.md. Re-fetching URLs server-side
loses paywall/auth/JS-rendering, which is the whole point of capturing
in the user's browser.

**Device discovery is two-step, intentionally.** The X4 has no mDNS,
no auth, dynamic DHCP. `X4Probe.locate()` tries the last-known IP first
(1 s timeout) and only falls back to a parallel /24 subnet scan if
that fails. The scan filters by a CrossPoint signature (non-empty
`version` field in `/api/status` JSON). The right long-term fix is a
DHCP reservation; we surface this in Settings.

**Uploads are idempotent on filename + size, grouped by destination
directory.** Articles upload into `/essays`; books stay at root.
`X4Uploader.flush` groups ready items by `destinationPath(for:)`, ensures
each directory exists once per flush via `POST /mkdir` (skipped if a root
`/api/files` listing already shows it), pre-fetches `/api/files?path=<dir>`
per group for the name → size idempotency map, and confirms each upload
with another per-path listing before marking `.uploaded`. The CrossPoint
API exposes no checksums, so name + size at a path is the strongest
invariant we have. Routing is `Capture.kind`-driven — change
`destinationPath(for:)` if you want a different layout.

**EPUB filenames are clean stems with collision-only disambiguation.**
`BuildPipeline.epubFilename` slugifies the polished title (max 40 chars,
`a-z0-9-` only) and uses it directly: `great-hackers.epub`. Two different
captures that resolve to the same slug get `-2`, `-3`, … only on actual
queue-side collision; the current item is excluded from the collision
check so retries reuse their own filename. Pathological fallback (99
same-titled items in flight) is a 6-char id-derived suffix. Cross-session
collisions on the *device* (e.g. an old `great-hackers.epub` from a
purged queue item) aren't handled here — the device-side dedupe in
`X4Uploader.flush` would need a rename-on-size-mismatch step.

**EPUB structural rule.** `EpubWriter.write` MUST emit `mimetype` as
the first entry, STORED (uncompressed), with no extra fields, so the
ASCII string `application/epub+zip` lands at byte offset 38. This is
the EPUB-3 spec; readers reject the archive otherwise. The smoke test
verifies this.

**CSS is mostly advisory on the X4.** Per `docs/file-formats.md` in
the CrossPoint repo, the device's internal binary format retains only
word-level bold/italic and block-level alignment. Most of
`X4Stylesheet.css` exists for previewing in Books.app / Calibre /
KOReader, not for the X4 itself. When optimizing for the device,
prefer cleaner structural HTML over more CSS rules.

**Queue persistence is plain JSON.** `~/Library/Application
Support/SendToX4/queue.json` is rewritten atomically on every mutation.
Per-item `<id>.capture.json` and `<slug>.epub` live alongside in
`queue/`. The whole thing is bounded by "items captured between two X4
File Transfer sessions" — small enough that SQLite would be overkill.

**Same-URL re-enqueue is destructive on disk too.** When a new capture
arrives for a URL already pending/ready/building, `QueueStore.enqueue`
evicts the prior item *and* deletes its `.capture.json` / `.epub` so
rapid re-clicks don't pile up debris. The flip side: `BuildPipeline`
returns EPUB bytes in memory and `QueueStore.attachEpub` writes them
to disk atomically with the manifest update — so a build that finishes
*after* its item was evicted drops the bytes rather than orphaning a
stale `.epub`. Don't move EPUB writes back into the build step.

## Constraints

- API keys live in macOS Keychain (service `com.justingarner.sendtox4`):
  `anthropic.api.key` for Claude, `annas-archive.api.key` for the AA
  member key. Never put either in a file, env var, or argv. Both can
  be set via the matching `tools/setkey.sh` / `tools/setaakey.sh`
  scripts, which POST through the loopback daemon.
- The daemon listens on **loopback only**
  (`acceptLocalOnly = true`, `requiredInterfaceType = .loopback` in
  `HTTPServer.swift`). Don't expose it to the LAN — there's no auth.
- `xcode-select` typically points at CommandLineTools by default in
  this dev environment. The user must run
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
  before any Xcode build will work.
- `gh` CLI installation, GitHub repo creation, and `git push` are
  visible-to-others actions — confirm with the user before running.

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

## Common commands

```sh
# Build the SwiftPM side (no Xcode needed)
swift build

# Run the headless daemon (loopback HTTP on :47821)
swift run sendtox4d

# Smoke-test the EPUB pipeline end-to-end (writes & validates an EPUB)
swift run sendtox4-smoke

# Set the Anthropic API key without leaking it into shell history
tools/setkey.sh

# Generate the Xcode project (after `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
# and `brew install xcodegen`)
xcodegen generate
```

`swift test` does **not** work in the default environment because
`xcode-select` typically points at CommandLineTools and XCTest isn't
available there. That's why we use a `sendtox4-smoke` executable
instead of an XCTest target.

## Architecture nuances worth knowing

**The pipeline is a chain of pure functions over `Capture`.** A
`Capture` (`Sources/Core/Capture.swift`) flows through `HTMLSanitizer`
→ `ClaudePolish` (optional) → `ImageProcessor` → `EpubWriter`, glued
by `BuildPipeline.processNext()`. Each step is independently testable;
none mutate the queue except the last one. Articles don't get a cover
page — the EPUB opens straight into the body — and the TOC (nav doc)
only appears in the spine when there's more than one chapter, since a
TOC for a single-chapter article is pure noise.

**The polish step has a hard contract.** `ClaudePolish` MUST NOT
paraphrase or rewrite article body text. The 95%-of-input word-count
guardrail enforces this — if the model returns less than 95% of the
input word count, the pipeline silently falls back to unpolished
sanitized HTML. The catastrophic failure mode it prevents is "model
silently dropped chapter 7 of a long article and the user never
notices on the offline e-ink reader." Don't loosen this without
serious thought.

**Three browser surfaces, one daemon.** Chrome extension
(`ChromeExtension/`), Safari Web Extension
(`SafariWebExtension/Resources/`), and macOS Share Extension
(`ShareExtension/`) all POST to the same loopback `/capture` endpoint.
Chrome and Safari extensions are byte-for-byte identical except for
`manifest.json`'s `browser_specific_settings`. **Keep their JS
in sync** — if you fix a bug in one, copy it to the other.

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

**Uploads are idempotent on filename + size.** Before posting to
`/upload`, `X4Uploader.flush` pre-fetches `/api/files`, skips files
that already exist with matching size, and confirms post-upload via
another listing before marking `.uploaded`. The CrossPoint API exposes
no checksums, so name + size is the strongest invariant we have.

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
Per-item `<id>.capture.json` and `<slug>-<id>.epub` live alongside in
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

- The Anthropic API key lives in macOS Keychain (service
  `com.justingarner.sendtox4`, account `anthropic.api.key`). Never put
  it in a file, env var, or argv.
- The daemon listens on **loopback only**
  (`acceptLocalOnly = true`, `requiredInterfaceType = .loopback` in
  `HTTPServer.swift`). Don't expose it to the LAN — there's no auth.
- `xcode-select` typically points at CommandLineTools by default in
  this dev environment. The user must run
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
  before any Xcode build will work.
- `gh` CLI installation, GitHub repo creation, and `git push` are
  visible-to-others actions — confirm with the user before running.

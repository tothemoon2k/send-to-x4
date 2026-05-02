import Foundation
import SendToX4Core

// Build a real EPUB end-to-end and validate structure with /usr/bin/unzip.
// Lets us exercise the pipeline without the full Xcode dev tools (XCTest).

func require(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if !cond {
        fputs("FAIL [\(file):\(line)] \(msg)\n", stderr)
        exit(1)
    }
}

let body = """
<p>The most useful sentence I've ever read on writing was a Twitter aphorism: <em>good writing is rewriting</em>.</p>
<p>It's blunt, but it captures the recursive structure of writing well.</p>
<h2>Some thoughts</h2>
<p>Editing is where craft happens. Drafts are scaffolding.</p>
"""

let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("sendtox4-smoke")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func writeAndList(_ input: EpubWriter.Input, name: String) throws -> (data: Data, opf: String, listing: String) {
    let data = try EpubWriter.write(input)
    require(data.count > 1024, "\(name): EPUB suspiciously small")
    require(data.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]), "\(name): missing PK signature")
    let mimeBytes = Data("application/epub+zip".utf8)
    let mimeOffset = 30 + 8
    require(data.subdata(in: mimeOffset..<(mimeOffset + mimeBytes.count)) == mimeBytes,
            "\(name): mimetype must be the first entry, STORED, at offset 38")

    let outURL = outDir.appendingPathComponent("\(name).epub")
    try data.write(to: outURL)
    print("wrote \(outURL.path) (\(data.count) bytes)")

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    proc.arguments = ["-l", outURL.path]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    try proc.run()
    proc.waitUntilExit()
    require(proc.terminationStatus == 0, "\(name): unzip rejected the file")
    let listing = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    let opfProc = Process()
    opfProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    opfProc.arguments = ["-p", outURL.path, "OEBPS/content.opf"]
    let opfPipe = Pipe()
    opfProc.standardOutput = opfPipe
    opfProc.standardError = Pipe()
    try opfProc.run()
    opfProc.waitUntilExit()
    let opf = String(data: opfPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    return (data, opf, listing)
}

// Case 1: single-chapter article. No cover, no TOC in the spine.
let single = EpubWriter.Input(
    identifier: "urn:send-to-x4:smoke-1",
    title: "Good Writing",
    author: "Paul Graham",
    sourceURL: "https://paulgraham.com/good.html",
    sourceName: "paulgraham.com",
    lang: "en",
    chapters: [.init(title: "Good Writing", bodyHTML: body)]
)
let r1 = try writeAndList(single, name: "good-writing")
print(r1.listing)

for required in ["mimetype", "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml",
                 "OEBPS/style.css", "OEBPS/chapter-001.xhtml"] {
    require(r1.listing.contains(required), "missing entry: \(required)")
}
require(!r1.listing.contains("OEBPS/cover.png"), "single-chapter must not have cover.png")
require(!r1.listing.contains("OEBPS/cover.xhtml"), "single-chapter must not have cover.xhtml")
require(!r1.opf.contains("<itemref idref=\"nav\"/>"),
        "single-chapter must NOT include nav in the spine")
require(r1.opf.contains("properties=\"nav\""),
        "nav.xhtml must still be declared in the manifest")

// Case 2: multi-chapter piece. Still no cover, but TOC IS in the spine.
let multi = EpubWriter.Input(
    identifier: "urn:send-to-x4:smoke-2",
    title: "A Long Read",
    chapters: [
        .init(title: "Part One", bodyHTML: "<p>One.</p>"),
        .init(title: "Part Two", bodyHTML: "<p>Two.</p>"),
        .init(title: "Part Three", bodyHTML: "<p>Three.</p>")
    ]
)
let r2 = try writeAndList(multi, name: "a-long-read")
require(r2.opf.contains("<itemref idref=\"nav\"/>"),
        "multi-chapter must include nav in the spine")
require(!r2.listing.contains("OEBPS/cover.png"), "multi-chapter must not have cover.png")

// Case 3: Anna's Archive search-HTML parser. Offline fixture so the test
// can run without network. Fixture mimics two result rows with the kinds of
// metadata strings AA actually surfaces.
let aaFixture = """
<html><body>
<a href="/md5/d6e1dc51a50726f00ec438af21952a45" class="js-vim-focus custom-a flex items-center relative left-[-10px] w-[calc(100%+20px)] px-[10px] py-2 hover:bg-black hover:bg-opacity-[0.05] focus-visible:outline focus-visible:outline-2">
  <div>
    <div lang="en">English [en], epub, .epub, 1.6MB, <strong>Pride and Prejudice</strong>, Jane Austen</div>
  </div>
</a>
<!-- some pages defer rows inside HTML comments -->
<!--
<a href="/md5/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" class="…">
  <div>Russian [ru], pdf, 12.3MB, Преступление и наказание, Фёдор Достоевский</div>
</a>
-->
<a href="/md5/0123456789abcdef0123456789abcdef" class="…">
  <div>English, azw3, 2.0MB, Sapiens, Yuval Noah Harari</div>
</a>
</body></html>
"""
let aaCandidates = AnnasArchive.parseSearchHTML(Data(aaFixture.utf8), preferredLang: "en")
require(aaCandidates.count == 3, "expected 3 candidates, got \(aaCandidates.count)")
require(aaCandidates[0].md5 == "d6e1dc51a50726f00ec438af21952a45", "first md5 wrong")
require(aaCandidates[0].format == "epub", "first format wrong: \(aaCandidates[0].format)")
require(aaCandidates[0].lang == "en", "first lang wrong: \(aaCandidates[0].lang ?? "nil")")
require((aaCandidates[0].sizeBytes ?? 0) > 1_500_000, "first size wrong: \(aaCandidates[0].sizeBytes ?? 0)")
require(aaCandidates[1].format == "pdf", "comment-unwrapped format wrong: \(aaCandidates[1].format)")
require(aaCandidates[2].format == "azw3", "third format wrong: \(aaCandidates[2].format)")

let best = AnnasArchive.pickBest(aaCandidates, preferredLang: "en")
require(best?.md5 == "d6e1dc51a50726f00ec438af21952a45",
        "ranker should pick the EPUB English candidate; picked \(best?.md5 ?? "nil")")

// Case 4: ranker must drop unknown-format candidates. If the parser couldn't
// pin a format, we'd rather fail with "no candidates" than ship random bytes
// to the converter — that was the Amazon → Odyssey regression.
let onlyUnknown = [
    AnnasArchive.Candidate(md5: "deadbeef0123456789abcdef00000000", format: "unknown",
                           sizeBytes: 1_000_000, lang: "en", title: nil, authors: nil, sourceText: "")
]
require(AnnasArchive.pickBest(onlyUnknown, preferredLang: "en") == nil,
        "ranker must reject unknown-format-only candidate sets")

// Case 5: format detection from attribute values (alt/title/data-*). Real
// AA HTML hides the format in attributes that stripTags would otherwise
// discard, so the parser has to peek at the raw inner HTML too.
let attrFixture = """
<html><body>
<a href="/md5/00000000000000000000000000000001" class="…">
  <img alt="EPUB cover">
  <div lang="en">English, 1.2MB, Some Book</div>
</a>
</body></html>
"""
let attrCandidates = AnnasArchive.parseSearchHTML(Data(attrFixture.utf8), preferredLang: "en")
require(attrCandidates.first?.format == "epub",
        "parser must read format from attribute values when text doesn't carry it; got \(attrCandidates.first?.format ?? "nil")")

// Case 6: byte-magic format sniffing. Identify a real EPUB and a PDF from
// just their first bytes. (TXT is harder to fixture meaningfully; skip.)
let epubBytes = r1.data       // produced by the case-1 smoke EPUB build
require(BookConverter.sniffFormat(bytes: epubBytes) == "epub",
        "sniffer must recognize a real EPUB by its mimetype entry")

var pdfBytes = Data("%PDF-1.4\n%âãÏÓ\n1 0 obj\n<</Type/Catalog>>".utf8)
pdfBytes.append(Data(repeating: 0x20, count: 100))
require(BookConverter.sniffFormat(bytes: pdfBytes) == "pdf",
        "sniffer must recognize PDF magic")

let txtBytes = Data("Just plain ASCII text, paragraph one.\n\nParagraph two.\n".utf8)
require(BookConverter.sniffFormat(bytes: txtBytes) == "txt",
        "sniffer must recognize plain TXT")

print("PASS — EPUB structure looks good; AA parser + ranker green; byte-sniffer green")

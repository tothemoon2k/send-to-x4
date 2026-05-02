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

let cover = CoverGenerator.makePNG(.init(
    title: "Good Writing",
    author: "Paul Graham",
    source: "paulgraham.com"
))
print("cover bytes: \(cover?.count ?? 0)")

let body = """
<p>The most useful sentence I've ever read on writing was a Twitter aphorism: <em>good writing is rewriting</em>.</p>
<p>It's blunt, but it captures the recursive structure of writing well.</p>
<h2>Some thoughts</h2>
<p>Editing is where craft happens. Drafts are scaffolding.</p>
"""

let input = EpubWriter.Input(
    identifier: "urn:send-to-x4:smoke-1",
    title: "Good Writing",
    author: "Paul Graham",
    sourceURL: "https://paulgraham.com/good.html",
    sourceName: "paulgraham.com",
    lang: "en",
    chapters: [.init(title: "Good Writing", bodyHTML: body)],
    coverPNG: cover
)

let data = try EpubWriter.write(input)
print("epub bytes: \(data.count)")

require(data.count > 1024, "EPUB suspiciously small")
require(data.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]), "missing PK signature")
let mimeBytes = Data("application/epub+zip".utf8)
let mimeOffset = 30 + 8
require(data.subdata(in: mimeOffset..<(mimeOffset + mimeBytes.count)) == mimeBytes,
        "mimetype must be the first entry, STORED, at offset 38")

let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("sendtox4-smoke")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let outURL = outDir.appendingPathComponent("good-writing.epub")
try data.write(to: outURL)
print("wrote \(outURL.path)")

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
proc.arguments = ["-l", outURL.path]
let pipe = Pipe()
proc.standardOutput = pipe
proc.standardError = Pipe()
try proc.run()
proc.waitUntilExit()
require(proc.terminationStatus == 0, "unzip rejected the file")
let listing = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
print(listing)

for required in ["mimetype", "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml",
                 "OEBPS/style.css", "OEBPS/chapter-001.xhtml"] {
    require(listing.contains(required), "missing entry: \(required)")
}
if cover != nil {
    require(listing.contains("OEBPS/cover.png"), "missing cover.png")
    require(listing.contains("OEBPS/cover.xhtml"), "missing cover.xhtml")
}
print("PASS — EPUB structure looks good")

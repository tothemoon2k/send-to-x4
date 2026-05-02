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

print("PASS — EPUB structure looks good")

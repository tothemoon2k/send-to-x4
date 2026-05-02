import Foundation

/// Cleans HTML (typically from Mozilla Readability) into safe XHTML suitable
/// for embedding in an EPUB. Strips scripting, navigation chrome, event
/// handlers, and inline styles. Rewrites <img src> to local references and
/// returns the list of remote URLs that need to be downloaded.
///
/// Implementation note: Foundation's `XMLDocument` on macOS exposes libxml2's
/// HTML tidy via `.documentTidyHTML`, which is robust for messy HTML.
public enum HTMLSanitizer {

    public struct ImageRef: Sendable {
        public var id: String
        public var sourceURL: URL
        public var localFilename: String
        public var alt: String?
    }

    public struct Result: Sendable {
        public var bodyXHTML: String
        public var images: [ImageRef]
        public var wordCount: Int
    }

    /// Tags allowed in EPUB body content.
    private static let allowedTags: Set<String> = [
        "p", "div", "span",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "em", "i", "strong", "b", "u", "s", "small", "sub", "sup",
        "blockquote", "cite", "q", "abbr",
        "ul", "ol", "li", "dl", "dt", "dd",
        "a",
        "code", "pre", "kbd", "samp", "var",
        "br", "hr",
        "img", "figure", "figcaption", "picture",
        "table", "thead", "tbody", "tfoot", "tr", "th", "td",
        "section", "article", "header", "footer", "main", "aside",
        "time", "mark"
    ]

    /// Tags whose content is dropped entirely (not just unwrapped).
    private static let droppedTags: Set<String> = [
        "script", "style", "noscript",
        "iframe", "frame", "frameset", "embed", "object", "applet",
        "form", "input", "button", "select", "option", "textarea", "label",
        "video", "audio", "source", "track", "canvas",
        "head", "meta", "link", "base", "title",
        "nav", "menu", "menuitem", "details", "summary", "dialog"
    ]

    private static let allowedAttrsByTag: [String: Set<String>] = [
        "a":      ["href", "title"],
        "img":    ["src", "alt", "title", "width", "height"],
        "abbr":   ["title"],
        "time":   ["datetime"],
        "td":     ["colspan", "rowspan", "headers"],
        "th":     ["colspan", "rowspan", "scope"],
        "ol":     ["start"],
        "li":     ["value"]
    ]

    /// Void elements (XHTML self-closing).
    private static let voidElements: Set<String> = [
        "br", "hr", "img", "meta", "link", "input", "area", "base", "col",
        "embed", "param", "source", "track", "wbr"
    ]

    public static func sanitize(_ html: String, baseURL: URL? = nil) throws -> Result {
        // Wrap so libxml2 has a complete document to chew on.
        let wrapped = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"/></head><body>\(html)</body></html>"

        let opts: XMLNode.Options = [.documentTidyHTML]
        let doc: XMLDocument
        do {
            doc = try XMLDocument(xmlString: wrapped, options: opts)
        } catch {
            // Fallback: try without tidy if input is already XML-ish.
            doc = try XMLDocument(xmlString: wrapped, options: [])
        }

        guard let root = doc.rootElement() else {
            return Result(bodyXHTML: "", images: [], wordCount: 0)
        }
        guard let body = firstElement(in: root, named: "body") ?? firstElement(in: root, named: "html") else {
            return Result(bodyXHTML: "", images: [], wordCount: 0)
        }

        var images: [ImageRef] = []
        var imageCounter = 0
        var seenURLs: [String: ImageRef] = [:]

        func handleImage(_ element: XMLElement) {
            let srcStr = element.attribute(forName: "src")?.stringValue
                ?? element.attribute(forName: "data-src")?.stringValue
                ?? element.attribute(forName: "data-original")?.stringValue
                ?? ""
            guard !srcStr.isEmpty else {
                element.detach()
                return
            }
            // Strip data: URIs to avoid bloating the output before image processor handles them.
            if srcStr.hasPrefix("data:") {
                element.detach()
                return
            }
            guard let resolved = URL(string: srcStr, relativeTo: baseURL)?.absoluteURL else {
                element.detach()
                return
            }

            let key = resolved.absoluteString
            let ref: ImageRef
            if let existing = seenURLs[key] {
                ref = existing
            } else {
                imageCounter += 1
                let id = String(format: "img-%03d", imageCounter)
                // Filename gets its real extension after image processor decides PNG/JPEG.
                let ref0 = ImageRef(
                    id: id,
                    sourceURL: resolved,
                    localFilename: id,                      // e.g. "img-001"; extension added later
                    alt: element.attribute(forName: "alt")?.stringValue
                )
                seenURLs[key] = ref0
                images.append(ref0)
                ref = ref0
            }

            // Rewrite the src to point at the local file (extension-less; the
            // pipeline rewrites again once the image is processed).
            element.attribute(forName: "src")?.stringValue = ref.localFilename
            // Drop width/height — let the EPUB stylesheet handle sizing.
            element.removeAttribute(forName: "width")
            element.removeAttribute(forName: "height")
            element.removeAttribute(forName: "srcset")
            element.removeAttribute(forName: "sizes")
        }

        // Recursive walk: depth-first, mutate.
        func walk(_ node: XMLNode) {
            // Snapshot children — mutating during iteration is unsafe.
            let children = (node.children ?? [])
            for child in children {
                if let element = child as? XMLElement {
                    let name = (element.name ?? "").lowercased()

                    if droppedTags.contains(name) {
                        element.detach()
                        continue
                    }

                    walk(element)

                    if !allowedTags.contains(name) {
                        // Unwrap unknown tag: replace with its children.
                        unwrap(element)
                        continue
                    }

                    // Filter attributes
                    let allowedForTag = allowedAttrsByTag[name] ?? []
                    let allAttrs = element.attributes ?? []
                    for attr in allAttrs {
                        let attrName = (attr.name ?? "").lowercased()
                        if attrName.hasPrefix("on") {
                            element.removeAttribute(forName: attr.name ?? "")
                            continue
                        }
                        if !allowedForTag.contains(attrName) {
                            element.removeAttribute(forName: attr.name ?? "")
                            continue
                        }
                        // Sanitize URL-bearing attributes.
                        if attrName == "href" || attrName == "src" {
                            let v = attr.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                            if v.hasPrefix("javascript:") || v.hasPrefix("vbscript:") || v.hasPrefix("data:") {
                                element.removeAttribute(forName: attr.name ?? "")
                            }
                        }
                    }

                    if name == "img" {
                        handleImage(element)
                    }
                } else if child.kind == .comment || child.kind == .processingInstruction {
                    child.detach()
                }
            }
        }

        walk(body)
        // Second pass: drop wrapper elements that lost all their meaningful
        // children (e.g. <div class="share-buttons"> after we removed the
        // <button>s inside it).
        pruneEmptyContainers(body)

        let xhtml = serializeChildren(body)
        let words = countWords(in: body)
        return Result(bodyXHTML: xhtml, images: images, wordCount: words)
    }

    /// Tags that are meaningless when empty (vs. <td>, <p>, <h1> which we keep
    /// even if empty in case they convey structure).
    private static let emptyDroppable: Set<String> = [
        "div", "span", "section", "article", "header", "footer", "main", "aside",
        "figure", "figcaption", "ul", "ol"
    ]

    private static func pruneEmptyContainers(_ node: XMLElement) {
        let kids = node.children ?? []
        for child in kids {
            if let element = child as? XMLElement {
                pruneEmptyContainers(element)
                let name = (element.name ?? "").lowercased()
                if emptyDroppable.contains(name) && !hasMeaningfulContent(element) {
                    element.detach()
                }
            }
        }
    }

    private static func hasMeaningfulContent(_ node: XMLElement) -> Bool {
        for child in node.children ?? [] {
            if child.kind == .text {
                if !(child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            } else if let element = child as? XMLElement {
                let name = (element.name ?? "").lowercased()
                if name == "img" || name == "br" || name == "hr" {
                    return true
                }
                if hasMeaningfulContent(element) { return true }
            }
        }
        return false
    }

    // MARK: - Helpers

    private static func firstElement(in node: XMLElement, named name: String) -> XMLElement? {
        if (node.name ?? "").lowercased() == name { return node }
        for child in node.children ?? [] {
            if let element = child as? XMLElement {
                if let found = firstElement(in: element, named: name) {
                    return found
                }
            }
        }
        return nil
    }

    /// Replace the element with its children in its parent.
    private static func unwrap(_ element: XMLElement) {
        guard let parent = element.parent as? XMLElement else {
            element.detach()
            return
        }
        let index = element.index
        let kids = (element.children ?? [])
        for (i, child) in kids.enumerated() {
            child.detach()
            parent.insertChild(child, at: index + i)
        }
        // Re-fetch element index in case insertion shifted things.
        element.detach()
    }

    /// Serialize the children of `parent` as XHTML.
    private static func serializeChildren(_ parent: XMLElement) -> String {
        var out = ""
        for child in parent.children ?? [] {
            out += serialize(child)
        }
        return out
    }

    private static func serialize(_ node: XMLNode) -> String {
        switch node.kind {
        case .text:
            return EpubWriter.escapeXML(node.stringValue ?? "")
        case .element:
            guard let element = node as? XMLElement else { return "" }
            let name = (element.name ?? "").lowercased()
            var attrs = ""
            for attr in element.attributes ?? [] {
                let aName = (attr.name ?? "").lowercased()
                let value = attr.stringValue ?? ""
                attrs += " \(aName)=\"\(EpubWriter.escapeAttr(value))\""
            }
            if voidElements.contains(name) {
                return "<\(name)\(attrs)/>"
            }
            var inner = ""
            for child in element.children ?? [] {
                inner += serialize(child)
            }
            return "<\(name)\(attrs)>\(inner)</\(name)>"
        default:
            return ""
        }
    }

    private static func countWords(in node: XMLNode) -> Int {
        switch node.kind {
        case .text:
            let s = node.stringValue ?? ""
            return s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        case .element:
            var count = 0
            for child in node.children ?? [] {
                count += countWords(in: child)
            }
            return count
        default:
            return 0
        }
    }
}

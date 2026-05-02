import Foundation

public enum JSONHelpers {
    /// Strips optional ```` ``` ```` (with or without a `json` language tag)
    /// fences that some Claude responses still wrap their JSON in.
    public static func stripJSONFence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let firstNewline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNewline)...])
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3))
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
}

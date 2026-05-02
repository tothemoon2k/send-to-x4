import Foundation

/// Sources a book cover image. Tries, in order:
///   1. The page's `og:image` (the page in front of the user — Amazon,
///      Goodreads, Project Gutenberg, etc. — almost always exposes one).
///   2. Open Library's covers API by ISBN-13 (free, no auth).
///
/// Returns the raw image bytes (JPEG or PNG, whatever the source serves).
/// The caller is expected to pass these through `ImageProcessor.process` to
/// get an X4-tuned grayscale-dithered PNG.
public enum BookCoverFetcher {

    public static func fetch(
        ogImageURL: String?,
        isbn13: String?
    ) async -> Data? {
        if let raw = ogImageURL,
           let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
           let url = URL(string: cleaned),
           let data = await tryFetch(url) {
            return data
        }
        if let isbn = isbn13?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
           // `default=false` so OL returns 404 instead of a 1×1 transparent
           // pixel when the ISBN has no cover on file.
           let url = URL(string: "https://covers.openlibrary.org/b/isbn/\(isbn)-L.jpg?default=false"),
           let data = await tryFetch(url) {
            return data
        }
        return nil
    }

    private static func tryFetch(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) SendToX4/0.1",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            // Reject 1×1 placeholder images (Amazon and a few other sites
            // serve a tiny transparent pixel as a fallback).
            guard data.count > 2_000 else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

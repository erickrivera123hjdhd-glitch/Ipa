import Foundation

enum LinkError: LocalizedError {
    case badLink, notFound
    var errorDescription: String? {
        switch self {
        case .badLink: return "That doesn't look like a link."
        case .notFound:
            return "Couldn't find any audio at that link. Direct file links and TikTok links work. For other sites, save the video and use the file or Photos button."
        }
    }
}

/// Turns a pasted link into a local audio/video file. Works on the phone, no server:
///  1. a direct audio/video file link,
///  2. a TikTok page (reads the sound / video address out of the page),
///  3. any page that names its video/audio in its meta tags.
/// Sites that hide their media (YouTube, Instagram...) can't be read this way.
enum LinkResolver {
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func fetch(_ text: String) async throws -> (url: URL, name: String) {
        guard let link = firstURL(in: text) else { throw LinkError.badLink }
        let first = try await get(link, referer: nil)
        if first.isMedia { return (first.file, first.name ?? link.host ?? "Song") }

        let html = (try? String(contentsOf: first.file, encoding: .utf8))
            ?? (try? String(contentsOf: first.file, encoding: .isoLatin1)) ?? ""
        try? FileManager.default.removeItem(at: first.file)
        let base = first.finalURL ?? link
        let title = pageTitle(html) ?? base.host ?? "Song"
        for c in candidates(html: html, base: base) {
            if let r = try? await get(c, referer: base), r.isMedia {
                return (r.file, title)
            }
        }
        throw LinkError.notFound
    }

    // MARK: network

    private struct Got { let file: URL; let isMedia: Bool; let finalURL: URL?; let name: String? }

    private static func get(_ url: URL, referer: URL?) async throws -> Got {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        if let r = referer { req.setValue(r.absoluteString, forHTTPHeaderField: "Referer") }
        req.timeoutInterval = 60
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        let mime = (resp.mimeType ?? "").lowercased()
        let path = resp.url?.path.lowercased() ?? url.path.lowercased()
        let isMedia = mime.hasPrefix("audio/") || mime.hasPrefix("video/")
            || (mime == "application/octet-stream" && hasMediaExt(path))
        guard isMedia else { return Got(file: tmp, isMedia: false, finalURL: resp.url, name: nil) }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-\(UUID().uuidString).\(ext(mime: mime, path: path))")
        try FileManager.default.moveItem(at: tmp, to: dest)
        let nm = (resp.url ?? url).deletingPathExtension().lastPathComponent
        return Got(file: dest, isMedia: true, finalURL: resp.url, name: nm.isEmpty ? nil : nm)
    }

    // MARK: parsing

    private static func firstURL(in text: String) -> URL? {
        let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let m = det?.firstMatch(in: text, options: [], range: range)
        return m?.url
    }

    private static func hasMediaExt(_ p: String) -> Bool {
        ["mp3", "m4a", "aac", "wav", "ogg", "flac", "mp4", "mov", "m4v", "webm"].contains { p.hasSuffix("." + $0) }
    }

    private static func ext(mime: String, path: String) -> String {
        if mime.contains("mpeg") && mime.hasPrefix("audio") { return "mp3" }
        if mime == "audio/mp4" || mime == "audio/x-m4a" || mime == "audio/aac" { return "m4a" }
        if mime.contains("wav") { return "wav" }
        if mime.contains("quicktime") { return "mov" }
        if mime.contains("webm") { return "webm" }
        if let e = path.split(separator: ".").last, e.count <= 4, hasMediaExt("." + e) { return String(e) }
        return mime.hasPrefix("audio/") ? "m4a" : "mp4"
    }

    private static func pageTitle(_ html: String) -> String? {
        guard let m = match(html, "<title[^>]*>([^<]{1,120})</title>").first else { return nil }
        let t = unescape(m).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(40))
    }

    private static func candidates(html: String, base: URL) -> [URL] {
        var out: [String] = []
        // TikTok: the page carries its data as JSON. The sound (audio only) first, then the video.
        if let json = match(html, "<script[^>]*id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\"[^>]*>(.*?)</script>").first,
           let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            for key in ["playUrl", "playAddr", "downloadAddr"] { collect(obj, key: key, into: &out) }
        }
        // generic meta tags / media tags
        let metas = match(html, "<meta[^>]+(?:property|name)=\"(?:og:video(?::secure_url|:url)?|og:audio(?::secure_url|:url)?|twitter:player:stream)\"[^>]+content=\"([^\"]+)\"")
        let tags = match(html, "<(?:video|audio|source)[^>]+src=\"([^\"]+)\"")
        out += (metas + tags).map(unescape)
        var seen = Set<String>(), urls: [URL] = []
        for s in out where !s.isEmpty {
            let u = s.replacingOccurrences(of: "\\u002F", with: "/")
            if let url = URL(string: u, relativeTo: base)?.absoluteURL, url.scheme?.hasPrefix("http") == true,
               seen.insert(url.absoluteString).inserted { urls.append(url) }
        }
        return urls
    }

    private static func collect(_ o: Any, key: String, into out: inout [String]) {
        if let d = o as? [String: Any] {
            if let s = d[key] as? String, s.hasPrefix("http") { out.append(s) }
            for v in d.values { collect(v, key: key, into: &out) }
        } else if let a = o as? [Any] {
            for v in a { collect(v, key: key, into: &out) }
        }
    }

    private static func match(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

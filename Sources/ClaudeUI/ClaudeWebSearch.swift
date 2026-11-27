import Foundation

public enum ClaudeWebSearchMode: String, CaseIterable, Codable, Equatable, Sendable {
    case auto = "Auto"
    case always = "Always"
    case off = "Off"

    public var detail: String {
        switch self {
        case .auto: "Searches DuckDuckGo automatically via tools or web-intent prompts"
        case .always: "Searches DuckDuckGo on every message before answering"
        case .off: "Disabled unless toggled on in the chat composer"
        }
    }
}

public struct ClaudeWebSearchResult: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var domain: String
    public var snippet: String

    public init(id: String = UUID().uuidString, title: String, url: String, domain: String = "", snippet: String) {
        self.id = id
        self.title = title
        self.url = url
        self.domain = domain.isEmpty ? (URL(string: url)?.host ?? "") : domain
        self.snippet = snippet
    }
}

public enum ClaudeWebSearchError: LocalizedError, Sendable {
    case emptyQuery
    case invalidURL
    case badResponse(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: "Search query cannot be empty."
        case .invalidURL: "Invalid URL."
        case .badResponse(let code): "DuckDuckGo returned HTTP \(code)."
        }
    }
}

public enum ClaudeDuckDuckGoSearch {
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    public static func search(
        query: String, maxResults: Int = 6, session: URLSession = .shared
    ) async throws -> [ClaudeWebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClaudeWebSearchError.emptyQuery }
        let limit = max(1, min(maxResults, 12))

        async let htmlTask = fetchHTMLResults(query: trimmed, limit: limit, session: session)
        async let instantTask = fetchInstantAnswerResults(query: trimmed, session: session)

        var merged = (try? await htmlTask) ?? []
        if merged.isEmpty {
            merged = (try? await fetchLiteResults(query: trimmed, limit: limit, session: session)) ?? []
        }
        let instant = (try? await instantTask) ?? []

        var seenURLs = Set(merged.map { $0.url.lowercased() })
        for item in instant where merged.count < limit {
            if seenURLs.insert(item.url.lowercased()).inserted {
                merged.append(item)
            }
        }
        return Array(merged.prefix(limit))
    }

    public static func fetchWebpageExcerpt(
        urlString: String, maxCharacters: Int = 3800, session: URLSession = .shared
    ) async throws -> (title: String, content: String) {
        let normalized = urlString.contains("://") ? urlString : "https://" + urlString
        guard let url = URL(string: normalized) else { throw ClaudeWebSearchError.invalidURL }
        let res = try await fetchWebpageExcerpt(url: url, maxCharacters: maxCharacters, session: session)
        return (res.title, res.excerpt)
    }

    public static func fetchWebpageExcerpt(
        url: URL, maxCharacters: Int = 3800, session: URLSession = .shared
    ) async throws -> (title: String, excerpt: String) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ClaudeWebSearchError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 18)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClaudeWebSearchError.badResponse(http.statusCode)
        }
        let prefixData = data.prefix(400_000)
        let raw = String(data: prefixData, encoding: .utf8) ?? String(data: prefixData, encoding: .isoLatin1) ?? ""
        return extractReadableWebpage(from: raw, fallbackTitle: url.host ?? url.absoluteString, limit: maxCharacters)
    }

    public static func extractReadableWebpage(
        from html: String, fallbackTitle: String = "", limit: Int = 3800
    ) -> (title: String, excerpt: String) {
        let title = firstTagText("title", in: html) ?? fallbackTitle
        var body = html
        let stripPatterns = [
            "<!--[\\s\\S]*?-->",
            "<script\\b[^>]*>[\\s\\S]*?</script>",
            "<style\\b[^>]*>[\\s\\S]*?</style>",
            "<noscript\\b[^>]*>[\\s\\S]*?</noscript>",
            "<svg\\b[^>]*>[\\s\\S]*?</svg>",
            "<nav\\b[^>]*>[\\s\\S]*?</nav>",
            "<footer\\b[^>]*>[\\s\\S]*?</footer>"
        ]
        for pattern in stripPatterns {
            body = body.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        body = body.replacingOccurrences(
            of: "</(p|div|li|h[1-6]|tr|section|article|br)\\s*>",
            with: "\n", options: [.regularExpression, .caseInsensitive])
        let clean = cleanHTMLText(body)
            .components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let clipped = clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
        return (title.isEmpty ? fallbackTitle : title, clipped)
    }

    public static func parseHTMLResults(_ html: String, limit: Int = 6) -> [ClaudeWebSearchResult] {
        let anchorPattern = "<a[^>]*class=\"[^\"]*result__a[^\"]*\"[^>]*href=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</a>"
        guard let anchorRegex = try? NSRegularExpression(pattern: anchorPattern, options: [.caseInsensitive]) else {
            return []
        }
        let snippetRegex = try? NSRegularExpression(
            pattern: "class=\"[^\"]*result__snippet[^\"]*\"[^>]*>([\\s\\S]*?)</(?:a|div|span)>",
            options: [.caseInsensitive])

        let nsRange = NSRange(html.startIndex..., in: html)
        let matches = anchorRegex.matches(in: html, range: nsRange)
        var results: [ClaudeWebSearchResult] = []
        var seen = Set<String>()

        for (index, match) in matches.enumerated() {
            guard results.count < limit, match.numberOfRanges >= 3,
                let hrefRange = Range(match.range(at: 1), in: html),
                let titleRange = Range(match.range(at: 2), in: html)
            else { continue }

            let rawHref = decodeHTMLEntities(String(html[hrefRange]))
            guard let resolvedURL = unwrapDuckDuckGoURL(rawHref) else { continue }
            let key = resolvedURL.lowercased()
            guard seen.insert(key).inserted else { continue }

            let title = cleanHTMLText(String(html[titleRange]))
            guard !title.isEmpty else { continue }

            let searchStart = match.range.upperBound
            let searchEnd = index + 1 < matches.count ? matches[index + 1].range.location : nsRange.upperBound
            var snippet = ""
            if searchEnd > searchStart, let snippetRegex {
                let subRange = NSRange(location: searchStart, length: min(4000, searchEnd - searchStart))
                if let sMatch = snippetRegex.firstMatch(in: html, range: subRange),
                    sMatch.numberOfRanges >= 2,
                    let sRange = Range(sMatch.range(at: 1), in: html)
                {
                    snippet = cleanHTMLText(String(html[sRange]))
                }
            }
            results.append(.init(title: title, url: resolvedURL, snippet: snippet))
        }
        return results
    }

    public static func parseLiteResults(_ html: String, limit: Int = 6) -> [ClaudeWebSearchResult] {
        let pattern =
            "<a[^>]*href=[\"']([^\"']+)[\"'][^>]*class=[\"'][^\"']*result-link[^\"']*[\"'][^>]*>([\\s\\S]*?)</a>"
        let altPattern =
            "<a[^>]*class=[\"'][^\"']*result-link[^\"']*[\"'][^>]*href=[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>"
        let snippetRegex = try? NSRegularExpression(
            pattern: "class=[\"'][^\"']*result-snippet[^\"']*[\"'][^>]*>([\\s\\S]*?)</td>",
            options: [.caseInsensitive])

        var matches: [NSTextCheckingResult] = []
        let fullRange = NSRange(html.startIndex..., in: html)
        if let r1 = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            matches = r1.matches(in: html, range: fullRange)
        }
        if matches.isEmpty, let r2 = try? NSRegularExpression(pattern: altPattern, options: [.caseInsensitive]) {
            matches = r2.matches(in: html, range: fullRange)
        }

        var results: [ClaudeWebSearchResult] = []
        var seen = Set<String>()
        for (index, match) in matches.enumerated() {
            guard results.count < limit, match.numberOfRanges >= 3,
                let hrefRange = Range(match.range(at: 1), in: html),
                let titleRange = Range(match.range(at: 2), in: html)
            else { continue }
            let rawHref = decodeHTMLEntities(String(html[hrefRange]))
            guard let resolvedURL = unwrapDuckDuckGoURL(rawHref), seen.insert(resolvedURL.lowercased()).inserted else {
                continue
            }
            let title = cleanHTMLText(String(html[titleRange]))
            guard !title.isEmpty else { continue }
            let start = match.range.upperBound
            let end = index + 1 < matches.count ? matches[index + 1].range.location : fullRange.upperBound
            var snippet = ""
            if end > start, let snippetRegex,
                let sMatch = snippetRegex.firstMatch(
                    in: html, range: NSRange(location: start, length: min(3000, end - start))),
                sMatch.numberOfRanges >= 2, let sRange = Range(sMatch.range(at: 1), in: html)
            {
                snippet = cleanHTMLText(String(html[sRange]))
            }
            results.append(.init(title: title, url: resolvedURL, snippet: snippet))
        }
        return results
    }

    public static func parseInstantAnswerJSON(_ data: Data) -> [ClaudeWebSearchResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var results: [ClaudeWebSearchResult] = []
        if let abstractText = json["AbstractText"] as? String, !abstractText.isEmpty,
            let abstractURL = json["AbstractURL"] as? String, !abstractURL.isEmpty
        {
            let heading = (json["Heading"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Summary"
            results.append(.init(title: heading, url: abstractURL, snippet: abstractText))
        }
        if let topics = json["RelatedTopics"] as? [[String: Any]] {
            for topic in topics {
                if let text = topic["Text"] as? String, let firstURL = topic["FirstURL"] as? String,
                    !text.isEmpty, !firstURL.isEmpty
                {
                    let title = String(text.split(separator: "-").first ?? Substring(text.prefix(60)))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    results.append(.init(title: title, url: firstURL, snippet: text))
                }
            }
        }
        return results
    }

    public static func unwrapDuckDuckGoURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("duckduckgo.com/y.js"), !trimmed.contains("ad_domain=") else {
            return nil
        }
        let normalized = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        if let components = URLComponents(string: normalized),
            let host = components.host?.lowercased(), host.contains("duckduckgo.com"),
            let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
            let target = URL(string: uddg),
            let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https"
        {
            return target.absoluteString
        }
        if let direct = URL(string: normalized),
            let scheme = direct.scheme?.lowercased(), scheme == "http" || scheme == "https",
            !(direct.host?.lowercased().contains("duckduckgo.com") ?? false)
        {
            return direct.absoluteString
        }
        return nil
    }

    public static func shouldAutoSearch(prompt: String) -> Bool {
        let lower = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.count >= 4 else { return false }
        let triggers = [
            "pesquise", "pesquisar", "busque", "buscar na web", "procure na internet", "notícias", "noticias",
            "cotação", "cotacao", "preço hoje", "preco hoje", "clima em", "tempo em", "quem ganhou",
            "última versão", "ultima versao", "lançamento", "search the web", "search for", "look up",
            "latest news", "current price", "weather in", "duckduckgo", "ddg"
        ]
        return triggers.contains { lower.contains($0) }
    }

    public static func optimizedSearchQuery(from prompt: String) -> String {
        var cleaned = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["/search ", "/ddg ", "pesquise sobre ", "pesquise ", "busque ", "search for ", "search "] {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        let firstLine = cleaned.components(separatedBy: .newlines).first ?? cleaned
        return String(firstLine.prefix(180))
    }

    public static func formatContextPrompt(
        query: String, results: [ClaudeWebSearchResult],
        currentDate: String = ISO8601DateFormatter().string(from: Date())
    ) -> String {
        guard !results.isEmpty else {
            return "[DuckDuckGo Web Search for '\(query)' (\(currentDate)): no results returned.]"
        }
        var lines = [
            "DuckDuckGo Web Search results for \"\(query)\" (retrieved \(currentDate)):",
            "Use these fresh sources to ground your response and cite relevant links as [Title](URL)."
        ]
        for (idx, item) in results.enumerated() {
            lines.append("[\(idx + 1)] \(item.title) — \(item.url)")
            if !item.snippet.isEmpty {
                lines.append("    Snippet: \(item.snippet)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func cleanHTMLText(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeHTMLEntities(stripped)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decodeHTMLEntities(_ input: String) -> String {
        var text = input
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&#x27;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&ndash;", "–"), ("&mdash;", "—"),
            ("&hellip;", "…"), ("&copy;", "©"), ("&reg;", "®")
        ]
        for (entity, replacement) in named where text.contains(entity) {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        if let decRegex = try? NSRegularExpression(pattern: "&#([0-9]{1,7});") {
            let matches = decRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
            for match in matches {
                if let numRange = Range(match.range(at: 1), in: text),
                    let fullRange = Range(match.range, in: text),
                    let code = UInt32(text[numRange]), let scalar = UnicodeScalar(code)
                {
                    text.replaceSubrange(fullRange, with: String(scalar))
                }
            }
        }
        if let hexRegex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]{1,6});") {
            let matches = hexRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
            for match in matches {
                if let numRange = Range(match.range(at: 1), in: text),
                    let fullRange = Range(match.range, in: text),
                    let code = UInt32(text[numRange], radix: 16), let scalar = UnicodeScalar(code)
                {
                    text.replaceSubrange(fullRange, with: String(scalar))
                }
            }
        }
        return text
    }

    private static func fetchHTMLResults(
        query: String, limit: Int, session: URLSession
    ) async throws -> [ClaudeWebSearchResult] {
        guard let url = URL(string: "https://html.duckduckgo.com/html/") else {
            throw ClaudeWebSearchError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://html.duckduckgo.com/", forHTTPHeaderField: "Referer")
        var form = URLComponents()
        form.queryItems = [.init(name: "q", value: query), .init(name: "kl", value: "wt-wt")]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClaudeWebSearchError.badResponse(http.statusCode)
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        return parseHTMLResults(html, limit: limit)
    }

    private static func fetchLiteResults(
        query: String, limit: Int, session: URLSession
    ) async throws -> [ClaudeWebSearchResult] {
        guard let url = URL(string: "https://lite.duckduckgo.com/lite/") else {
            throw ClaudeWebSearchError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var form = URLComponents()
        form.queryItems = [.init(name: "q", value: query)]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClaudeWebSearchError.badResponse(http.statusCode)
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        return parseLiteResults(html, limit: limit)
    }

    private static func fetchInstantAnswerResults(
        query: String, session: URLSession
    ) async throws -> [ClaudeWebSearchResult] {
        var components = URLComponents(string: "https://api.duckduckgo.com/")
        components?.queryItems = [
            .init(name: "q", value: query),
            .init(name: "format", value: "json"),
            .init(name: "no_html", value: "1"),
            .init(name: "skip_disambig", value: "1")
        ]
        guard let url = components?.url else { throw ClaudeWebSearchError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClaudeWebSearchError.badResponse(http.statusCode)
        }
        return parseInstantAnswerJSON(data)
    }

    private static func firstTagText(_ tag: String, in html: String) -> String? {
        let pattern = "<" + tag + "\\b[^>]*>([\\s\\S]*?)</" + tag + ">"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            match.numberOfRanges >= 2, let range = Range(match.range(at: 1), in: html)
        else { return nil }
        let cleaned = cleanHTMLText(String(html[range]))
        return cleaned.isEmpty ? nil : cleaned
    }
}

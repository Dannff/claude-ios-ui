import Foundation
import Testing
@testable import ClaudeUI

@Test func htmlPreviewSupportDetectsHTMLAndSVGAndNormalizesDocuments() {
    #expect(ClaudeHTMLPreviewSupport.isPreviewableCode(language: "html", content: "<h1>Hello</h1>"))
    #expect(ClaudeHTMLPreviewSupport.isPreviewableCode(language: "SVG", content: "<svg><circle r='5'/></svg>"))
    let fullDoc = "<!DOCTYPE html><html><body>Hi</body></html>"
    #expect(ClaudeHTMLPreviewSupport.isPreviewableCode(language: nil, content: fullDoc))
    #expect(!ClaudeHTMLPreviewSupport.isPreviewableCode(language: "swift", content: "let x = 1 < 2 && 3 > 1"))
    #expect(!ClaudeHTMLPreviewSupport.isPreviewableCode(language: nil, content: "print('hello')"))

    #expect(ClaudeHTMLPreviewSupport.isSubstantialRawHTML("<div class=\"card\"><h2>Dashboard</h2><p>Live</p></div>"))
    #expect(!ClaudeHTMLPreviewSupport.isSubstantialRawHTML("<br>"))

    let rawFragment = "<title>Solar Tracker</title><div id='app'>Ready</div>"
    #expect(ClaudeHTMLPreviewSupport.extractTitle(from: rawFragment) == "Solar Tracker")

    let normalized = ClaudeHTMLPreviewSupport.normalizedHTMLDocument(source: "<h1>Widget</h1>", language: "html")
    #expect(normalized.contains("<!DOCTYPE html>"))
    #expect(normalized.contains("viewport"))
    #expect(normalized.contains("claudePreviewError"))

    let markdown = """
        Here is your interactive app:

        ```html
        <!doctype html>
        <html><head><title>Pomodoro Timer</title></head><body><button>Start</button></body></html>
        ```
        """
    let extracted = ClaudeHTMLPreviewSupport.extractArtifacts(from: markdown)
    #expect(extracted.count == 1)
    #expect(extracted.first?.title == "Pomodoro Timer")
}

@Test func duckDuckGoParserUnwrapsRedirectsAndExtractsHTMLAndInstantAnswers() throws {
    let wrapped = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2Fswift%2F&rut=abcdef"
    #expect(ClaudeDuckDuckGoSearch.unwrapDuckDuckGoURL(wrapped) == "https://developer.apple.com/swift/")

    let sampleDDGHTML = """
        <div class="result results_links results_links_deep web-result">
          <h2 class="result__title">
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2Fblog%2F&amp;rut=123">Swift.org &amp; Blog</a>
          </h2>
          <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2Fblog%2F">Official announcements for <b>Swift</b>6.</a>
        </div>
        """
    let htmlResults = ClaudeDuckDuckGoSearch.parseHTMLResults(sampleDDGHTML, limit: 5)
    #expect(htmlResults.count == 1)
    #expect(htmlResults[0].title == "Swift.org & Blog")
    #expect(htmlResults[0].url == "https://swift.org/blog/")
    #expect(htmlResults[0].domain == "swift.org")
    #expect(htmlResults[0].snippet == "Official announcements for Swift6.")

    let instantJSON: [String: Any] = [
        "Heading": "DuckDuckGo",
        "AbstractText": "DuckDuckGo is an internet privacy company.",
        "AbstractURL": "https://en.wikipedia.org/wiki/DuckDuckGo",
        "RelatedTopics": [
            [
                "Text": "DuckDuckGo - Official site",
                "FirstURL": "https://duckduckgo.com/"
            ]
        ]
    ]
    let jsonData = try JSONSerialization.data(withJSONObject: instantJSON)
    let iaResults = ClaudeDuckDuckGoSearch.parseInstantAnswerJSON(jsonData)
    #expect(iaResults.count == 2)
    #expect(iaResults[0].url == "https://en.wikipedia.org/wiki/DuckDuckGo")

    let sampleWebpage = """
        <html><head><title>Article Title</title><script>var bad = 1;</script></head>
        <body><nav>Menu</nav><main><h1>Headline</h1><p>Clean body paragraph.</p></main></body></html>
        """
    let readable = ClaudeDuckDuckGoSearch.extractReadableWebpage(from: sampleWebpage, limit: 500)
    #expect(readable.title == "Article Title")
    #expect(readable.excerpt.contains("Headline"))
    #expect(readable.excerpt.contains("Clean body paragraph."))
    #expect(!readable.excerpt.contains("var bad"))

    #expect(ClaudeDuckDuckGoSearch.shouldAutoSearch(prompt: "Quais são as últimas notícias de hoje sobre IA?"))
    #expect(!ClaudeDuckDuckGoSearch.shouldAutoSearch(prompt: "Write a Swift function to reverse an array"))
}

@Test func workspacePersistenceSlashCommandsCalculatorAndCleanSessionDefaults() throws {
    let clean = SessionState()
    #expect(clean.messages.isEmpty)
    #expect(clean.conversations.isEmpty)
    #expect(clean.projects.projects.isEmpty)
    #expect(clean.projects.suggestedRepository.isEmpty)
    #expect(clean.artifacts.items.isEmpty)
    #expect(clean.devices.rows.isEmpty)

    #expect(ClaudeSlashCommand.parse("/search swift 6 concurrency") == .search("swift 6 concurrency"))
    #expect(ClaudeSlashCommand.parse("/ddg Clima São Paulo") == .search("Clima São Paulo"))
    let expectedRead = ClaudeSlashCommand.readURL("https://example.com", question: "Resuma")
    #expect(ClaudeSlashCommand.parse("/read https://example.com Resuma") == expectedRead)
    #expect(ClaudeSlashCommand.parse("/html Jogo da velha neon") == .htmlApp("Jogo da velha neon"))
    #expect(ClaudeSlashCommand.parse("/calc 2^10 + sqrt(144)") == .calculate("2^10 + sqrt(144)"))
    #expect(ClaudeSlashCommand.parse("/limpar") == .clear)

    #expect(ClaudeAgentTools.evaluateMath("sqrt(144) + 2^10") == .success(1036))
    #expect(ClaudeAgentTools.evaluateMath("(15 * 4) / 2 - 5") == .success(25))
    #expect(ClaudeAgentTools.evaluateMath("10 / 0") == .failure(.divisionByZero))
    #expect(ClaudeAgentTools.evaluateMath("invalid(((") == .failure(.invalidSyntax))

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = ClaudeWorkspaceStore(directory: tempDir)
    let source = ClaudeWebSearchResult(title: "Swift.org", url: "https://swift.org", snippet: "Swift language")
    let conv = ClaudeConversationSummary(
        title: "Pesquisa Swift",
        pinned: true,
        messages: [
            .init(isUser: true, text: "O que há de novo no Swift?"),
            .init(isUser: false, text: "Confira [1].", searchSources: [source])
        ])
    let snap = ClaudeWorkspaceSnapshot(
        fullName: "Maria Silva",
        nickname: "Maria",
        initials: "MS",
        instructions: "Responda em português.",
        conversations: [conv],
        projects: [.init(name: "App iOS", goal: "Shipping")],
        artifacts: [.init(title: "Preview", content: "<h1>Oi</h1>")],
        memoryNotes: [.init(title: "Preferência", markdown: "Tema escuro")])
    store.save(snap)

    let loaded = store.load()
    #expect(loaded.fullName == "Maria Silva")
    #expect(loaded.conversations.count == 1)
    #expect(loaded.conversations[0].messages[1].searchSources == [source])
    #expect(loaded.projects.count == 1)
    #expect(loaded.artifacts.count == 1)
    #expect(loaded.memoryNotes.count == 1)

    var session = SessionState()
    session.openConversation(loaded.conversations[0])
    #expect(session.messages.count == 2)
    #expect(session.messages[1].searchSources == [source])

    store.clearAll()
    #expect(store.load().conversations.isEmpty)
}

import Foundation

public struct ClaudeAttachmentPayload: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable { case image, textFile }
    public var id: String
    public var fileName: String
    public var kind: Kind
    public var mimeType: String
    public var base64Data: String
    public var textContent: String
    public var aspectRatio: Double

    public init(
        id: String = UUID().uuidString, fileName: String, kind: Kind, mimeType: String = "text/plain",
        base64Data: String = "", textContent: String = "", aspectRatio: Double = 1.0
    ) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.mimeType = mimeType
        self.base64Data = base64Data
        self.textContent = textContent
        self.aspectRatio = aspectRatio
    }

    public var dataURL: String? {
        guard kind == .image, !base64Data.isEmpty else { return nil }
        return "data:\(mimeType);base64,\(base64Data)"
    }
}

public struct ClaudePersistedMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var isUser: Bool
    public var text: String
    public var searchSources: [ClaudeWebSearchResult]

    public init(
        id: UUID = UUID(), isUser: Bool, text: String, searchSources: [ClaudeWebSearchResult] = []
    ) {
        self.id = id
        self.isUser = isUser
        self.text = text
        self.searchSources = searchSources
    }

    public init(from message: ChatMessage) {
        self.id = message.id
        self.isUser = (message.role == .user)
        self.text = message.text
        self.searchSources = message.searchSources
    }

    public func toChatMessage() -> ChatMessage {
        ChatMessage(
            id: id, role: isUser ? .user : .assistant, text: text,
            searchSources: searchSources)
    }
}

public struct ClaudeConversationSummary: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var updatedAt: Date
    public var pinned: Bool
    public var projectID: UUID?
    public var messages: [ClaudePersistedMessage]

    public init(
        id: UUID = UUID(), title: String, updatedAt: Date = Date(), pinned: Bool = false,
        projectID: UUID? = nil, messages: [ClaudePersistedMessage] = []
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.pinned = pinned
        self.projectID = projectID
        self.messages = messages
    }

    public static func makeTitle(from firstPrompt: String) -> String {
        let cleaned =
            firstPrompt
            .replacingOccurrences(of: "^/[a-zA-Z]+\\s*", with: "", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "New conversation"
        if cleaned.count <= 48 { return cleaned }
        return String(cleaned.prefix(45)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public func exportMarkdown() -> String {
        var lines = ["# " + title, ""]
        for msg in messages {
            lines.append(msg.isUser ? "### User" : "### Assistant")
            lines.append("")
            lines.append(msg.text)
            if !msg.searchSources.isEmpty {
                lines.append("")
                lines.append("**Sources (DuckDuckGo):**")
                for src in msg.searchSources {
                    lines.append("- [\(src.title)](\(src.url))")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

public struct ClaudePersistedProject: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var goal: String
    public var icon: String
    public var pinned: Bool
    public var contextItems: [String]

    public init(
        id: UUID = UUID(), name: String, goal: String = "", icon: String = "rectangle.stack",
        pinned: Bool = false, contextItems: [String] = []
    ) {
        self.id = id
        self.name = name
        self.goal = goal
        self.icon = icon
        self.pinned = pinned
        self.contextItems = contextItems
    }

    public func toClaudeProject() -> ClaudeProject {
        var p = ClaudeProject(id: id, name: name, goal: goal, icon: icon)
        p.pinned = pinned
        return p
    }
}

public struct ClaudePersistedArtifact: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var language: String
    public var content: String
    public var isHTML: Bool
    public var pinned: Bool
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString, title: String, language: String = "html", content: String,
        isHTML: Bool = true, pinned: Bool = false, updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.language = language
        self.content = content
        self.isHTML = isHTML
        self.pinned = pinned
        self.updatedAt = updatedAt
    }

    public func toClaudeArtifact(dateFormatter: DateFormatter? = nil) -> ClaudeArtifact {
        let fmt = dateFormatter ?? Self.shortDateFormatter()
        let dateString = fmt.string(from: updatedAt)
        let fenced = "```\(language)\n\(content)\n```"
        let doc = ArtifactDocument(
            title: title, date: dateString, author: language.uppercased(),
            tab: isHTML ? "Preview & Code" : "Code",
            sections: [.init(id: "main", title: isHTML ? "Interactive Preview" : "Source", paragraphs: [fenced])])
        return ClaudeArtifact(
            id: id, title: title, kind: isHTML ? .design : .docs, edited: dateString,
            privacy: "Local on device", pinned: pinned, owned: true, darkPreview: isHTML, document: doc)
    }

    private static func shortDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }
}

public struct ClaudePersistedMemoryNote: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var markdown: String
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, title: String, markdown: String, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.updatedAt = updatedAt
    }
}

public struct ClaudeWorkspaceSnapshot: Codable, Equatable, Sendable {
    public var fullName: String
    public var nickname: String
    public var initials: String
    public var instructions: String
    public var appearanceRaw: String
    public var hapticsEnabled: Bool
    public var activeProjectID: UUID?
    public var conversations: [ClaudeConversationSummary]
    public var projects: [ClaudePersistedProject]
    public var artifacts: [ClaudePersistedArtifact]
    public var memoryNotes: [ClaudePersistedMemoryNote]

    public init(
        fullName: String = "", nickname: String = "", initials: String = "AI", instructions: String = "",
        appearanceRaw: String = ClaudeAppearance.dark.rawValue, hapticsEnabled: Bool = true,
        activeProjectID: UUID? = nil, conversations: [ClaudeConversationSummary] = [],
        projects: [ClaudePersistedProject] = [], artifacts: [ClaudePersistedArtifact] = [],
        memoryNotes: [ClaudePersistedMemoryNote] = []
    ) {
        self.fullName = fullName
        self.nickname = nickname
        self.initials = initials
        self.instructions = instructions
        self.appearanceRaw = appearanceRaw
        self.hapticsEnabled = hapticsEnabled
        self.activeProjectID = activeProjectID
        self.conversations = conversations
        self.projects = projects
        self.artifacts = artifacts
        self.memoryNotes = memoryNotes
    }
}

public struct ClaudeWorkspaceStore: Sendable {
    public let fileURL: URL?
    public let isEphemeral: Bool

    public init(directory: URL? = nil, isEphemeral: Bool = false) {
        self.isEphemeral = isEphemeral
        if isEphemeral {
            self.fileURL = nil
        } else if let directory {
            self.fileURL = directory.appendingPathComponent("workspace.json")
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            self.fileURL = base?.appendingPathComponent("ClaudeWorkspace", isDirectory: true)
                .appendingPathComponent("workspace.json")
        }
    }

    public func load() -> ClaudeWorkspaceSnapshot {
        guard !isEphemeral, let fileURL, let data = try? Data(contentsOf: fileURL) else {
            return .init()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ClaudeWorkspaceSnapshot.self, from: data)) ?? .init()
    }

    public func save(_ snapshot: ClaudeWorkspaceSnapshot) {
        guard !isEphemeral, let fileURL else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func clearAll() {
        guard !isEphemeral, let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

public enum ClaudeSlashCommand: Equatable, Sendable {
    case search(String)
    case readURL(String, question: String)
    case htmlApp(String)
    case calculate(String)
    case clear

    public static func parse(_ raw: String) -> Self? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let head = parts.first?.lowercased() else { return nil }
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        switch head {
        case "/clear", "/limpar":
            return .clear
        case "/search", "/ddg", "/web", "/pesquisar":
            return rest.isEmpty ? nil : .search(rest)
        case "/read", "/ler", "/url":
            let tokens = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let urlToken = tokens.first, !urlToken.isEmpty else { return nil }
            let question = tokens.count > 1 ? String(tokens[1]) : ""
            return .readURL(String(urlToken), question: question)
        case "/html", "/preview", "/app":
            return rest.isEmpty ? nil : .htmlApp(rest)
        case "/calc", "/math":
            return rest.isEmpty ? nil : .calculate(rest)
        default:
            return nil
        }
    }
}

public enum ClaudeAgentTools {
    public static func openAIToolDefinitions(includeWebSearch: Bool) -> [[String: Any]] {
        var tools: [[String: Any]] = [
            [
                "type": "function",
                "function": [
                    "name": "read_webpage",
                    "description": "Fetch and read clean text from an HTTP or HTTPS URL.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "url": ["type": "string", "description": "Full http:// or https:// URL to read."]
                        ],
                        "required": ["url"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "calculator",
                    "description":
                        "Evaluate a math expression (+, -, *, /, ^, sqrt, sin, cos, tan, log, ln, pi, e).",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "expression": ["type": "string", "description": "Math expression, e.g. 'sqrt(144) + 2^10'."]
                        ],
                        "required": ["expression"]
                    ]
                ]
            ],
            [
                "type": "function",
                "function": [
                    "name": "current_datetime",
                    "description": "Return the current local date, time, weekday, and timezone on the user's device.",
                    "parameters": ["type": "object", "properties": [:] as [String: Any]]
                ]
            ]
        ]
        if includeWebSearch {
            tools.insert(
                [
                    "type": "function",
                    "function": [
                        "name": "web_search",
                        "description":
                            "Search the live web using DuckDuckGo for up-to-date facts, news, or docs.",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "query": ["type": "string", "description": "Concise search query."]
                            ],
                            "required": ["query"]
                        ]
                    ]
                ], at: 0)
        }
        return tools
    }

    public static func currentDateTimeSummary(now: Date = Date()) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let human = DateFormatter()
        human.dateStyle = .full
        human.timeStyle = .medium
        let tz = TimeZone.current.identifier
        return "\(human.string(from: now)) (\(iso.string(from: now)), TimeZone: \(tz))"
    }

    public static func evaluateMath(_ expression: String) -> Result<Double, MathError> {
        var parser = MathParser(expression)
        return parser.parse()
    }

    public enum MathError: LocalizedError, Equatable, Sendable {
        case invalidSyntax
        case divisionByZero

        public var errorDescription: String? {
            switch self {
            case .invalidSyntax: "Invalid mathematical expression."
            case .divisionByZero: "Division by zero."
            }
        }
    }
}

private struct MathParser {
    private let chars: [Character]
    private var index = 0

    init(_ input: String) {
        self.chars = Array(input.replacingOccurrences(of: ",", with: "."))
    }

    mutating func parse() -> Result<Double, ClaudeAgentTools.MathError> {
        skipSpaces()
        guard index < chars.count else { return .failure(.invalidSyntax) }
        switch parseAddSub() {
        case .success(let val):
            skipSpaces()
            guard index == chars.count, val.isFinite else { return .failure(.invalidSyntax) }
            return .success(val)
        case .failure(let err):
            return .failure(err)
        }
    }

    private mutating func parseAddSub() -> Result<Double, ClaudeAgentTools.MathError> {
        var lhs: Double
        switch parseMulDiv() {
        case .success(let v): lhs = v
        case .failure(let e): return .failure(e)
        }
        while true {
            skipSpaces()
            guard index < chars.count, chars[index] == "+" || chars[index] == "-" else { break }
            let op = chars[index]
            index += 1
            switch parseMulDiv() {
            case .success(let rhs): lhs = (op == "+") ? (lhs + rhs) : (lhs - rhs)
            case .failure(let e): return .failure(e)
            }
        }
        return .success(lhs)
    }

    private mutating func parseMulDiv() -> Result<Double, ClaudeAgentTools.MathError> {
        var lhs: Double
        switch parsePower() {
        case .success(let v): lhs = v
        case .failure(let e): return .failure(e)
        }
        while true {
            skipSpaces()
            guard index < chars.count, chars[index] == "*" || chars[index] == "/" || chars[index] == "%" else {
                break
            }
            let op = chars[index]
            index += 1
            switch parsePower() {
            case .success(let rhs):
                if (op == "/" || op == "%") && rhs == 0 { return .failure(.divisionByZero) }
                if op == "*" {
                    lhs *= rhs
                } else if op == "/" {
                    lhs /= rhs
                } else {
                    lhs = lhs.truncatingRemainder(dividingBy: rhs)
                }
            case .failure(let e):
                return .failure(e)
            }
        }
        return .success(lhs)
    }

    private mutating func parsePower() -> Result<Double, ClaudeAgentTools.MathError> {
        let base: Double
        switch parseUnary() {
        case .success(let v): base = v
        case .failure(let e): return .failure(e)
        }
        skipSpaces()
        if index < chars.count, chars[index] == "^" {
            index += 1
            switch parsePower() {
            case .success(let exp): return .success(pow(base, exp))
            case .failure(let e): return .failure(e)
            }
        }
        return .success(base)
    }

    private mutating func parseUnary() -> Result<Double, ClaudeAgentTools.MathError> {
        skipSpaces()
        guard index < chars.count else { return .failure(.invalidSyntax) }
        if chars[index] == "+" {
            index += 1
            return parseUnary()
        }
        if chars[index] == "-" {
            index += 1
            return parseUnary().map { -$0 }
        }
        return parsePrimary()
    }

    private mutating func parsePrimary() -> Result<Double, ClaudeAgentTools.MathError> {
        skipSpaces()
        guard index < chars.count else { return .failure(.invalidSyntax) }
        if chars[index] == "(" {
            index += 1
            let inner = parseAddSub()
            skipSpaces()
            guard index < chars.count, chars[index] == ")" else { return .failure(.invalidSyntax) }
            index += 1
            return inner
        }
        if chars[index].isLetter {
            let start = index
            while index < chars.count && chars[index].isLetter { index += 1 }
            let ident = String(chars[start..<index]).lowercased()
            if ident == "pi" { return .success(Double.pi) }
            if ident == "e" { return .success(M_E) }
            skipSpaces()
            guard index < chars.count, chars[index] == "(" else { return .failure(.invalidSyntax) }
            index += 1
            let argRes = parseAddSub()
            skipSpaces()
            guard index < chars.count, chars[index] == ")" else { return .failure(.invalidSyntax) }
            index += 1
            guard case .success(let arg) = argRes else { return argRes }
            switch ident {
            case "sqrt": return arg >= 0 ? .success(sqrt(arg)) : .failure(.invalidSyntax)
            case "sin": return .success(sin(arg))
            case "cos": return .success(cos(arg))
            case "tan": return .success(tan(arg))
            case "abs": return .success(abs(arg))
            case "log": return arg > 0 ? .success(log10(arg)) : .failure(.invalidSyntax)
            case "ln": return arg > 0 ? .success(log(arg)) : .failure(.invalidSyntax)
            case "round": return .success(arg.rounded())
            case "floor": return .success(floor(arg))
            case "ceil": return .success(ceil(arg))
            default: return .failure(.invalidSyntax)
            }
        }
        let start = index
        var hasDot = false
        while index < chars.count && (chars[index].isNumber || (!hasDot && chars[index] == ".")) {
            if chars[index] == "." { hasDot = true }
            index += 1
        }
        guard index > start, let num = Double(String(chars[start..<index])) else {
            return .failure(.invalidSyntax)
        }
        return .success(num)
    }

    private mutating func skipSpaces() {
        while index < chars.count && chars[index].isWhitespace { index += 1 }
    }
}

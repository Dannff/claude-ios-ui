import Foundation

public enum ClaudeBYOKPreset: String, CaseIterable, Codable, Equatable, Sendable {
    case openAI = "OpenAI"
    case openRouter = "OpenRouter"
    case groq = "Groq"
    case deepSeek = "DeepSeek"
    case gemini = "Google Gemini"
    case mistral = "Mistral"
    case together = "Together AI"
    case ollama = "Ollama (Local)"
    case lmStudio = "LM Studio (Local)"
    case custom = "Custom"

    public var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .mistral: "https://api.mistral.ai/v1"
        case .together: "https://api.together.xyz/v1"
        case .ollama: "http://localhost:11434/v1"
        case .lmStudio: "http://localhost:1234/v1"
        case .custom: ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o"
        case .openRouter: "anthropic/claude-sonnet-4"
        case .groq: "llama-3.3-70b-versatile"
        case .deepSeek: "deepseek-chat"
        case .gemini: "gemini-2.5-flash"
        case .mistral: "mistral-large-latest"
        case .together: "meta-llama/Llama-3.3-70B-Instruct-Turbo"
        case .ollama: "llama3.2"
        case .lmStudio: "local-model"
        case .custom: ""
        }
    }
}

public struct ClaudeBYOKHeader: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var value: String

    public init(id: String = UUID().uuidString, name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Host-persistable OpenAI-compatible BYOK configuration. Use `withoutAPIKey` when storing
/// non-secret fields in preferences and keep `apiKey` in Keychain.
public struct ClaudeBYOKConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var preset: ClaudeBYOKPreset
    public var customName: String
    public var baseURL: String
    public var apiKey: String
    public var modelID: String
    public var systemPrompt: String
    public var streamResponses: Bool
    public var temperature: Double
    public var webSearchMode: ClaudeWebSearchMode
    public var enableAgentTools: Bool
    public var customHeaders: [ClaudeBYOKHeader]

    public init(
        isEnabled: Bool = false, preset: ClaudeBYOKPreset = .openAI, customName: String = "",
        baseURL: String = ClaudeBYOKPreset.openAI.defaultBaseURL, apiKey: String = "",
        modelID: String = ClaudeBYOKPreset.openAI.defaultModel, systemPrompt: String = "",
        streamResponses: Bool = true, temperature: Double = 0.7,
        webSearchMode: ClaudeWebSearchMode = .auto, enableAgentTools: Bool = true,
        customHeaders: [ClaudeBYOKHeader] = []
    ) {
        self.isEnabled = isEnabled
        self.preset = preset
        self.customName = customName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        self.streamResponses = streamResponses
        self.temperature = Self.clampTemperature(temperature)
        self.webSearchMode = webSearchMode
        self.enableAgentTools = enableAgentTools
        self.customHeaders = customHeaders
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, preset, customName, baseURL, apiKey, modelID, systemPrompt
        case streamResponses, temperature, webSearchMode, enableAgentTools, customHeaders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        preset = try c.decodeIfPresent(ClaudeBYOKPreset.self, forKey: .preset) ?? .openAI
        customName = try c.decodeIfPresent(String.self, forKey: .customName) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? preset.defaultBaseURL
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? preset.defaultModel
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        streamResponses = try c.decodeIfPresent(Bool.self, forKey: .streamResponses) ?? true
        let rawTemp = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        temperature = Self.clampTemperature(rawTemp)
        webSearchMode = try c.decodeIfPresent(ClaudeWebSearchMode.self, forKey: .webSearchMode) ?? .auto
        enableAgentTools = try c.decodeIfPresent(Bool.self, forKey: .enableAgentTools) ?? true
        customHeaders = try c.decodeIfPresent([ClaudeBYOKHeader].self, forKey: .customHeaders) ?? []
    }

    public static func clampTemperature(_ value: Double) -> Double {
        guard value.isFinite else { return 0.7 }
        return min(2.0, max(0.0, (value * 10).rounded() / 10))
    }

    public var trimmedBaseURL: String { baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedModelID: String { modelID.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedSystemPrompt: String { systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var hasAPIKey: Bool { !trimmedAPIKey.isEmpty }

    public var displayName: String {
        let custom = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        if preset == .custom, !custom.isEmpty { return custom }
        return preset.rawValue
    }

    public var shortModelLabel: String {
        let model = trimmedModelID
        guard let slash = model.lastIndex(of: "/"), slash < model.index(before: model.endIndex) else { return model }
        return String(model[model.index(after: slash)...])
    }

    public var resolvedChatCompletionsURL: URL? {
        guard var components = validatedBaseComponents() else { return nil }
        let normalized = Self.normalizedPath(components.path)
        if normalized.isEmpty {
            components.path = "/v1/chat/completions"
        } else if normalized.hasSuffix("/chat/completions") {
            components.path = normalized
        } else {
            components.path = normalized + "/chat/completions"
        }
        return components.url
    }

    public var resolvedModelsURL: URL? {
        guard var components = validatedBaseComponents() else { return nil }
        let normalized = Self.normalizedPath(components.path)
        if normalized.isEmpty {
            components.path = "/v1/models"
        } else if normalized.hasSuffix("/chat/completions") {
            let prefix = String(normalized.dropLast("/chat/completions".count))
            components.path = (prefix.isEmpty ? "/v1" : prefix) + "/models"
        } else if normalized.hasSuffix("/models") {
            components.path = normalized
        } else {
            components.path = normalized + "/models"
        }
        return components.url
    }

    public var isReady: Bool { resolvedChatCompletionsURL != nil && !trimmedModelID.isEmpty }

    public var withoutAPIKey: ClaudeBYOKConfiguration {
        var copy = self
        copy.apiKey = ""
        return copy
    }

    private func validatedBaseComponents() -> URLComponents? {
        let candidate = trimmedBaseURL
        guard !candidate.isEmpty, candidate.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            let components = URLComponents(string: candidate),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil, components.fragment == nil
        else { return nil }
        return components
    }

    private static func normalizedPath(_ rawPath: String) -> String {
        var path = rawPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path == "/" ? "" : path
    }
}

public enum ClaudeBYOKConnectionStatus: Equatable, Sendable {
    case idle
    case testing(UUID)
    case connected(String)
    case failed(String)

    public var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}

@nonexhaustive public enum ClaudeBYOKAction: Equatable, Sendable {
    case open, back
    case setEnabled(Bool)
    case selectPreset(ClaudeBYOKPreset)
    case editCustomName(String)
    case editBaseURL(String)
    case editAPIKey(String)
    case toggleKeyVisibility
    case editModelID(String)
    case selectDiscoveredModel(String)
    case editSystemPrompt(String)
    case setStreamResponses(Bool)
    case setTemperature(Double)
    case setWebSearchMode(ClaudeWebSearchMode)
    case setAgentTools(Bool)
    case addHeader
    case editHeaderName(id: String, String)
    case editHeaderValue(id: String, String)
    case removeHeader(String)
    case testConnection
    case fetchModels
    case clearCredentials
}

/// Presentation state for configuring any OpenAI-compatible BYOK endpoint in Settings.
/// Networking and secure key storage remain owned by the integrating host app.
public struct ClaudeBYOKState: Equatable, Sendable {
    public var configuration: ClaudeBYOKConfiguration
    public var discoveredModels: [String]
    public private(set) var isPresented = false
    public private(set) var isKeyVisible = false
    public private(set) var connectionStatus: ClaudeBYOKConnectionStatus = .idle
    public private(set) var modelsFetchID: UUID?
    public private(set) var fieldRevision = 0

    public init(configuration: ClaudeBYOKConfiguration = .init(), discoveredModels: [String] = []) {
        self.configuration = configuration
        self.discoveredModels = discoveredModels
    }

    public var statusSummary: String {
        guard configuration.isEnabled else { return "" }
        return configuration.isReady ? configuration.displayName : "Setup needed"
    }

    public var activeComposerLabels: (model: String, provider: String)? {
        guard configuration.isEnabled, configuration.isReady else { return nil }
        return (configuration.shortModelLabel, configuration.displayName)
    }

    public var pendingTestID: UUID? {
        if case .testing(let id) = connectionStatus { return id }
        return nil
    }

    public mutating func reduce(_ action: ClaudeBYOKAction) {
        switch action {
        case .open:
            isPresented = true
        case .back:
            close()
        case .setEnabled(let enabled):
            configuration.isEnabled = enabled
        case .selectPreset(let preset):
            let previousDefaultModel = configuration.preset.defaultModel
            configuration.preset = preset
            if preset != .custom { configuration.baseURL = preset.defaultBaseURL }
            let currentModel = configuration.trimmedModelID
            if preset != .custom && (currentModel.isEmpty || currentModel == previousDefaultModel) {
                configuration.modelID = preset.defaultModel
            }
            discoveredModels = []
            modelsFetchID = nil
            connectionStatus = .idle
            fieldRevision &+= 1
        case .editCustomName(let value):
            configuration.customName = value
        case .editBaseURL(let value):
            configuration.baseURL = value
            modelsFetchID = nil
            connectionStatus = .idle
        case .editAPIKey(let value):
            configuration.apiKey = value
            modelsFetchID = nil
            connectionStatus = .idle
        case .toggleKeyVisibility:
            isKeyVisible.toggle()
        case .editModelID(let value):
            configuration.modelID = value
            if case .failed = connectionStatus { connectionStatus = .idle }
        case .selectDiscoveredModel(let model):
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            configuration.modelID = model
            fieldRevision &+= 1
        case .editSystemPrompt(let value):
            configuration.systemPrompt = value
        case .setStreamResponses(let enabled):
            configuration.streamResponses = enabled
        case .setTemperature(let value):
            configuration.temperature = ClaudeBYOKConfiguration.clampTemperature(value)
        case .setWebSearchMode(let mode):
            configuration.webSearchMode = mode
        case .setAgentTools(let enabled):
            configuration.enableAgentTools = enabled
        case .addHeader:
            configuration.customHeaders.append(.init())
        case .editHeaderName(let id, let name):
            guard let index = configuration.customHeaders.firstIndex(where: { $0.id == id }) else { return }
            configuration.customHeaders[index].name = name
        case .editHeaderValue(let id, let value):
            guard let index = configuration.customHeaders.firstIndex(where: { $0.id == id }) else { return }
            configuration.customHeaders[index].value = value
        case .removeHeader(let id):
            configuration.customHeaders.removeAll { $0.id == id }
        case .testConnection:
            guard configuration.resolvedChatCompletionsURL != nil else {
                connectionStatus = .failed("Enter a valid HTTP or HTTPS base URL first.")
                return
            }
            connectionStatus = .testing(UUID())
        case .fetchModels:
            guard configuration.resolvedModelsURL != nil else {
                connectionStatus = .failed("Enter a valid HTTP or HTTPS base URL first.")
                return
            }
            modelsFetchID = UUID()
        case .clearCredentials:
            configuration.apiKey = ""
            configuration.isEnabled = false
            isKeyVisible = false
            discoveredModels = []
            modelsFetchID = nil
            connectionStatus = .idle
            fieldRevision &+= 1
        }
    }

    public mutating func close() {
        isPresented = false
        isKeyVisible = false
        modelsFetchID = nil
        if case .testing = connectionStatus { connectionStatus = .idle }
    }

    public mutating func finishConnectionTest(requestID: UUID, summary: String = "Connected") {
        guard pendingTestID == requestID else { return }
        connectionStatus = .connected(summary)
    }

    public mutating func failConnectionTest(requestID: UUID, message: String) {
        guard pendingTestID == requestID else { return }
        connectionStatus = .failed(message)
    }

    public mutating func finishModelsFetch(requestID: UUID, models: [String]) {
        guard modelsFetchID == requestID else { return }
        modelsFetchID = nil
        var seen = Set<String>()
        let cleaned = models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
        discoveredModels = cleaned
        if configuration.trimmedModelID.isEmpty, let first = cleaned.first {
            configuration.modelID = first
            fieldRevision &+= 1
        }
    }

    public mutating func failModelsFetch(requestID: UUID, message: String) {
        guard modelsFetchID == requestID else { return }
        modelsFetchID = nil
        connectionStatus = .failed(message)
    }
}

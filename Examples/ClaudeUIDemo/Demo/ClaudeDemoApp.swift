import ClaudeUI
import ClaudeWidgets
import Foundation
import Security
import SwiftUI
import WidgetKit

@main
struct ClaudeDemoApp: App {
    @State private var widgetPreview = ProcessInfo.processInfo.arguments.contains("--widgets")
    @State private var widgetCamera = false
    @State private var announcement = ProcessInfo.processInfo.arguments.contains("--announcement")
    @State private var configured = false
    @State private var state = SessionState()
    @State private var persistence = BYOKPersistence.fromProcessEnvironment()
    @State private var dispatchTask: Task<Void, Never>?
    @State private var accountTask: Task<Void, Never>?
    @State private var responseTask: Task<Void, Never>?
    @State private var providerTestTask: Task<Void, Never>?
    @State private var modelsFetchTask: Task<Void, Never>?
    var body: some Scene {
        WindowGroup {
            Group {
                if let screen = DemoScreen(launchArguments: ProcessInfo.processInfo.arguments) {
                    DemoScreenView(
                        screen: screen,
                        appearance: ProcessInfo.processInfo.arguments.contains("--light") ? .light : .dark)
                } else if widgetPreview {
                    WidgetPreview().environment(
                        \.openURL,
                        OpenURLAction { url in
                            routeWidget(url)
                            return .handled
                        })
                } else {
                    ClaudeSessionView(
                        state: $state,
                        mediaContent: demoMediaContent, onAction: handle)
                }
            }
            .onAppear {
                if !configured {
                    configureFixture()
                    configured = true
                }
            }
            .onOpenURL(perform: routeWidget)
            .sheet(isPresented: $announcement) {
                ClaudeWorkAnnouncementView(onDismiss: { announcement = false }) { ClaudeWorkAnnouncementStill() }
                    .presentationDetents([.large]).presentationCornerRadius(40).presentationDragIndicator(.hidden)
            }
            .fullScreenCover(isPresented: $widgetCamera) {
                ClaudeCameraView(onCancel: { widgetCamera = false }, onCapture: { _ in widgetCamera = false }) {
                    LinearGradient(colors: [.gray, .black], startPoint: .top, endPoint: .bottom)
                }
            }
        }
    }
    private func routeWidget(_ url: URL) {
        guard let destination = ClaudeWidgetDestination(url: url) else { return }
        widgetPreview = false
        switch destination {
        case .chat: handle(.newSession)
        case .camera: widgetCamera = true
        case .voice:
            handle(.newSession)
            handle(.startVoice)
        case .code: handle(.openCode)
        case .dispatch: handle(.openDispatch)
        case .newCodeSession:
            handle(.openCode)
            handle(.code(.newSession))
        case .searchCode:
            handle(.openCode)
            handle(.code(.search))
        }
    }
    private func configureFixture() {
        WidgetCenter.shared.reloadAllTimelines()
        state.installDemoFixtures()
        if let savedBYOK = persistence.load() {
            state.settings.apiProvider.configuration = savedBYOK
        }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--video") {
            state.media.draft = [
                .init(
                    id: "garden-video", fileName: "Garden-Motion.mp4", accessibilityDescription: "Garden motion video",
                    aspectRatio: 240.0 / 426, kind: .video)
            ]
        }
        if args.contains("--markdown") { state.messages = [.init(role: .assistant, text: MarkdownFixture.source)] }
        if args.contains("--light") { state.appearance = .light }
        if args.contains("--typed") { state.draft = "Reply with a short greeting." }
        if args.contains("--complete") {
            state.messages = [
                .init(role: .user, text: "Reply with a short greeting."),
                .init(role: .assistant, text: "Hey Jordan! What's on your mind tonight?")
            ]
        }
        if args.contains("--editing"), let message = state.messages.first { state.reduce(.beginEditing(message.id)) }
        if args.contains("--dictation") { state.reduce(.startDictation) }
        if args.contains("--waveform") {
            state.reduce(.startDictation)
            state.dictationLevels = [0, 0.1, 0.3, 0.8, 1, 0.5, 0.2, 0, 0.4, 0.7, 1, 0.3, 0.1, 0]
        }
        if args.contains("--artifacts") { handle(.openArtifacts) }
        if args.contains("--artifact-document") {
            handle(.openArtifacts)
            handle(.artifacts(.open("garden")))
        }
        if args.contains("--code") { handle(.openCode) }
        if args.contains("--code-new-session") {
            handle(.openCode)
            handle(.code(.newSession))
        }
        if args.contains("--dispatch") { handle(.openDispatch) }
        if args.contains("--voice") { state.reduce(.startVoice) }
        if args.contains("--long-draft") {
            state.draft = String(repeating: "A thoughtful interface makes room for the details. ", count: 32)
        }
    }
    private func handle(_ action: ClaudeAction) {
        if action == .stop || action == .newSession {
            responseTask?.cancel()
            responseTask = nil
        }
        state.reduce(action)
        switch action {
        case .send, .retry:
            guard let responseID = state.responseID else { return }
            responseTask?.cancel()
            let byok = state.settings.apiProvider.configuration
            if byok.isEnabled {
                let history = state.messages
                let fallbackInstructions = state.settings.profile.instructions
                responseTask = Task { @MainActor in
                    await runBYOKCompletion(
                        configuration: byok, messages: history, fallbackInstructions: fallbackInstructions,
                        responseID: responseID)
                }
            } else {
                responseTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    let response = "Hey Jordan! What's on your mind tonight?"
                    for word in response.split(separator: " ") {
                        guard !Task.isCancelled else { return }
                        state.appendResponse(
                            (state.messages.last?.role == .assistant ? " " : "") + word, responseID: responseID)
                        try? await Task.sleep(for: .milliseconds(140))
                    }
                    guard !Task.isCancelled else { return }
                    state.finishResponse(responseID: responseID)
                }
            }
        case .settings(.apiProvider(let byokAction)):
            persistence.save(state.settings.apiProvider.configuration)
            switch byokAction {
            case .testConnection:
                guard let requestID = state.settings.apiProvider.pendingTestID else { return }
                let config = state.settings.apiProvider.configuration
                providerTestTask?.cancel()
                providerTestTask = Task { @MainActor in
                    do {
                        let summary = try await OpenAICompatibleClient.testConnection(configuration: config)
                        guard !Task.isCancelled else { return }
                        state.settings.apiProvider.finishConnectionTest(requestID: requestID, summary: summary)
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        state.settings.apiProvider.failConnectionTest(
                            requestID: requestID, message: error.localizedDescription)
                    }
                }
            case .fetchModels:
                guard let requestID = state.settings.apiProvider.modelsFetchID else { return }
                let config = state.settings.apiProvider.configuration
                modelsFetchTask?.cancel()
                modelsFetchTask = Task { @MainActor in
                    do {
                        let models = try await OpenAICompatibleClient.fetchModels(configuration: config)
                        guard !Task.isCancelled else { return }
                        state.settings.apiProvider.finishModelsFetch(requestID: requestID, models: models)
                        persistence.save(state.settings.apiProvider.configuration)
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        state.settings.apiProvider.failModelsFetch(
                            requestID: requestID, message: error.localizedDescription)
                    }
                }
            case .back, .clearCredentials:
                providerTestTask?.cancel()
                modelsFetchTask?.cancel()
            default:
                break
            }
        case .openDispatch, .dispatch(.reload):
            guard let requestID = state.dispatch.loadID else { return }
            dispatchTask?.cancel()
            dispatchTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                state.dispatch.finishLoading(DemoHostResponses.dispatchWelcome, requestID: requestID)
            }
        case .devices(.openManage):
            guard let requestID = state.devices.accountRequestID else { return }
            accountTask?.cancel()
            accountTask = nil
            accountTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                state.devices.finishAccountLoad(DemoHostResponses.accountProfile, requestID: requestID)
            }
        case .devices(.closeManage):
            accountTask?.cancel()
            accountTask = nil
        case .code(.copyRemoteCommand): UIPasteboard.general.string = "claude rc"
        case .devices(.copyOrganizationID): UIPasteboard.general.string = state.devices.profile.organizationID
        case .markdown(_, .copyCode(let text)), .artifacts(.markdown(.copyCode(let text))):
            UIPasteboard.general.string = text
        case .media(.copyFileName(let item)): UIPasteboard.general.string = item.fileName
        case .settings(.memory(.submitInstruction)):
            if ProcessInfo.processInfo.arguments.contains("--memory-clear-after-submit") {
                state.reduce(.settings(.memory(.replaceDraft(""))))
            }
        case .settings(.submitProfile):
            if let submission = state.settings.pendingProfile {
                state.settings.acknowledgeProfile(requestID: submission.id)
            }
        case .copy(let id):
            if let message = state.messages.first(where: { $0.id == id }) { UIPasteboard.general.string = message.text }
        default: break
        }
    }
    @MainActor private func runBYOKCompletion(
        configuration: ClaudeBYOKConfiguration, messages: [ChatMessage], fallbackInstructions: String,
        responseID: UUID
    ) async {
        guard configuration.isReady else {
            state.appendResponse(
                "BYOK provider is enabled, but Base URL or Model is missing. Check Settings → API provider.",
                responseID: responseID)
            state.finishResponse(responseID: responseID)
            return
        }
        do {
            try await OpenAICompatibleClient.complete(
                configuration: configuration, messages: messages, fallbackSystemPrompt: fallbackInstructions
            ) { chunk in
                await MainActor.run {
                    state.appendResponse(chunk, responseID: responseID)
                }
            }
            guard !Task.isCancelled else { return }
            state.finishResponse(responseID: responseID)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            let prefix = state.messages.last?.role == .assistant ? "\n\n" : ""
            state.appendResponse(prefix + "Provider error: " + error.localizedDescription, responseID: responseID)
            state.finishResponse(responseID: responseID)
        }
    }
}

struct DemoPhoto: View {
    let item: ClaudeMedia
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [.init(red: 0.6, green: 0.77, blue: 0.78), .init(red: 0.93, green: 0.87, blue: 0.64)],
                    startPoint: .top, endPoint: .bottom)
                Circle().fill(.white.opacity(0.85)).frame(width: geometry.size.width * 0.18).offset(
                    x: geometry.size.width * 0.23, y: -geometry.size.height * 0.25)
                Ellipse().fill(Color(red: 0.3, green: 0.5, blue: 0.35)).frame(
                    width: geometry.size.width * 1.7, height: geometry.size.height * 0.7
                ).offset(x: -geometry.size.width * 0.25, y: geometry.size.height * 0.4)
                Ellipse().fill(Color(red: 0.17, green: 0.36, blue: 0.24)).frame(
                    width: geometry.size.width * 1.5, height: geometry.size.height * 0.8
                ).offset(x: geometry.size.width * 0.45, y: geometry.size.height * 0.45)
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
}

struct BYOKPersistence: Sendable {
    private let suiteName: String?
    private let keychainService: String
    private let isEphemeral: Bool
    private static let defaultsKey = "claude.byok.configuration"
    private static let keychainAccount = "openai-compatible-api-key"

    static func fromProcessEnvironment() -> BYOKPersistence {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--byok-suite"), index + 1 < args.count {
            let suite = args[index + 1]
            let store = BYOKPersistence(
                suiteName: suite, keychainService: "org.community.claudeui.demo.byok." + suite, isEphemeral: false)
            if args.contains("--byok-reset") { store.reset() }
            return store
        }
        let underXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return BYOKPersistence(
            suiteName: nil, keychainService: "org.community.claudeui.demo.byok", isEphemeral: underXCTest)
    }

    func load() -> ClaudeBYOKConfiguration? {
        guard !isEphemeral, let defaults = resolvedDefaults(),
            let data = defaults.data(forKey: Self.defaultsKey),
            var config = try? JSONDecoder().decode(ClaudeBYOKConfiguration.self, from: data)
        else { return nil }
        config.apiKey = loadAPIKey()
        return config
    }

    func save(_ configuration: ClaudeBYOKConfiguration) {
        guard !isEphemeral, let defaults = resolvedDefaults() else { return }
        if let data = try? JSONEncoder().encode(configuration.withoutAPIKey) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        saveAPIKey(configuration.apiKey)
    }

    func reset() {
        resolvedDefaults()?.removeObject(forKey: Self.defaultsKey)
        saveAPIKey("")
    }

    private func resolvedDefaults() -> UserDefaults? {
        if let suiteName { return UserDefaults(suiteName: suiteName) }
        return .standard
    }

    private func loadAPIKey() -> String {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func saveAPIKey(_ apiKey: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(baseQuery as CFDictionary)
        guard !apiKey.isEmpty, let data = apiKey.data(using: .utf8) else { return }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

enum BYOKClientError: LocalizedError, Sendable {
    case invalidEndpoint
    case missingModel
    case httpError(statusCode: Int, detail: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Invalid HTTP or HTTPS endpoint URL."
        case .missingModel: "Enter a model identifier before testing or sending."
        case .httpError(let code, let detail):
            detail.isEmpty ? "HTTP \(code) from provider." : "HTTP \(code): \(detail)"
        case .emptyResponse: "Provider returned an empty response."
        }
    }
}

enum OpenAICompatibleClient {
    private struct RequestMessage: Encodable, Sendable {
        let role: String
        let content: String
    }

    private struct ChatRequestBody: Encodable, Sendable {
        let model: String
        let messages: [RequestMessage]
        let stream: Bool
        let max_tokens: Int?
    }

    private struct ChatResponseBody: Decodable, Sendable {
        struct Choice: Decodable, Sendable {
            struct Message: Decodable, Sendable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct StreamChunk: Decodable, Sendable {
        struct Choice: Decodable, Sendable {
            struct Delta: Decodable, Sendable {
                let content: String?
            }
            let delta: Delta
        }
        let choices: [Choice]
    }

    private struct ModelsResponseBody: Decodable, Sendable {
        struct ModelEntry: Decodable, Sendable {
            let id: String
        }
        let data: [ModelEntry]
    }

    private struct ErrorEnvelope: Decodable, Sendable {
        struct Detail: Decodable, Sendable {
            let message: String?
        }
        let error: Detail?
    }

    static func fetchModels(configuration: ClaudeBYOKConfiguration) async throws -> [String] {
        guard let url = configuration.resolvedModelsURL else { throw BYOKClientError.invalidEndpoint }
        let request = makeRequest(url: url, method: "GET", configuration: configuration)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response: response, body: data)
        let decoded = try JSONDecoder().decode(ModelsResponseBody.self, from: data)
        return decoded.data.map(\.id)
    }

    static func testConnection(configuration: ClaudeBYOKConfiguration) async throws -> String {
        guard let chatURL = configuration.resolvedChatCompletionsURL else { throw BYOKClientError.invalidEndpoint }
        if let modelsURL = configuration.resolvedModelsURL {
            let request = makeRequest(url: modelsURL, method: "GET", configuration: configuration)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                if let decoded = try? JSONDecoder().decode(ModelsResponseBody.self, from: data), !decoded.data.isEmpty {
                    return "Connected · \(decoded.data.count) model(s) available"
                }
                return "Connected to " + configuration.displayName
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 404, http.statusCode != 405 {
                try validateHTTP(response: response, body: data)
            }
        }
        let model = configuration.trimmedModelID
        guard !model.isEmpty else { throw BYOKClientError.missingModel }
        var request = makeRequest(url: chatURL, method: "POST", configuration: configuration)
        let pingBody = ChatRequestBody(
            model: model, messages: [.init(role: "user", content: "ping")], stream: false, max_tokens: 1)
        request.httpBody = try JSONEncoder().encode(pingBody)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response: response, body: data)
        return "Connected to " + configuration.displayName
    }

    static func complete(
        configuration: ClaudeBYOKConfiguration, messages: [ChatMessage], fallbackSystemPrompt: String,
        onToken: @Sendable (String) async -> Void
    ) async throws {
        guard let url = configuration.resolvedChatCompletionsURL else { throw BYOKClientError.invalidEndpoint }
        let model = configuration.trimmedModelID
        guard !model.isEmpty else { throw BYOKClientError.missingModel }

        var payloadMessages: [RequestMessage] = []
        let customSystem = configuration.trimmedSystemPrompt
        let fallbackSystem = fallbackSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemText = customSystem.isEmpty ? fallbackSystem : customSystem
        if !systemText.isEmpty {
            payloadMessages.append(.init(role: "system", content: systemText))
        }
        for item in messages {
            payloadMessages.append(.init(role: item.role.rawValue, content: item.text))
        }

        var request = makeRequest(
            url: url, method: "POST", configuration: configuration, acceptSSE: configuration.streamResponses)
        let body = ChatRequestBody(
            model: model, messages: payloadMessages, stream: configuration.streamResponses, max_tokens: nil)
        request.httpBody = try JSONEncoder().encode(body)

        if configuration.streamResponses {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                var errorData = Data()
                for try await byte in bytes {
                    errorData.append(byte)
                    if errorData.count >= 8192 { break }
                }
                try validateHTTP(response: response, body: errorData)
            }
            let contentType =
                (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if contentType.contains("application/json") {
                var fullData = Data()
                for try await byte in bytes { fullData.append(byte) }
                let decoded = try JSONDecoder().decode(ChatResponseBody.self, from: fullData)
                guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
                    throw BYOKClientError.emptyResponse
                }
                await onToken(content)
                return
            }
            var receivedContent = false
            for try await line in bytes.lines {
                try Task.checkCancellation()
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data:") else { continue }
                let rawPayload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if rawPayload == "[DONE]" { break }
                guard let chunkData = rawPayload.data(using: .utf8),
                    let chunk = try? JSONDecoder().decode(StreamChunk.self, from: chunkData)
                else { continue }
                if let piece = chunk.choices.first?.delta.content, !piece.isEmpty {
                    receivedContent = true
                    await onToken(piece)
                }
            }
            if !receivedContent { throw BYOKClientError.emptyResponse }
        } else {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTP(response: response, body: data)
            let decoded = try JSONDecoder().decode(ChatResponseBody.self, from: data)
            guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
                throw BYOKClientError.emptyResponse
            }
            await onToken(content)
        }
    }

    private static func makeRequest(
        url: URL, method: String, configuration: ClaudeBYOKConfiguration, acceptSSE: Bool = false
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        if method == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(acceptSSE ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if configuration.hasAPIKey {
            request.setValue("Bearer " + configuration.trimmedAPIKey, forHTTPHeaderField: "Authorization")
        }
        for header in configuration.customHeaders where !header.trimmedName.isEmpty {
            request.setValue(header.trimmedValue, forHTTPHeaderField: header.trimmedName)
        }
        return request
    }

    private static func validateHTTP(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body),
            let message = envelope.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty
        {
            throw BYOKClientError.httpError(statusCode: http.statusCode, detail: message)
        }
        if let stringDict = try? JSONDecoder().decode([String: String].self, from: body),
            let message = stringDict["error"]?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty
        {
            throw BYOKClientError.httpError(statusCode: http.statusCode, detail: message)
        }
        let rawBody = String(data: body.prefix(240), encoding: .utf8) ?? ""
        let fallback = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        throw BYOKClientError.httpError(statusCode: http.statusCode, detail: fallback)
    }
}

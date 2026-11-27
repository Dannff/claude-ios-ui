import Foundation
import Testing
@testable import ClaudeUI

@Test func byokEndpointNormalizationSupportsRootVersionedAndExplicitPaths() {
    let cases: [(String, String?, String?)] = [
        (
            "https://api.openai.com",
            "https://api.openai.com/v1/chat/completions",
            "https://api.openai.com/v1/models"
        ),
        (
            "https://api.openai.com/v1/",
            "https://api.openai.com/v1/chat/completions",
            "https://api.openai.com/v1/models"
        ),
        (
            "https://openrouter.ai/api/v1",
            "https://openrouter.ai/api/v1/chat/completions",
            "https://openrouter.ai/api/v1/models"
        ),
        (
            "https://gateway.example.com/proxy/chat/completions",
            "https://gateway.example.com/proxy/chat/completions",
            "https://gateway.example.com/proxy/models"
        ),
        (
            "http://localhost:11434/v1",
            "http://localhost:11434/v1/chat/completions",
            "http://localhost:11434/v1/models"
        ),
        ("", nil, nil),
        ("ftp://api.openai.com/v1", nil, nil),
        ("https://user:secret@api.openai.com/v1", nil, nil),
        ("https://api.openai.com/v1#section", nil, nil),
        ("https://bad host.example.com/v1", nil, nil)
    ]
    for (input, expectedChat, expectedModels) in cases {
        let config = ClaudeBYOKConfiguration(baseURL: input)
        #expect(config.resolvedChatCompletionsURL?.absoluteString == expectedChat)
        #expect(config.resolvedModelsURL?.absoluteString == expectedModels)
    }
}

@Test func byokPresetSelectionUpdatesDefaultEndpointAndPreservesCustomModel() {
    var state = ClaudeBYOKState()
    #expect(state.configuration.preset == .openAI)
    #expect(state.configuration.baseURL == "https://api.openai.com/v1")
    #expect(state.configuration.modelID == "gpt-4o")

    state.reduce(.selectPreset(.openRouter))
    #expect(state.configuration.baseURL == "https://openrouter.ai/api/v1")
    #expect(state.configuration.modelID == "anthropic/claude-sonnet-4")
    #expect(state.configuration.shortModelLabel == "claude-sonnet-4")

    state.reduce(.editModelID("my-org/custom-finetune"))
    state.reduce(.selectPreset(.groq))
    #expect(state.configuration.baseURL == "https://api.groq.com/openai/v1")
    #expect(state.configuration.modelID == "my-org/custom-finetune")

    state.reduce(.selectPreset(.custom))
    state.reduce(.editCustomName("Local Gateway"))
    #expect(state.configuration.displayName == "Local Gateway")
}

@Test func byokWithoutAPIKeyRedactsSecretWhileCodablePreservesConfiguration() throws {
    let config = ClaudeBYOKConfiguration(
        isEnabled: true, preset: .deepSeek, baseURL: "https://api.deepseek.com/v1", apiKey: "sk-secret-123",
        modelID: "deepseek-chat", systemPrompt: "Be concise", streamResponses: false,
        customHeaders: [.init(id: "h1", name: "X-Title", value: "Claude UI")])
    let redacted = config.withoutAPIKey
    #expect(redacted.apiKey.isEmpty)
    #expect(redacted.isEnabled)
    #expect(redacted.modelID == "deepseek-chat")
    #expect(redacted.customHeaders == config.customHeaders)

    let restored = try JSONDecoder().decode(ClaudeBYOKConfiguration.self, from: JSONEncoder().encode(redacted))
    #expect(restored == redacted)
}

@Test func byokConnectionAndModelRequestsRejectStaleTokensAndClearResetsSecret() {
    var state = ClaudeBYOKState()
    state.reduce(.open)
    state.reduce(.editAPIKey("sk-live"))
    state.reduce(.setEnabled(true))
    #expect(state.statusSummary == "OpenAI")
    #expect(state.activeComposerLabels?.model == "gpt-4o")
    #expect(state.activeComposerLabels?.provider == "OpenAI")

    state.reduce(.testConnection)
    let firstTest = state.pendingTestID!
    state.reduce(.editBaseURL("https://openrouter.ai/api/v1"))
    state.finishConnectionTest(requestID: firstTest, summary: "Stale")
    #expect(state.connectionStatus == .idle)

    state.reduce(.testConnection)
    let activeTest = state.pendingTestID!
    state.finishConnectionTest(requestID: activeTest, summary: "Connected")
    #expect(state.connectionStatus == .connected("Connected"))

    state.reduce(.fetchModels)
    let fetchID = state.modelsFetchID!
    state.finishModelsFetch(requestID: UUID(), models: ["ignored"])
    #expect(state.discoveredModels.isEmpty)
    state.finishModelsFetch(requestID: fetchID, models: [" gpt-4.1 ", "o4-mini", "gpt-4.1", ""])
    #expect(state.discoveredModels == ["gpt-4.1", "o4-mini"])
    state.reduce(.selectDiscoveredModel("o4-mini"))
    #expect(state.configuration.modelID == "o4-mini")

    state.reduce(.toggleKeyVisibility)
    #expect(state.isKeyVisible)
    state.reduce(.clearCredentials)
    #expect(!state.configuration.hasAPIKey)
    #expect(!state.configuration.isEnabled)
    #expect(!state.isKeyVisible)
    #expect(state.discoveredModels.isEmpty)
    #expect(state.statusSummary.isEmpty)
    #expect(state.activeComposerLabels == nil)
}

@Test func byokCustomHeadersAndSettingsNavigationPreserveConfigurationAcrossNewSession() {
    var session = SessionState()
    session.reduce(.settings(.open(.profile)))
    session.reduce(.settings(.apiProvider(.open)))
    #expect(session.settings.destination == nil)
    #expect(session.settings.apiProvider.isPresented)

    session.reduce(.settings(.apiProvider(.addHeader)))
    let headerID = session.settings.apiProvider.configuration.customHeaders[0].id
    session.reduce(.settings(.apiProvider(.editHeaderName(id: headerID, "HTTP-Referer"))))
    session.reduce(.settings(.apiProvider(.editHeaderValue(id: headerID, "https://example.app"))))
    session.reduce(.settings(.apiProvider(.editAPIKey("sk-persist"))))
    session.reduce(.settings(.apiProvider(.setEnabled(true))))

    session.reduce(.newSession)
    #expect(!session.settings.apiProvider.isPresented)
    #expect(session.settings.apiProvider.configuration.isEnabled)
    #expect(session.settings.apiProvider.configuration.apiKey == "sk-persist")
    #expect(session.settings.apiProvider.configuration.customHeaders.first?.trimmedName == "HTTP-Referer")

    session.reduce(.settings(.apiProvider(.removeHeader(headerID))))
    #expect(session.settings.apiProvider.configuration.customHeaders.isEmpty)
}

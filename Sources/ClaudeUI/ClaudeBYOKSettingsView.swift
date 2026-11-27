#if canImport(UIKit)
    import SwiftUI

    struct ClaudeBYOKSettingsView: View {
        let state: ClaudeBYOKState
        let action: (ClaudeBYOKAction) -> Void
        private let destructiveColor = Color(red: 0.86, green: 0.59, blue: 0.59)

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    enableGroup
                    sectionLabel("Provider")
                    providerGroup
                    resolvedEndpointCaption
                    sectionLabel("Model & streaming")
                    modelGroup
                    sectionLabel("Custom headers")
                    headersGroup
                    connectionGroup
                    clearGroup
                }.padding(.horizontal, 16).padding(.top, 26).padding(.bottom, 24)
            }.scrollDismissesKeyboard(.interactively).accessibilityIdentifier("settings.byok.scroll")
        }

        private var enableGroup: some View {
            RowGroup {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use OpenAI-compatible endpoint").scaledFont(17)
                        Text("Send chat messages to any Bring Your Own Key (BYOK) provider.")
                            .scaledFont(13, relativeTo: .footnote).foregroundStyle(ClaudePalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(
                        "Use OpenAI-compatible endpoint",
                        isOn: Binding(get: { state.configuration.isEnabled }, set: { action(.setEnabled($0)) })
                    ).labelsHidden().tint(ClaudeSettingsColors.switchTint).frame(width: 63)
                        .accessibilityIdentifier("settings.byok.enabled")
                }.padding(.horizontal, 16).padding(.vertical, 16)
            }
        }

        private var providerGroup: some View {
            RowGroup {
                HStack {
                    Text("Preset").scaledFont(17)
                    Spacer()
                    Menu {
                        Picker(
                            "Preset",
                            selection: Binding(
                                get: { state.configuration.preset }, set: { action(.selectPreset($0)) })
                        ) {
                            ForEach(ClaudeBYOKPreset.allCases, id: \.self) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(state.configuration.preset.rawValue)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold))
                        }.scaledFont(17).foregroundStyle(ClaudeSettingsColors.switchTint)
                            .frame(minHeight: 44)
                    }.accessibilityIdentifier("settings.byok.preset")
                }.padding(.horizontal, 16).frame(minHeight: 52)
                if state.configuration.preset == .custom {
                    RowDivider()
                    fieldRow(
                        title: "Name", text: state.configuration.customName, placeholder: "Custom gateway",
                        identifier: "settings.byok.customName", disablesAutocapitalization: false
                    ) { action(.editCustomName($0)) }
                }
                RowDivider()
                fieldRow(
                    title: "Base URL", text: state.configuration.baseURL, placeholder: "https://api.openai.com/v1",
                    identifier: "settings.byok.baseURL", isURL: true
                ) { action(.editBaseURL($0)) }
                RowDivider()
                HStack(spacing: 0) {
                    Text("API key").scaledFont(17).foregroundStyle(ClaudePalette.secondary)
                        .frame(width: 92, alignment: .leading)
                    ClaudeProfileTextField(
                        text: state.configuration.apiKey, placeholder: "sk-... (optional for local)",
                        identifier: "settings.byok.apiKey", update: { action(.editAPIKey($0)) },
                        isSecure: !state.isKeyVisible, disablesAutocapitalization: true,
                        revision: state.fieldRevision)
                    Button {
                        action(.toggleKeyVisibility)
                    } label: {
                        Image(systemName: state.isKeyVisible ? "eye.slash" : "eye").font(.system(size: 16))
                            .foregroundStyle(ClaudePalette.secondary).frame(width: 44, height: 44)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(state.isKeyVisible ? "Hide API key" : "Show API key")
                        .accessibilityIdentifier("settings.byok.toggleKey")
                }.padding(.leading, 16).padding(.trailing, 6).frame(height: 52)
            }
        }

        private var resolvedEndpointCaption: some View {
            Group {
                if let url = state.configuration.resolvedChatCompletionsURL {
                    Text("Endpoint: " + url.absoluteString)
                } else {
                    Text("Enter a valid HTTP or HTTPS base URL, such as https://openrouter.ai/api/v1.")
                }
            }.scaledFont(13, relativeTo: .footnote).foregroundStyle(ClaudePalette.secondary)
                .padding(.horizontal, 16).padding(.top, -8).accessibilityIdentifier("settings.byok.endpointPreview")
        }

        private var modelGroup: some View {
            RowGroup {
                HStack(spacing: 8) {
                    Text("Model").scaledFont(17).foregroundStyle(ClaudePalette.secondary)
                        .frame(width: 92, alignment: .leading)
                    ClaudeProfileTextField(
                        text: state.configuration.modelID, placeholder: "gpt-4o",
                        identifier: "settings.byok.model", update: { action(.editModelID($0)) },
                        disablesAutocapitalization: true, revision: state.fieldRevision)
                    if !state.discoveredModels.isEmpty {
                        Menu {
                            ForEach(state.discoveredModels, id: \.self) { model in
                                Button(model) { action(.selectDiscoveredModel(model)) }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down.circle").font(.system(size: 19))
                                .foregroundStyle(ClaudeSettingsColors.switchTint).frame(width: 44, height: 44)
                        }.accessibilityLabel("Select discovered model")
                            .accessibilityIdentifier("settings.byok.modelPicker")
                    }
                }.padding(.leading, 16).padding(.trailing, state.discoveredModels.isEmpty ? 16 : 6).frame(height: 52)
                RowDivider()
                Button {
                    action(.fetchModels)
                } label: {
                    HStack(spacing: 12) {
                        if state.modelsFetchID != nil {
                            ProgressView().frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 17))
                                .foregroundStyle(ClaudeSettingsColors.switchTint).frame(width: 22)
                        }
                        Text(
                            state.discoveredModels.isEmpty
                                ? "Load models from endpoint"
                                : "Reload models (\(state.discoveredModels.count) loaded)"
                        ).scaledFont(17).foregroundStyle(ClaudeSettingsColors.switchTint)
                        Spacer()
                    }.padding(.horizontal, 16).frame(height: 50).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .disabled(state.configuration.resolvedModelsURL == nil || state.modelsFetchID != nil)
                    .accessibilityIdentifier("settings.byok.fetchModels")
                RowDivider()
                Toggle(
                    "Stream responses (SSE)",
                    isOn: Binding(
                        get: { state.configuration.streamResponses }, set: { action(.setStreamResponses($0)) })
                ).scaledFont(17).tint(ClaudeSettingsColors.switchTint).padding(.horizontal, 16).frame(height: 52)
                    .accessibilityIdentifier("settings.byok.stream")
                RowDivider()
                fieldRow(
                    title: "System", text: state.configuration.systemPrompt,
                    placeholder: "Optional system instructions", identifier: "settings.byok.systemPrompt",
                    disablesAutocapitalization: false
                ) { action(.editSystemPrompt($0)) }
            }
        }

        private var headersGroup: some View {
            RowGroup {
                ForEach(state.configuration.customHeaders) { header in
                    HStack(spacing: 8) {
                        ClaudeProfileTextField(
                            text: header.name, placeholder: "Header",
                            identifier: "settings.byok.header.name." + header.id,
                            update: { action(.editHeaderName(id: header.id, $0)) }, disablesAutocapitalization: true,
                            revision: state.fieldRevision)
                        Divider().frame(height: 24)
                        ClaudeProfileTextField(
                            text: header.value, placeholder: "Value",
                            identifier: "settings.byok.header.value." + header.id,
                            update: { action(.editHeaderValue(id: header.id, $0)) }, disablesAutocapitalization: true,
                            revision: state.fieldRevision)
                        Button {
                            action(.removeHeader(header.id))
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(destructiveColor)
                                .frame(width: 44, height: 44)
                        }.buttonStyle(.plain).accessibilityLabel("Remove header")
                            .accessibilityIdentifier("settings.byok.header.remove." + header.id)
                    }.padding(.leading, 16).padding(.trailing, 6).frame(height: 50)
                    RowDivider()
                }
                Button {
                    action(.addHeader)
                } label: {
                    Label("Add custom header", systemImage: "plus").scaledFont(17)
                        .foregroundStyle(ClaudeSettingsColors.switchTint)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 50)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("settings.byok.addHeader")
            }
        }

        private var connectionGroup: some View {
            VStack(alignment: .leading, spacing: 8) {
                RowGroup {
                    Button {
                        action(.testConnection)
                    } label: {
                        HStack(spacing: 12) {
                            if state.connectionStatus.isTesting {
                                ProgressView().frame(width: 22, height: 22)
                            } else {
                                Image(systemName: "bolt.horizontal.circle").font(.system(size: 19))
                                    .foregroundStyle(ClaudeSettingsColors.switchTint).frame(width: 22)
                            }
                            Text(state.connectionStatus.isTesting ? "Testing connection…" : "Test connection")
                                .scaledFont(17).foregroundStyle(ClaudeSettingsColors.switchTint)
                            Spacer()
                        }.padding(.horizontal, 16).frame(height: 52).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(state.connectionStatus.isTesting)
                        .accessibilityIdentifier("settings.byok.test")
                }
                switch state.connectionStatus {
                case .idle, .testing:
                    EmptyView()
                case .connected(let summary):
                    Label(summary, systemImage: "checkmark.circle.fill").scaledFont(14, relativeTo: .subheadline)
                        .foregroundStyle(.green).padding(.horizontal, 16)
                        .accessibilityIdentifier("settings.byok.status")
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(14, relativeTo: .subheadline).foregroundStyle(ClaudePalette.orange)
                        .padding(.horizontal, 16).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.byok.status")
                }
            }
        }

        private var clearGroup: some View {
            RowGroup {
                Button {
                    action(.clearCredentials)
                } label: {
                    Label("Clear API key & disable", systemImage: "trash").scaledFont(17)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 52)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(destructiveColor).accessibilityIdentifier("settings.byok.clear")
            }
        }

        private func fieldRow(
            title: String, text: String, placeholder: String, identifier: String, isURL: Bool = false,
            disablesAutocapitalization: Bool = true, update: @escaping (String) -> Void
        ) -> some View {
            HStack(spacing: 0) {
                Text(title).scaledFont(17).foregroundStyle(ClaudePalette.secondary)
                    .frame(width: 92, alignment: .leading)
                ClaudeProfileTextField(
                    text: text, placeholder: placeholder, identifier: identifier, update: update, isURL: isURL,
                    disablesAutocapitalization: disablesAutocapitalization, revision: state.fieldRevision)
            }.padding(.horizontal, 16).frame(height: 52)
        }

        private func sectionLabel(_ title: String) -> some View {
            Text(title).scaledFont(15, relativeTo: .subheadline).foregroundStyle(ClaudePalette.secondary)
                .padding(.leading, 16).padding(.top, 4).padding(.bottom, -6)
        }
    }
#endif

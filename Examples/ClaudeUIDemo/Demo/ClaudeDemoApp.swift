import AVFoundation
import ClaudeUI
import ClaudeWidgets
import Foundation
import NaturalLanguage
import Security
import Speech
import SwiftUI
import UIKit
import WidgetKit

@main
struct ClaudeDemoApp: App {
    @State private var widgetPreview = ProcessInfo.processInfo.arguments.contains("--widgets")
    @State private var widgetCamera = false
    @State private var announcement = ProcessInfo.processInfo.arguments.contains("--announcement")
    @State private var configured = false
    @State private var isDemoFixtureMode = false
    @State private var state = SessionState()
    @State private var persistence = BYOKPersistence.fromProcessEnvironment()
    @State private var workspaceStore = ClaudeWorkspaceStore(
        isEphemeral: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
    @State private var persistedProjects: [ClaudePersistedProject] = []
    @State private var persistedArtifacts: [ClaudePersistedArtifact] = []
    @State private var persistedMemoryNotes: [ClaudePersistedMemoryNote] = []
    @State private var attachedImages: [String: UIImage] = [:]
    @State private var messageAttachmentPayloads: [UUID: [ClaudeAttachmentPayload]] = [:]
    @State private var speechController = SpeechSynthesizerController()
    @State private var dictationController = LiveSpeechDictationController()
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
                        mediaContent: renderMediaContent,
                        onAction: handle)
                }
            }
            .onAppear {
                if !configured {
                    configureInitialState()
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

    private func renderMediaContent(_ item: ClaudeMedia, _ presentation: ClaudeMediaPresentation) -> AnyView {
        if let image = attachedImages[item.id] {
            return AnyView(
                Image(uiImage: image).resizable().scaledToFill()
            )
        }
        return demoMediaContent(item, presentation)
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

    private static func shouldInstallDemoFixtures(arguments: [String], environment: [String: String]) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        let fixtureFlags: Set<String> = [
            "--demo-fixtures", "--video", "--markdown", "--typed", "--complete", "--editing",
            "--dictation", "--waveform", "--artifacts", "--artifact-document", "--code",
            "--code-new-session", "--dispatch", "--voice", "--long-draft"
        ]
        return arguments.contains { fixtureFlags.contains($0) }
    }

    private func configureInitialState() {
        WidgetCenter.shared.reloadAllTimelines()
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        let demoMode = Self.shouldInstallDemoFixtures(arguments: args, environment: env)
        isDemoFixtureMode = demoMode

        if demoMode {
            state.installDemoFixtures()
            if let savedBYOK = persistence.load() {
                state.settings.apiProvider.configuration = savedBYOK
            }
            applyLaunchFlags(args)
            return
        }

        // Real workspace initialization — zero mock data
        let snapshot = workspaceStore.load()
        if let savedBYOK = persistence.load() {
            state.settings.apiProvider.configuration = savedBYOK
        }
        if let savedAppearance = ClaudeAppearance(rawValue: snapshot.appearanceRaw) {
            state.appearance = savedAppearance
        }
        if args.contains("--light") { state.appearance = .light }
        state.settings.hapticsEnabled = snapshot.hapticsEnabled
        state.settings.profile = ClaudeProfile(
            initials: Self.computeInitials(fullName: snapshot.fullName, fallback: snapshot.initials),
            fullName: snapshot.fullName,
            nickname: snapshot.nickname,
            instructions: snapshot.instructions)
        let shortVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildVer = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        state.settings.versionLabel = "\(shortVer) (\(buildVer))"
        refreshAccountSummary()

        state.settings.capabilities = ClaudeCapabilitiesState(
            values: Dictionary(
                uniqueKeysWithValues: ClaudeCapability.allCases.map { key in
                    (key, ClaudeCapabilityValue(isEnabled: key != .sensitiveMemory, isEditable: true))
                }))

        state.conversations = snapshot.conversations.sorted { $0.updatedAt > $1.updatedAt }
        persistedProjects = snapshot.projects
        state.projects.projects = snapshot.projects.map { $0.toClaudeProject() }
        state.activeProjectID = snapshot.activeProjectID
        persistedArtifacts = snapshot.artifacts
        state.artifacts.items = snapshot.artifacts.map { $0.toClaudeArtifact() }
        persistedMemoryNotes = snapshot.memoryNotes
        rebuildMemoryFilesState()
    }

    private func applyLaunchFlags(_ args: [String]) {
        if args.contains("--video") {
            state.media.draft = [
                .init(
                    id: "garden-video", fileName: "Garden-Motion.mp4",
                    accessibilityDescription: "Garden motion video", aspectRatio: 240.0 / 426, kind: .video)
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

    private static func computeInitials(fullName: String, fallback: String = "AI") -> String {
        let parts = fullName.split(whereSeparator: \.isWhitespace)
        if parts.count >= 2, let f = parts.first?.first, let l = parts.last?.first {
            return String([f, l]).uppercased()
        }
        if let first = parts.first?.prefix(2), !first.isEmpty {
            return String(first).uppercased()
        }
        let cleaned = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "AI" : cleaned
    }

    private func refreshAccountSummary() {
        guard !isDemoFixtureMode else { return }
        let byok = state.settings.apiProvider.configuration
        if byok.isEnabled, byok.isReady {
            state.settings.account = ClaudeAccountSummary(
                email: byok.shortModelLabel, accountLabel: byok.displayName, planLabel: "BYOK")
        } else {
            state.settings.account = ClaudeAccountSummary(
                email: "", accountLabel: "On-device workspace", planLabel: "Local")
        }
    }

    private func rebuildMemoryFilesState() {
        guard !isDemoFixtureMode else { return }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        let files = persistedMemoryNotes.map { note in
            ClaudeMemoryFile(
                id: note.id, title: note.title, updatedLabel: fmt.string(from: note.updatedAt),
                summary: String(note.markdown.prefix(80)), markdown: note.markdown)
        }
        state.settings.memoryFiles = ClaudeMemoryFilesState(
            groups: files.isEmpty ? [] : [.init(id: "notes", title: "Saved Notes", files: files)])
    }

    private func persistWorkspace() {
        guard !isDemoFixtureMode else { return }
        let snap = ClaudeWorkspaceSnapshot(
            fullName: state.settings.profile.fullName,
            nickname: state.settings.profile.nickname,
            initials: state.settings.profile.initials,
            instructions: state.settings.profile.instructions,
            appearanceRaw: state.appearance.rawValue,
            hapticsEnabled: state.settings.hapticsEnabled,
            activeProjectID: state.activeProjectID,
            conversations: state.conversations,
            projects: persistedProjects,
            artifacts: persistedArtifacts,
            memoryNotes: persistedMemoryNotes)
        workspaceStore.save(snap)
    }

    private func saveActiveConversationIfNeeded() {
        guard !isDemoFixtureMode, !state.temporary, !state.messages.isEmpty else { return }
        let persistedMessages = state.messages.map { ClaudePersistedMessage(from: $0) }
        if let activeID = state.activeConversationID,
            let index = state.conversations.firstIndex(where: { $0.id == activeID })
        {
            state.conversations[index].messages = persistedMessages
            state.conversations[index].updatedAt = Date()
            state.conversations[index].projectID = state.activeProjectID
        } else {
            let firstUser = state.messages.first(where: { $0.role == .user })?.text ?? "Conversation"
            let newConv = ClaudeConversationSummary(
                id: state.activeConversationID ?? UUID(),
                title: ClaudeConversationSummary.makeTitle(from: firstUser),
                updatedAt: Date(),
                pinned: false,
                projectID: state.activeProjectID,
                messages: persistedMessages)
            state.activeConversationID = newConv.id
            state.conversations.insert(newConv, at: 0)
        }
        state.conversations.sort { $0.updatedAt > $1.updatedAt }
        persistWorkspace()
    }

    private func triggerLightHaptic() {
        guard state.settings.hapticsEnabled, !isDemoFixtureMode else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func handle(_ action: ClaudeAction) {
        if action == .stop || action == .newSession {
            responseTask?.cancel()
            responseTask = nil
            speechController.stop()
            dictationController.stop()
        }

        // Handle `/clear` slash command before adding a chat message
        if case .send(let rawText) = action, ClaudeSlashCommand.parse(rawText) == .clear {
            state.draft = ""
            handle(.newSession)
            return
        }

        // Capture pending rich attachment payloads before `state.reduce(.send)` clears them
        let pendingPayloads = state.attachmentPayloads
        if case .attachPayload(let payload) = action, payload.kind == .image,
            let data = Data(base64Encoded: payload.base64Data), let img = UIImage(data: data)
        {
            attachedImages[payload.id] = img
        }

        state.reduce(action)

        switch action {
        case .send:
            if let lastUser = state.messages.last(where: { $0.role == .user }), !pendingPayloads.isEmpty {
                messageAttachmentPayloads[lastUser.id] = pendingPayloads
            }
            triggerLightHaptic()
            startAssistantTurn()
        case .retry:
            triggerLightHaptic()
            startAssistantTurn()
        case .startDictation:
            guard !isDemoFixtureMode else { return }
            dictationController.start(
                onLevel: { level in state.dictationLevels.append(level) },
                onTranscript: { text in state.transcript = text },
                onError: { _ in state.reduce(.cancelDictation) })
        case .stopDictation, .cancelDictation, .commitDictation:
            dictationController.stop()
        case .selectConversation(let id):
            responseTask?.cancel()
            responseTask = nil
            if let conv = state.conversations.first(where: { $0.id == id }) {
                state.openConversation(conv)
            }
        case .deleteConversation(let id):
            state.conversations.removeAll { $0.id == id }
            if state.activeConversationID == id {
                state.reduce(.newSession)
            }
            persistWorkspace()
        case .togglePinConversation(let id):
            if let idx = state.conversations.firstIndex(where: { $0.id == id }) {
                state.conversations[idx].pinned.toggle()
                persistWorkspace()
            }
        case .renameConversation(let id, let newTitle):
            if let idx = state.conversations.firstIndex(where: { $0.id == id }) {
                state.conversations[idx].title = newTitle
                persistWorkspace()
            }
        case .selectActiveProject:
            persistWorkspace()
        case .settings(.apiProvider(let byokAction)):
            persistence.save(state.settings.apiProvider.configuration)
            refreshAccountSummary()
            handleBYOKAction(byokAction)
        case .settings(.setAppearance), .settings(.setHaptics):
            persistWorkspace()
        case .settings(.capability(.requestEnabled(let capability, let enabled))):
            var current = state.settings.capabilities[capability]
            if current.isEditable {
                current.isEnabled = enabled
                state.settings.capabilities.values[capability] = current
            }
        case .settings(.memory(.submitInstruction(let fileID, let text))):
            handleMemoryInstruction(fileID: fileID, text: text)
        case .settings(.memory(.confirmDelete)):
            if let request = state.settings.memoryFiles.pendingDeletion {
                persistedMemoryNotes.removeAll { $0.id == request.fileID }
                state.settings.memoryFiles.acknowledgeDeletion(requestID: request.id)
                persistWorkspace()
            }
        case .settings(.submitProfile):
            if let submission = state.settings.pendingProfile {
                var updated = submission.profile
                updated.initials = Self.computeInitials(fullName: updated.fullName, fallback: updated.initials)
                state.settings.acknowledgeProfile(requestID: submission.id, profile: updated)
                persistWorkspace()
            }
        case .settings(.requestLogOut):
            state.reduce(.settings(.apiProvider(.clearCredentials)))
            persistence.save(state.settings.apiProvider.configuration)
            refreshAccountSummary()
        case .settings(.requestDeleteAccount):
            guard !isDemoFixtureMode else { return }
            workspaceStore.clearAll()
            state.conversations = []
            persistedProjects = []
            persistedArtifacts = []
            persistedMemoryNotes = []
            state.projects.projects = []
            state.artifacts.items = []
            rebuildMemoryFilesState()
            state.reduce(.newSession)
        case .projects(.create(let draft)):
            let cleanedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedName.isEmpty else { return }
            let persisted = ClaudePersistedProject(
                name: cleanedName,
                goal: draft.goal.trimmingCharacters(in: .whitespacesAndNewlines),
                icon: draft.icon,
                pinned: false,
                contextItems: draft.context)
            persistedProjects.insert(persisted, at: 0)
            state.projects.acknowledgeCreated(persisted.toClaudeProject())
            state.activeProjectID = persisted.id
            persistWorkspace()
        case .projects(.openProject(let id)):
            state.reduce(.newSession)
            state.activeProjectID = id
            persistWorkspace()
        case .artifacts(.togglePin(let id)):
            state.artifacts.togglePinned(id: id)
            if let idx = persistedArtifacts.firstIndex(where: { $0.id == id }) {
                persistedArtifacts[idx].pinned.toggle()
                persistWorkspace()
            }
        case .artifacts(.delete(let id)):
            state.artifacts.remove(id: id)
            persistedArtifacts.removeAll { $0.id == id }
            persistWorkspace()
        case .openDispatch, .dispatch(.reload):
            guard let requestID = state.dispatch.loadID else { return }
            dispatchTask?.cancel()
            if isDemoFixtureMode {
                dispatchTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    state.dispatch.finishLoading(DemoHostResponses.dispatchWelcome, requestID: requestID)
                }
            } else {
                state.dispatch.finishLoading([], requestID: requestID)
            }
        case .devices(.openManage):
            guard let requestID = state.devices.accountRequestID else { return }
            accountTask?.cancel()
            if isDemoFixtureMode {
                accountTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    state.devices.finishAccountLoad(DemoHostResponses.accountProfile, requestID: requestID)
                }
            } else {
                let localProfile = DeviceAccountProfile(
                    initials: state.settings.profile.initials,
                    fullName: state.settings.profile.fullName,
                    nickname: state.settings.profile.nickname,
                    work: "",
                    workChoices: ["Software Engineering", "Design", "Research", "Product", "Education", "Other"],
                    organizationID: "local-device",
                    deletionUnavailableReason: "")
                state.devices.finishAccountLoad(localProfile, requestID: requestID)
            }
        case .devices(.closeManage):
            accountTask?.cancel()
            accountTask = nil
        case .code(.copyRemoteCommand):
            UIPasteboard.general.string = "claude rc"
        case .devices(.copyOrganizationID):
            UIPasteboard.general.string = state.devices.profile.organizationID
        case .markdown(_, .copyCode(let text)), .artifacts(.markdown(.copyCode(let text))):
            UIPasteboard.general.string = text
            triggerLightHaptic()
        case .markdown(_, .openLink(let url)), .artifacts(.markdown(.openLink(let url))):
            UIApplication.shared.open(url)
        case .markdown(_, .saveArtifact(let language, let content)),
            .artifacts(.markdown(.saveArtifact(let language, let content))):
            saveArtifactFromCode(language: language, content: content)
            triggerLightHaptic()
        case .media(.copyFileName(let item)):
            UIPasteboard.general.string = item.fileName
        case .copy(let id):
            if let message = state.messages.first(where: { $0.id == id }) {
                UIPasteboard.general.string = message.text
                triggerLightHaptic()
            }
        case .readAloud(let id):
            if let message = state.messages.first(where: { $0.id == id }) {
                speechController.toggleSpeak(id: id, text: message.text)
            }
        default:
            break
        }
    }

    private func handleBYOKAction(_ byokAction: ClaudeBYOKAction) {
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
                    refreshAccountSummary()
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
    }

    private func handleMemoryInstruction(fileID: String?, text: String) {
        if isDemoFixtureMode {
            if ProcessInfo.processInfo.arguments.contains("--memory-clear-after-submit") {
                state.reduce(.settings(.memory(.replaceDraft(""))))
            }
            return
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if let fileID, let idx = persistedMemoryNotes.firstIndex(where: { $0.id == fileID }) {
            persistedMemoryNotes[idx].markdown += "\n\n" + cleaned
            persistedMemoryNotes[idx].updatedAt = Date()
        } else {
            let title = ClaudeConversationSummary.makeTitle(from: cleaned)
            persistedMemoryNotes.insert(
                ClaudePersistedMemoryNote(title: title, markdown: cleaned), at: 0)
        }
        state.reduce(.settings(.memory(.replaceDraft(""))))
        rebuildMemoryFilesState()
        persistWorkspace()
    }

    private func saveArtifactFromCode(language: String?, content: String) {
        guard !isDemoFixtureMode else { return }
        let lang = (language ?? "html").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveLang = lang.isEmpty ? "text" : lang
        let isHTML = ClaudeHTMLPreviewSupport.isPreviewableCode(language: effectiveLang, content: content)
        let title =
            isHTML
            ? ClaudeHTMLPreviewSupport.extractTitle(from: content, language: effectiveLang)
            : "\(effectiveLang.uppercased()) Snippet"
        let persisted = ClaudePersistedArtifact(
            title: title, language: effectiveLang, content: content, isHTML: isHTML)
        persistedArtifacts.insert(persisted, at: 0)
        state.artifacts.items.insert(persisted.toClaudeArtifact(), at: 0)
        persistWorkspace()
    }

    private func startAssistantTurn() {
        guard let responseID = state.responseID else { return }
        responseTask?.cancel()

        // Preserve fixture reply ONLY when launched in XCTest / demo fixture mode without BYOK enabled
        let byok = state.settings.apiProvider.configuration
        if isDemoFixtureMode && !byok.isEnabled {
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
            return
        }

        let history = state.messages
        let forceWebSearch = state.webSearchEnabled
        let systemPrompt = buildWorkspaceSystemPrompt(byok: byok)
        let payloadsSnapshot = messageAttachmentPayloads

        responseTask = Task { @MainActor in
            await runRealAssistantTurn(
                byok: byok,
                messages: history,
                attachmentPayloadsByMessage: payloadsSnapshot,
                forceWebSearch: forceWebSearch,
                workspaceSystemPrompt: systemPrompt,
                responseID: responseID)
            saveActiveConversationIfNeeded()
        }
    }

    private func buildWorkspaceSystemPrompt(byok: ClaudeBYOKConfiguration) -> String {
        var sections: [String] = []
        let base = byok.trimmedSystemPrompt
        if !base.isEmpty { sections.append(base) }
        let profileInst = state.settings.profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !profileInst.isEmpty {
            sections.append("User profile instructions:\n\(profileInst)")
        }
        if let activeID = state.activeProjectID,
            let project = persistedProjects.first(where: { $0.id == activeID })
        {
            var projLines = ["Active project: \(project.name)"]
            if !project.goal.isEmpty { projLines.append("Project goal: \(project.goal)") }
            if !project.contextItems.isEmpty {
                projLines.append("Project context:\n" + project.contextItems.joined(separator: "\n"))
            }
            sections.append(projLines.joined(separator: "\n"))
        }
        if !persistedMemoryNotes.isEmpty {
            let notes = persistedMemoryNotes.prefix(8).map { "- \($0.title): \($0.markdown)" }
                .joined(separator: "\n")
            sections.append("Saved user memory notes:\n\(notes)")
        }
        sections.append(
            "Current device date/time: \(ClaudeAgentTools.currentDateTimeSummary()). "
                + "When creating HTML pages, dashboards, games, SVG graphics, or interactive demos, "
                + "always output a complete self-contained single-file HTML5 document inside a ```html code block "
                + "so the iOS app renders a live interactive WebView preview directly in the chat.")
        return sections.joined(separator: "\n\n")
    }

    @MainActor
    private func runRealAssistantTurn(
        byok: ClaudeBYOKConfiguration,
        messages: [ChatMessage],
        attachmentPayloadsByMessage: [UUID: [ClaudeAttachmentPayload]],
        forceWebSearch: Bool,
        workspaceSystemPrompt: String,
        responseID: UUID
    ) async {
        let latestRaw = messages.last(where: { $0.role == .user })?.text ?? ""
        let slash = ClaudeSlashCommand.parse(latestRaw)

        // 1. Direct calculator command works instantly with or without BYOK
        if case .calculate(let expr) = slash {
            switch ClaudeAgentTools.evaluateMath(expr) {
            case .success(let val):
                let formatted = val.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", val) : "\(val)"
                state.appendResponse("**Result:** `\(expr)` = **\(formatted)**", responseID: responseID)
            case .failure(let err):
                state.appendResponse(
                    "Could not evaluate `\(expr)`: \(err.localizedDescription)", responseID: responseID)
            }
            state.finishResponse(responseID: responseID)
            return
        }

        // 2. Keyless / Offline mode when BYOK is disabled or incomplete
        guard byok.isEnabled, byok.isReady else {
            await handleWithoutBYOK(slash: slash, latestRaw: latestRaw, responseID: responseID)
            return
        }

        // 3. Prepare transformed messages & optional DuckDuckGo web context
        var preparedMessages = messages
        var extraContextBlocks: [String] = []

        if case .htmlApp(let appPrompt) = slash, let lastIdx = preparedMessages.indices.last {
            preparedMessages[lastIdx].text =
                "Build a complete, polished, mobile-friendly, interactive single-file HTML5 + CSS + JavaScript "
                + "application inside a single ```html code block for the following request:\n\n\(appPrompt)"
        }

        if case .readURL(let urlString, let question) = slash {
            state.setStreamingStatus("Reading \(urlString)…", responseID: responseID)
            do {
                let page = try await ClaudeDuckDuckGoSearch.fetchWebpageExcerpt(urlString: urlString)
                state.setResponseSources(
                    [.init(title: page.title, url: urlString, snippet: String(page.content.prefix(180)))],
                    responseID: responseID)
                extraContextBlocks.append(
                    "Webpage content from \(urlString) (Title: \(page.title)):\n\n\(page.content)")
                if let lastIdx = preparedMessages.indices.last {
                    preparedMessages[lastIdx].text =
                        question.isEmpty
                        ? "Summarize and highlight the key points from \(urlString)."
                        : question
                }
            } catch {
                extraContextBlocks.append(
                    "Failed to fetch \(urlString): \(error.localizedDescription). Let the user know.")
            }
        }

        let explicitSearchQuery: String? = {
            if case .search(let q) = slash { return q }
            return nil
        }()
        let shouldSearch: Bool = {
            if explicitSearchQuery != nil { return true }
            if case .readURL = slash { return false }
            if case .htmlApp = slash { return forceWebSearch }
            if byok.webSearchMode == .off && !forceWebSearch { return false }
            if forceWebSearch || byok.webSearchMode == .always { return true }
            return ClaudeDuckDuckGoSearch.shouldAutoSearch(prompt: latestRaw)
        }()

        if shouldSearch {
            let query = explicitSearchQuery ?? ClaudeDuckDuckGoSearch.optimizedSearchQuery(from: latestRaw)
            if !query.isEmpty {
                state.setStreamingStatus("Searching DuckDuckGo for “\(query)”…", responseID: responseID)
                if let results = try? await ClaudeDuckDuckGoSearch.search(query: query, maxResults: 6),
                    !results.isEmpty
                {
                    state.setResponseSources(results, responseID: responseID)
                    let promptBlock = ClaudeDuckDuckGoSearch.formatContextPrompt(query: query, results: results)
                    extraContextBlocks.append(promptBlock)
                    if let lastIdx = preparedMessages.indices.last, explicitSearchQuery != nil {
                        preparedMessages[lastIdx].text = query
                    }
                }
            }
        }

        state.setStreamingStatus("Generating response…", responseID: responseID)
        let fullSystemPrompt = ([workspaceSystemPrompt] + extraContextBlocks).filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        do {
            try await OpenAICompatibleClient.complete(
                configuration: byok,
                messages: preparedMessages,
                attachmentPayloadsByMessage: attachmentPayloadsByMessage,
                systemPrompt: fullSystemPrompt,
                onStatus: { status in
                    await MainActor.run { state.setStreamingStatus(status, responseID: responseID) }
                },
                onSources: { newSources in
                    await MainActor.run { state.setResponseSources(newSources, responseID: responseID) }
                },
                onChunk: { chunk in
                    await MainActor.run {
                        state.setStreamingStatus(nil, responseID: responseID)
                        state.appendResponse(chunk, responseID: responseID)
                    }
                })
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

    @MainActor
    private func handleWithoutBYOK(slash: ClaudeSlashCommand?, latestRaw: String, responseID: UUID) async {
        if case .search(let query) = slash {
            state.setStreamingStatus("Searching DuckDuckGo for “\(query)”…", responseID: responseID)
            do {
                let results = try await ClaudeDuckDuckGoSearch.search(query: query, maxResults: 6)
                if results.isEmpty {
                    state.appendResponse("No DuckDuckGo results found for **\(query)**.", responseID: responseID)
                } else {
                    state.setResponseSources(results, responseID: responseID)
                    var md = "### DuckDuckGo Results for “\(query)”\n\n"
                    for (idx, r) in results.enumerated() {
                        md += "\(idx + 1). **[\(r.title)](\(r.url))** — *\(r.domain)*\n"
                        if !r.snippet.isEmpty { md += "   \(r.snippet)\n" }
                        md += "\n"
                    }
                    md +=
                        "_Tip: Enable an API key in **Settings → API provider** for AI synthesis over search results._"
                    state.appendResponse(md, responseID: responseID)
                }
            } catch {
                state.appendResponse("DuckDuckGo search error: \(error.localizedDescription)", responseID: responseID)
            }
            state.finishResponse(responseID: responseID)
            return
        }

        if case .readURL(let urlString, _) = slash {
            state.setStreamingStatus("Reading \(urlString)…", responseID: responseID)
            do {
                let page = try await ClaudeDuckDuckGoSearch.fetchWebpageExcerpt(
                    urlString: urlString, maxCharacters: 4000)
                state.setResponseSources(
                    [.init(title: page.title, url: urlString, snippet: String(page.content.prefix(160)))],
                    responseID: responseID)
                let md = "### \(page.title)\n\nSource: [\(urlString)](\(urlString))\n\n\(page.content)"
                state.appendResponse(md, responseID: responseID)
            } catch {
                state.appendResponse("Could not read webpage: \(error.localizedDescription)", responseID: responseID)
            }
            state.finishResponse(responseID: responseID)
            return
        }

        if case .htmlApp(let prompt) = slash {
            let safeTitle = prompt.replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let starterHTML = """
                ### Live HTML Preview

                Configure an API key in **Settings → API provider** to generate custom AI apps. Here is an interactive HTML5 canvas preview running live in chat:

                ```html
                <!doctype html>
                <html lang="en">
                <head>
                  <meta charset="utf-8">
                  <title>\(safeTitle)</title>
                  <style>
                    body { font-family: -apple-system, sans-serif; margin: 0; padding: 20px; background: #141418; color: #f3f3f5; }
                    .card { background: #1f2028; border: 1px solid #323442; border-radius: 18px; padding: 18px; }
                    button { background: #cc5c3b; color: #fff; border: 0; border-radius: 999px; padding: 10px 18px; font-size: 15px; font-weight: 600; cursor: pointer; }
                    .count { font-size: 32px; font-weight: 700; margin: 12px 0; color: #ff8c69; }
                  </style>
                </head>
                <body>
                  <div class="card">
                    <div style="font-size:13px;opacity:0.7;">Interactive HTML5 Sandbox</div>
                    <h2 style="margin:6px 0 4px;">\(safeTitle)</h2>
                    <div class="count" id="counter">0</div>
                    <button onclick="document.getElementById('counter').textContent = Number(document.getElementById('counter').textContent) + 1">Tap Counter +1</button>
                  </div>
                </body>
                </html>
                ```
                """
            state.appendResponse(starterHTML, responseID: responseID)
            state.finishResponse(responseID: responseID)
            return
        }

        if state.webSearchEnabled, !latestRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await handleWithoutBYOK(slash: .search(latestRaw), latestRaw: latestRaw, responseID: responseID)
            return
        }

        let setupGuide = """
            ### Configure an AI Provider to Start Chatting

            No mock responses are active. Connect any **OpenAI-compatible** endpoint in **Settings → API provider**:
            - **OpenAI**, **OpenRouter**, **Google Gemini**, **Groq**, **DeepSeek**, **Mistral**, **Together AI**, or local **Ollama / LM Studio**.

            **Available right now (even without an API key):**
            - Tap the **🌐 Globe** button or type `/search <query>` for live **DuckDuckGo Web Search**
            - Type `/read <https://url>` to extract readable text from any webpage
            - Type `/calc sqrt(144) + 2^10` for instant math evaluation
            - Type `/html <title>` or paste any ```` ```html ```` code block to test the **Live HTML Preview**
            """
        state.appendResponse(setupGuide, responseID: responseID)
        state.finishResponse(responseID: responseID)
    }
}

@MainActor
final class SpeechSynthesizerController: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var activeMessageID: UUID?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggleSpeak(id: UUID, text: String) {
        if synthesizer.isSpeaking, activeMessageID == id {
            stop()
            return
        }
        stop()
        let plain = Self.stripMarkdown(text)
        guard !plain.isEmpty else { return }
        activeMessageID = id
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: plain)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(plain)
        if let lang = recognizer.dominantLanguage?.rawValue {
            utterance.voice = AVSpeechSynthesisVoice(language: lang)
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        activeMessageID = nil
    }

    private static func stripMarkdown(_ source: String) -> String {
        source
            .replacingOccurrences(of: "```[\\s\\S]*?```", with: " Code block omitted. ", options: .regularExpression)
            .replacingOccurrences(of: "[#*`_>~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class LiveSpeechDictationController {
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func start(
        onLevel: @escaping @MainActor (Double) -> Void,
        onTranscript: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        stop()
        SFSpeechRecognizer.requestAuthorization { authStatus in
            Task { @MainActor in
                guard authStatus == .authorized else {
                    onError("Speech recognition permission not granted.")
                    return
                }
                let granted: Bool
                if #available(iOS 17.0, *) {
                    granted = await AVAudioApplication.requestRecordPermission()
                } else {
                    granted = true
                }
                guard granted else {
                    onError("Microphone permission not granted.")
                    return
                }
                self.beginSession(onLevel: onLevel, onTranscript: onTranscript, onError: onError)
            }
        }
    }

    private func beginSession(
        onLevel: @escaping @MainActor (Double) -> Void,
        onTranscript: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(),
            recognizer.isAvailable
        else {
            onError("Speech recognizer unavailable.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
                let rms = Self.computeNormalizedLevel(buffer: buffer)
                Task { @MainActor in onLevel(rms) }
            }

            engine.prepare()
            try engine.start()
            self.audioEngine = engine
            self.recognitionRequest = request

            self.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                Task { @MainActor in
                    if let text = result?.bestTranscription.formattedString {
                        onTranscript(text)
                    }
                    if error != nil && result?.isFinal != true {
                        self.stop()
                    }
                }
            }
        } catch {
            stop()
            onError(error.localizedDescription)
        }
    }

    func stop() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
    }

    nonisolated private static func computeNormalizedLevel(buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let s = channelData[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 0.000_01))
        return Double(min(1, max(0, (db + 50) / 45)))
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
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        saveAPIKey("")
    }

    private func resolvedDefaults() -> UserDefaults? {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    private func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return "" }
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
        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }
}

enum OpenAICompatibleError: LocalizedError {
    case invalidEndpoint
    case missingModel
    case httpStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Invalid HTTP or HTTPS base URL."
        case .missingModel: "Enter a model identifier first."
        case .httpStatus(let code, let detail):
            detail.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(detail)"
        case .emptyResponse: "Endpoint returned an empty response."
        }
    }
}

enum OpenAICompatibleClient {
    static func fetchModels(configuration: ClaudeBYOKConfiguration) async throws -> [String] {
        guard let url = configuration.resolvedModelsURL else { throw OpenAICompatibleError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        applyHeaders(to: &request, configuration: configuration)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response: response, data: data)
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let dict = root as? [String: Any], let items = dict["data"] as? [[String: Any]] {
            return items.compactMap { $0["id"] as? String }.sorted()
        }
        if let items = root as? [[String: Any]] {
            return items.compactMap { $0["id"] as? String }.sorted()
        }
        return []
    }

    static func testConnection(configuration: ClaudeBYOKConfiguration) async throws -> String {
        guard let chatURL = configuration.resolvedChatCompletionsURL else {
            throw OpenAICompatibleError.invalidEndpoint
        }
        let model = configuration.trimmedModelID
        guard !model.isEmpty else { throw OpenAICompatibleError.missingModel }
        if let models = try? await fetchModels(configuration: configuration), !models.isEmpty {
            return "Connected · \(models.count) models available"
        }
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        applyHeaders(to: &request, configuration: configuration)
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 4,
            "stream": false,
            "messages": [["role": "user", "content": "ping"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response: response, data: data)
        return "Connected to \(configuration.displayName) (\(configuration.shortModelLabel))"
    }

    static func complete(
        configuration: ClaudeBYOKConfiguration,
        messages: [ChatMessage],
        attachmentPayloadsByMessage: [UUID: [ClaudeAttachmentPayload]],
        systemPrompt: String,
        onStatus: @escaping @Sendable (String) async -> Void,
        onSources: @escaping @Sendable ([ClaudeWebSearchResult]) async -> Void,
        onChunk: @escaping @Sendable (String) async -> Void
    ) async throws {
        guard let url = configuration.resolvedChatCompletionsURL else { throw OpenAICompatibleError.invalidEndpoint }
        let model = configuration.trimmedModelID
        guard !model.isEmpty else { throw OpenAICompatibleError.missingModel }

        var wireMessages: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            wireMessages.append(["role": "system", "content": systemPrompt])
        }
        for message in messages {
            let role = message.role == .user ? "user" : "assistant"
            let payloads = attachmentPayloadsByMessage[message.id] ?? []
            wireMessages.append(buildWireMessage(role: role, text: message.text, payloads: payloads))
        }

        var collectedSources: [ClaudeWebSearchResult] = []
        let promptText = messages.last(where: { $0.role == .user })?.text ?? ""
        let wantsToolProbe =
            configuration.enableAgentTools
            && (!configuration.streamResponses || Self.promptMayBenefitFromTools(promptText))
        if wantsToolProbe {
            switch try await runAgentToolRoundsIfSupported(
                url: url,
                model: model,
                configuration: configuration,
                initialMessages: wireMessages,
                collectedSources: &collectedSources,
                onStatus: onStatus,
                onSources: onSources)
            {
            case .updatedMessages(let updated):
                wireMessages = updated
            case .directAnswer(let content):
                await onChunk(content)
                return
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        applyHeaders(to: &request, configuration: configuration)
        let body: [String: Any] = [
            "model": model,
            "temperature": configuration.temperature,
            "stream": configuration.streamResponses,
            "messages": wireMessages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        if configuration.streamResponses {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                var errorBytes = Data()
                for try await byte in bytes {
                    errorBytes.append(byte)
                    if errorBytes.count >= 4096 { break }
                }
                throw OpenAICompatibleError.httpStatus(http.statusCode, extractErrorMessage(from: errorBytes))
            }
            var receivedAny = false
            for try await rawLine in bytes.lines {
                try Task.checkCancellation()
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("data:") else { continue }
                let dataPart = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if dataPart == "[DONE]" { break }
                guard let jsonData = dataPart.data(using: .utf8),
                    let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                else { continue }
                if let err = (obj["error"] as? [String: Any])?["message"] as? String {
                    throw OpenAICompatibleError.httpStatus(500, err)
                }
                if let delta = extractContent(from: obj), !delta.isEmpty {
                    receivedAny = true
                    await onChunk(delta)
                }
            }
            if !receivedAny { throw OpenAICompatibleError.emptyResponse }
        } else {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTP(response: response, data: data)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let content = extractContent(from: obj), !content.isEmpty
            else {
                throw OpenAICompatibleError.emptyResponse
            }
            await onChunk(content)
        }
    }

    private static func buildWireMessage(
        role: String, text: String, payloads: [ClaudeAttachmentPayload]
    ) -> [String: Any] {
        guard role == "user", !payloads.isEmpty else {
            return ["role": role, "content": text]
        }
        let textFiles = payloads.filter { $0.kind == .textFile && !$0.textContent.isEmpty }
        let images = payloads.filter { $0.kind == .image && $0.dataURL != nil }
        var combinedText = text
        for file in textFiles {
            combinedText += "\n\n--- File: \(file.fileName) ---\n\(file.textContent)"
        }
        guard !images.isEmpty else {
            return ["role": role, "content": combinedText]
        }
        var parts: [[String: Any]] = [
            ["type": "text", "text": combinedText.isEmpty ? "Analyze the attached image(s)." : combinedText]
        ]
        for img in images {
            if let dataURL = img.dataURL {
                parts.append(["type": "image_url", "image_url": ["url": dataURL]])
            }
        }
        return ["role": role, "content": parts]
    }

    private enum ToolProbeOutcome {
        case updatedMessages([[String: Any]])
        case directAnswer(String)
    }

    private static func promptMayBenefitFromTools(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("http://") || lower.contains("https://") { return true }
        let triggers = [
            "calculate", "calcular", "calcule", "quanto é", "sqrt(", "current time", "what time",
            "que horas", "data de hoje", "today's date", "search the web", "pesquise na web"
        ]
        return triggers.contains { lower.contains($0) }
    }

    private static func runAgentToolRoundsIfSupported(
        url: URL,
        model: String,
        configuration: ClaudeBYOKConfiguration,
        initialMessages: [[String: Any]],
        collectedSources: inout [ClaudeWebSearchResult],
        onStatus: @escaping @Sendable (String) async -> Void,
        onSources: @escaping @Sendable ([ClaudeWebSearchResult]) async -> Void
    ) async throws -> ToolProbeOutcome {
        let includeSearchTool = configuration.webSearchMode != .off
        let tools = ClaudeAgentTools.openAIToolDefinitions(includeWebSearch: includeSearchTool)
        var current = initialMessages
        var executedAnyTool = false

        for _ in 0..<2 {
            try Task.checkCancellation()
            var probe = URLRequest(url: url)
            probe.httpMethod = "POST"
            probe.timeoutInterval = 45
            applyHeaders(to: &probe, configuration: configuration)
            let body: [String: Any] = [
                "model": model,
                "temperature": configuration.temperature,
                "stream": false,
                "tools": tools,
                "messages": current
            ]
            probe.httpBody = try JSONSerialization.data(withJSONObject: body)
            guard let (data, response) = try? await URLSession.shared.data(for: probe),
                let http = response as? HTTPURLResponse,
                (200...299).contains(http.statusCode),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choice = (root["choices"] as? [[String: Any]])?.first,
                let message = choice["message"] as? [String: Any]
            else {
                return .updatedMessages(executedAnyTool ? current : initialMessages)
            }

            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                executedAnyTool = true
                current.append(message)
                for call in toolCalls {
                    guard let callID = call["id"] as? String,
                        let fn = call["function"] as? [String: Any],
                        let name = fn["name"] as? String
                    else { continue }
                    let rawArgs = (fn["arguments"] as? String) ?? "{}"
                    let argsDict =
                        (rawArgs.data(using: .utf8).flatMap {
                            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                        }) ?? [:]
                    let toolOutput = await executeToolCall(
                        name: name, args: argsDict, collectedSources: &collectedSources,
                        onStatus: onStatus, onSources: onSources)
                    current.append([
                        "role": "tool",
                        "tool_call_id": callID,
                        "content": toolOutput
                    ])
                }
                continue
            }

            if let direct = extractContent(from: root), !direct.isEmpty {
                return .directAnswer(direct)
            }
            return .updatedMessages(executedAnyTool ? current : initialMessages)
        }
        return .updatedMessages(current)
    }

    private static func executeToolCall(
        name: String,
        args: [String: Any],
        collectedSources: inout [ClaudeWebSearchResult],
        onStatus: @escaping @Sendable (String) async -> Void,
        onSources: @escaping @Sendable ([ClaudeWebSearchResult]) async -> Void
    ) async -> String {
        switch name {
        case "web_search":
            let query = (args["query"] as? String) ?? ""
            guard !query.isEmpty else { return "Missing query parameter." }
            await onStatus("Searching DuckDuckGo for “\(query)”…")
            if let results = try? await ClaudeDuckDuckGoSearch.search(query: query, maxResults: 5), !results.isEmpty {
                for r in results where !collectedSources.contains(where: { $0.url == r.url }) {
                    collectedSources.append(r)
                }
                await onSources(collectedSources)
                return ClaudeDuckDuckGoSearch.formatContextPrompt(query: query, results: results)
            }
            return "No results found on DuckDuckGo for '\(query)'."
        case "read_webpage":
            let urlStr = (args["url"] as? String) ?? ""
            await onStatus("Reading \(urlStr)…")
            if let page = try? await ClaudeDuckDuckGoSearch.fetchWebpageExcerpt(urlString: urlStr) {
                return "Title: \(page.title)\nURL: \(urlStr)\n\n\(page.content)"
            }
            return "Could not fetch or parse \(urlStr)."
        case "calculator":
            let expr = (args["expression"] as? String) ?? ""
            await onStatus("Calculating \(expr)…")
            switch ClaudeAgentTools.evaluateMath(expr) {
            case .success(let v): return "\(v)"
            case .failure(let e): return "Error: \(e.localizedDescription)"
            }
        case "current_datetime":
            return ClaudeAgentTools.currentDateTimeSummary()
        default:
            return "Unsupported tool: \(name)"
        }
    }

    private static func applyHeaders(to request: inout URLRequest, configuration: ClaudeBYOKConfiguration) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let key = configuration.trimmedAPIKey
        if !key.isEmpty {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        for header in configuration.customHeaders {
            let name = header.trimmedName
            let value = header.trimmedValue
            if !name.isEmpty, !value.isEmpty {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
    }

    private static func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        throw OpenAICompatibleError.httpStatus(http.statusCode, extractErrorMessage(from: data))
    }

    private static func extractErrorMessage(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = root["error"] as? [String: Any], let message = err["message"] as? String {
                return message
            }
            if let message = root["error"] as? String { return message }
            if let message = root["message"] as? String { return message }
        }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(raw.prefix(240))
    }

    private static func extractContent(from root: [String: Any]) -> String? {
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first else { return nil }
        for key in ["delta", "message"] {
            if let container = first[key] as? [String: Any] {
                if let text = container["content"] as? String { return text }
                if let parts = container["content"] as? [[String: Any]] {
                    let joined = parts.compactMap { $0["text"] as? String }.joined()
                    if !joined.isEmpty { return joined }
                }
            }
        }
        return first["text"] as? String
    }
}

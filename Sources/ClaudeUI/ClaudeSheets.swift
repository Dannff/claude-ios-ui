#if canImport(UIKit)
    import PhotosUI
    import SwiftUI
    import UIKit
    import UniformTypeIdentifiers

    struct SheetHeader: View {
        let title: String
        var back = false
        var trailing: String?
        var controlDiameter: CGFloat = 42
        var titleMaxWidth: CGFloat = 200
        let close: () -> Void
        var trailingAction: (() -> Void)?
        var body: some View {
            ZStack {
                Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1).frame(maxWidth: titleMaxWidth)
                HStack {
                    Button(action: close) {
                        Image(systemName: back ? "chevron.left" : "xmark").font(.system(size: 21, weight: .light))
                            .frame(width: controlDiameter, height: controlDiameter)
                    }.glassEffect(in: .circle).accessibilityLabel(back ? "Back" : "Close").accessibilityIdentifier(
                        "sheet.close.\(title)")
                    Spacer()
                    if let trailing { Button(trailing) { trailingAction?() }.font(.system(size: 16)) }
                }
            }.frame(height: 58).padding(.horizontal, 16).padding(.top, 7)
        }
    }

    struct SheetRow: View {
        let title: String
        var symbol: String?
        var detail: String?
        var value: String?
        var checked = false
        var chevron = false
        var badge: String?
        var action: () -> Void
        var body: some View {
            Button(action: action) {
                HStack(spacing: 12) {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 20, weight: .light)).frame(width: 23)
                            .foregroundStyle(Color(white: 0.72))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text(title).font(.system(size: 17))
                            if let badge {
                                Text(badge).font(.system(size: 11, weight: .semibold)).foregroundStyle(
                                    badge.contains("usage") ? Color.orange : ClaudePalette.ink
                                ).padding(.horizontal, 8).padding(.vertical, 5).background(
                                    badge.contains("usage") ? Color.orange.opacity(0.20) : .primary.opacity(0.05),
                                    in: .capsule)
                            }
                        }
                        if let detail {
                            Text(detail).font(.system(size: 13)).foregroundStyle(ClaudePalette.secondary).fixedSize(
                                horizontal: false, vertical: true)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let value {
                        Text(value).font(.system(size: 16)).foregroundStyle(ClaudePalette.secondary).lineLimit(1)
                    }
                    if checked {
                        Image(systemName: "checkmark").font(.system(size: 19, weight: .semibold)).foregroundStyle(.blue)
                    }
                    if chevron {
                        Image(systemName: "chevron.right").font(.system(size: 15)).foregroundStyle(
                            ClaudePalette.secondary)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 14).contentShape(.rect)
            }.buttonStyle(.plain)
        }
    }

    struct RowGroup<Content: View>: View {
        @ViewBuilder var content: () -> Content
        var body: some View {
            VStack(spacing: 0, content: content).background(ClaudePalette.panel, in: .rect(cornerRadius: 28))
        }
    }

    struct RowDivider: View { var body: some View { Divider().padding(.horizontal, 16) } }

    struct ClaudeModelSheet: View {
        @Binding var state: SessionState
        let action: (ClaudeAction) -> Void
        var voiceContext = false
        var close: (() -> Void)?
        private func closePicker() { if let close { close() } else { dismiss() } }
        @Environment(\.dismiss) private var dismiss
        @State private var effort = false
        var body: some View {
            VStack(spacing: 18) {
                SheetHeader(title: effort ? "Effort" : "Select model", back: effort || voiceContext) {
                    if effort { effort = false } else { closePicker() }
                }
                if effort {
                    VStack(alignment: .leading, spacing: 9) {
                        RowGroup {
                            ForEach(Effort.allCases, id: \.self) { level in
                                SheetRow(
                                    title: level.rawValue, checked: state.effort == level,
                                    badge: level == .medium ? "Recommended" : level == .max ? "4× or more usage" : nil
                                ) {
                                    action(.selectEffort(level))
                                    effort = false
                                }.accessibilityIdentifier("effort.\(level.rawValue)")
                                if level != .max { RowDivider() }
                            }
                        }
                        Text(
                            "Higher effort means more thorough responses, but takes longer and uses your limits faster."
                        ).font(.system(size: 14)).foregroundStyle(ClaudePalette.secondary).padding(.horizontal, 16)
                    }.padding(.horizontal, 16)
                } else {
                    if let activeBYOK = state.settings.apiProvider.activeComposerLabels {
                        RowGroup {
                            SheetRow(
                                title: activeBYOK.model,
                                symbol: "bolt.horizontal.circle",
                                detail: "Active BYOK endpoint: \(activeBYOK.provider)",
                                checked: true,
                                badge: "Active"
                            ) {
                                closePicker()
                                action(.settings(.open(.profile)))
                                action(.settings(.apiProvider(.open)))
                            }
                        }.padding(.horizontal, 16)
                    }
                    RowGroup {
                        ForEach(ClaudeModel.allCases, id: \.self) { model in
                            SheetRow(
                                title: voiceContext ? model.rawValue.components(separatedBy: " ")[0] : model.rawValue,
                                detail: model.detail,
                                checked: state.settings.apiProvider.activeComposerLabels == nil && state.model == model
                            ) {
                                action(.selectModel(model))
                                closePicker()
                            }.accessibilityIdentifier("model.\(model.rawValue)")
                            if model != .haiku { RowDivider() }
                        }
                    }.padding(.horizontal, 16)
                    RowGroup {
                        SheetRow(title: "Effort", value: state.effort.rawValue, chevron: true) { effort = true }
                            .accessibilityIdentifier("model.effort")
                    }.padding(.horizontal, 16)
                }
                Spacer(minLength: 0)
            }.background(ClaudePalette.background).foregroundStyle(ClaudePalette.ink)
                .presentationDetents([.height(480)]).presentationDragIndicator(.visible).presentationCornerRadius(38)
        }
    }

    struct ClaudeAttachmentSheet: View {
        @Binding var state: SessionState
        let mediaContent: (ClaudeMedia, ClaudeMediaPresentation) -> AnyView
        let action: (ClaudeAction) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var page = "Add to session"
        @State private var camera = false
        @State private var systemCamera = false
        @State private var showingFileImporter = false
        @State private var selectedPhotoItems: [PhotosPickerItem] = []
        @State private var importError: String?

        private var activeProjectName: String {
            guard let id = state.activeProjectID,
                let proj = state.projects.projects.first(where: { $0.id == id })
            else { return "None" }
            return proj.name
        }

        private var connectedDeviceSummary: String {
            guard state.deviceEnabled,
                let first = state.devices.rows.first(where: { $0.status == .connected }) ?? state.devices.rows.first
            else { return "None" }
            return first.name
        }

        var body: some View {
            VStack(spacing: 16) {
                SheetHeader(
                    title: page, back: page != "Add to session",
                    close: { if page == "Add to session" { dismiss() } else { page = "Add to session" } })
                switch page {
                case "Select mode":
                    RowGroup {
                        SheetRow(
                            title: "Manually approve", symbol: "hand.raised",
                            detail: "Ask before running external actions.",
                            checked: !state.automaticApproval
                        ) {
                            action(.setAutomaticApproval(false))
                            page = "Add to session"
                        }
                        RowDivider()
                        SheetRow(
                            title: "Automatically approve", symbol: "forward",
                            detail: "Allow safe tools like DuckDuckGo search and calculator automatically.",
                            checked: state.automaticApproval
                        ) {
                            action(.setAutomaticApproval(true))
                            page = "Add to session"
                        }
                    }.padding(.horizontal, 16)
                case "Devices":
                    if state.devices.rows.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "desktopcomputer").font(.system(size: 34, weight: .light))
                                .foregroundStyle(ClaudePalette.secondary)
                            Text("No connected computers").font(.system(size: 17, weight: .medium))
                            Text("Pair a remote computer host to dispatch desktop tasks from your iPhone.")
                                .font(.system(size: 14)).foregroundStyle(ClaudePalette.secondary)
                                .multilineTextAlignment(.center).padding(.horizontal, 28)
                        }.frame(maxWidth: .infinity).padding(.top, 28)
                    } else {
                        VStack(alignment: .leading, spacing: 9) {
                            RowGroup {
                                ForEach(Array(state.devices.rows.enumerated()), id: \.element.id) { idx, row in
                                    SheetRow(
                                        title: row.name, detail: row.subtitle,
                                        checked: state.deviceEnabled
                                    ) { action(.setDeviceEnabled(!state.deviceEnabled)) }
                                    if idx + 1 < state.devices.rows.count { RowDivider() }
                                }
                            }
                        }.padding(.horizontal, 16)
                    }
                case "Add to project":
                    ScrollView {
                        VStack(spacing: 12) {
                            RowGroup {
                                SheetRow(
                                    title: "None", symbol: "xmark.circle",
                                    checked: state.activeProjectID == nil
                                ) {
                                    action(.selectActiveProject(nil))
                                    dismiss()
                                }
                                ForEach(state.projects.projects) { project in
                                    RowDivider()
                                    SheetRow(
                                        title: project.name, symbol: project.icon,
                                        detail: project.goal.isEmpty ? nil : project.goal,
                                        checked: state.activeProjectID == project.id
                                    ) {
                                        action(.selectActiveProject(project.id))
                                        dismiss()
                                    }
                                }
                            }
                            RowGroup {
                                SheetRow(
                                    title: "Manage projects…", symbol: "plus.rectangle.on.folder", chevron: true
                                ) {
                                    dismiss()
                                    action(.openProjects)
                                }
                            }
                        }.padding(.horizontal, 16)
                    }
                default:
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            Button {
                                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                    systemCamera = true
                                } else {
                                    camera = true
                                }
                            } label: {
                                VStack(spacing: 7) {
                                    Image(systemName: "camera").font(.system(size: 22))
                                    Text("Camera").font(.system(size: 15))
                                }.frame(width: 96, height: 96).background(
                                    ClaudePalette.panel, in: .rect(cornerRadius: 26))
                            }
                            PhotosPicker(
                                selection: $selectedPhotoItems, maxSelectionCount: 4, matching: .images
                            ) {
                                VStack(spacing: 7) {
                                    Image(systemName: "photo.on.rectangle").font(.system(size: 22))
                                    Text("Photos").font(.system(size: 15))
                                }.frame(width: 96, height: 96).background(
                                    ClaudePalette.panel, in: .rect(cornerRadius: 26))
                            }.accessibilityIdentifier("media.photosPicker")
                            Button {
                                showingFileImporter = true
                            } label: {
                                VStack(spacing: 7) {
                                    Image(systemName: "doc.badge.plus").font(.system(size: 22))
                                    Text("Files").font(.system(size: 15))
                                }.frame(width: 96, height: 96).background(
                                    ClaudePalette.panel, in: .rect(cornerRadius: 26))
                            }.accessibilityIdentifier("media.filesPicker")
                            ForEach(state.media.recent) { item in
                                Button {
                                    action(.media(.toggleRecent(item.id)))
                                } label: {
                                    mediaContent(item, .thumbnail).frame(width: 96, height: 96).clipped().clipShape(
                                        .rect(cornerRadius: 26)
                                    )
                                    .overlay(alignment: .topTrailing) {
                                        if state.media.selectedIDs.contains(item.id) {
                                            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(.white).frame(width: 26, height: 26).background(
                                                    .black, in: .circle
                                                ).padding(7)
                                        }
                                    }
                                }.accessibilityLabel(item.accessibilityDescription).accessibilityValue(
                                    state.media.selectedIDs.contains(item.id) ? "Selected" : "Not selected"
                                ).accessibilityIdentifier("media.recent." + item.id)
                            }
                        }.padding(.horizontal, 16)
                    }.scrollIndicators(.hidden)
                    if let importError {
                        Text(importError).font(.footnote).foregroundStyle(ClaudePalette.orange)
                            .padding(.horizontal, 20)
                    }
                    RowGroup {
                        SheetRow(
                            title: "DuckDuckGo Web Search", symbol: "globe",
                            value: state.webSearchEnabled ? "On" : "Auto",
                            checked: state.webSearchEnabled
                        ) { action(.toggleWebSearch) }
                        RowDivider()
                        SheetRow(
                            title: "Project context", symbol: "rectangle.stack",
                            value: activeProjectName, chevron: true
                        ) { page = "Add to project" }
                    }.padding(.horizontal, 16)
                    RowGroup {
                        SheetRow(
                            title: "Permission", symbol: "hand.raised",
                            value: state.automaticApproval ? "Automatic" : "Manual", chevron: true
                        ) { page = "Select mode" }
                        RowDivider()
                        SheetRow(
                            title: "Devices", symbol: "desktopcomputer",
                            value: connectedDeviceSummary, chevron: true
                        ) { page = "Devices" }
                    }.padding(.horizontal, 16)
                }
                Spacer(minLength: 0)
            }.background(ClaudePalette.background).foregroundStyle(ClaudePalette.ink)
                .presentationDetents([.height(455)]).presentationDragIndicator(.visible).presentationCornerRadius(38)
                .overlay(alignment: .bottom) {
                    if page == "Add to session", !state.media.selected.isEmpty {
                        Button {
                            action(.media(.attachSelected))
                            dismiss()
                        } label: {
                            let count = state.media.selected.count
                            Text("Attach \(count) \(count == 1 ? "photo" : "photos")")
                                .font(.system(size: 16, weight: .medium)).frame(maxWidth: .infinity).frame(height: 46)
                                .foregroundStyle(ClaudePalette.background).background(ClaudePalette.ink, in: .capsule)
                        }.padding(.horizontal, 16).padding(.bottom, 16).accessibilityIdentifier("media.attachSelected")
                    }
                }
                .onAppear { action(.media(.beginSelection)) }
                .onDisappear { action(.media(.cancelSelection)) }
                .onChange(of: selectedPhotoItems) { _, newItems in
                    guard !newItems.isEmpty else { return }
                    Task {
                        await loadPickedPhotos(newItems)
                        selectedPhotoItems = []
                        dismiss()
                    }
                }
                .fileImporter(
                    isPresented: $showingFileImporter,
                    allowedContentTypes: [.plainText, .sourceCode, .json, .xml, .html, .commaSeparatedText, .data],
                    allowsMultipleSelection: true
                ) { result in
                    handleImportedFiles(result)
                }
                .fullScreenCover(isPresented: $systemCamera) {
                    ClaudeSystemCameraPicker { image in
                        let stamp = Int(Date().timeIntervalSince1970)
                        if let payload = Self.encodeImagePayload(image, fileName: "Camera-\(stamp).jpg") {
                            action(.attachPayload(payload))
                        }
                        systemCamera = false
                        dismiss()
                    } onCancel: {
                        systemCamera = false
                    }
                }
                .fullScreenCover(isPresented: $camera) {
                    ClaudeCameraView(
                        onCancel: { camera = false },
                        onCapture: { _ in camera = false }
                    ) { SyntheticCameraPreview() }
                }
        }

        @MainActor
        private func loadPickedPhotos(_ items: [PhotosPickerItem]) async {
            for (idx, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self),
                    let image = UIImage(data: data),
                    let payload = Self.encodeImagePayload(image, fileName: "Photo-\(idx + 1).jpg")
                else { continue }
                action(.attachPayload(payload))
            }
        }

        private func handleImportedFiles(_ result: Result<[URL], Error>) {
            switch result {
            case .failure(let error):
                importError = error.localizedDescription
            case .success(let urls):
                var attachedAny = false
                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url) else { continue }
                    let name = url.lastPathComponent
                    if let image = UIImage(data: data),
                        let payload = Self.encodeImagePayload(image, fileName: name)
                    {
                        action(.attachPayload(payload))
                        attachedAny = true
                    } else if let text = String(data: data.prefix(64_000), encoding: .utf8)
                        ?? String(data: data.prefix(64_000), encoding: .isoLatin1)
                    {
                        let payload = ClaudeAttachmentPayload(
                            fileName: name, kind: .textFile, mimeType: "text/plain", textContent: text)
                        action(.attachPayload(payload))
                        attachedAny = true
                    }
                }
                if attachedAny {
                    dismiss()
                } else {
                    importError = "Unsupported or unreadable file format."
                }
            }
        }

        static func encodeImagePayload(_ image: UIImage, fileName: String) -> ClaudeAttachmentPayload? {
            let maxDimension: CGFloat = 1280
            let size = image.size
            guard size.width > 0, size.height > 0 else { return nil }
            let scale = min(1.0, maxDimension / max(size.width, size.height))
            let targetSize = CGSize(width: round(size.width * scale), height: round(size.height * scale))
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            let resized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { return nil }
            let ratio = Double(targetSize.width / max(1, targetSize.height))
            return ClaudeAttachmentPayload(
                fileName: fileName, kind: .image, mimeType: "image/jpeg",
                base64Data: jpeg.base64EncodedString(), aspectRatio: ratio)
        }
    }

    struct ClaudeSystemCameraPicker: UIViewControllerRepresentable {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, onCancel: onCancel) }

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

        @MainActor
        final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
            let onCapture: (UIImage) -> Void
            let onCancel: () -> Void

            init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
                self.onCapture = onCapture
                self.onCancel = onCancel
            }

            func imagePickerController(
                _ picker: UIImagePickerController,
                didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                if let image = info[.originalImage] as? UIImage {
                    onCapture(image)
                } else {
                    onCancel()
                }
            }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
                onCancel()
            }
        }
    }

    struct SyntheticPhoto: View {
        let index: Int
        var body: some View {
            GeometryReader { geo in
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.40, green: 0.59, blue: 0.68), Color(red: 0.77, green: 0.77, blue: 0.59)],
                        startPoint: .top, endPoint: .bottom)
                    Circle().fill(Color(white: 0.95).opacity(0.85)).frame(width: 19, height: 19).offset(x: 21, y: -22)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height))
                        p.addLine(to: CGPoint(x: 0, y: 70))
                        p.addLine(to: CGPoint(x: 28, y: 36 + index * 7))
                        p.addLine(to: CGPoint(x: 62, y: 72))
                        p.addLine(to: CGPoint(x: 84, y: 40))
                        p.addLine(to: CGPoint(x: geo.size.width, y: 68))
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        p.closeSubpath()
                    }.fill(Color(red: 0.20, green: 0.35, blue: 0.29))
                }
            }
        }
    }

    struct ClaudeConversationSearchSheet: View {
        let conversations: [ClaudeConversationSummary]
        let onSelect: (UUID) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var query = ""

        private var matches: [ClaudeConversationSummary] {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return conversations }
            return conversations.filter { conv in
                conv.title.localizedCaseInsensitiveContains(trimmed)
                    || conv.messages.contains { $0.text.localizedCaseInsensitiveContains(trimmed) }
            }
        }

        var body: some View {
            VStack(spacing: 14) {
                SheetHeader(title: "Search conversations", close: { dismiss() })
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ClaudePalette.secondary)
                    TextField("Search titles or messages…", text: $query)
                        .accessibilityIdentifier("conversations.searchField")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(ClaudePalette.secondary)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 14).frame(height: 44).background(ClaudePalette.panel, in: .capsule)
                    .padding(.horizontal, 16)
                if matches.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 32, weight: .light))
                            .foregroundStyle(ClaudePalette.secondary)
                        Text(conversations.isEmpty ? "No saved conversations yet" : "No matching conversations")
                            .font(.system(size: 16, weight: .medium))
                    }.frame(maxWidth: .infinity).padding(.top, 48)
                } else {
                    ScrollView {
                        RowGroup {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { idx, conv in
                                SheetRow(
                                    title: conv.title,
                                    symbol: conv.pinned ? "pin.fill" : "bubble.left",
                                    detail: conv.messages.last?.text.replacingOccurrences(of: "\n", with: " ")
                                        .prefix(90).description,
                                    value: "\(conv.messages.count)"
                                ) {
                                    onSelect(conv.id)
                                    dismiss()
                                }
                                if idx + 1 < matches.count { RowDivider() }
                            }
                        }.padding(.horizontal, 16)
                    }
                }
                Spacer(minLength: 0)
            }.background(ClaudePalette.background).foregroundStyle(ClaudePalette.ink)
                .presentationDragIndicator(.visible).presentationCornerRadius(38)
        }
    }

    struct ClaudeRenameConversationSheet: View {
        let initialTitle: String
        let onSave: (String) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var title: String

        init(initialTitle: String, onSave: @escaping (String) -> Void) {
            self.initialTitle = initialTitle
            self.onSave = onSave
            _title = State(initialValue: initialTitle)
        }

        var body: some View {
            VStack(spacing: 18) {
                SheetHeader(
                    title: "Rename conversation", trailing: "Save", close: { dismiss() },
                    trailingAction: {
                        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty { onSave(cleaned) }
                        dismiss()
                    })
                TextField("Conversation title", text: $title)
                    .font(.system(size: 17))
                    .padding(.horizontal, 16).frame(height: 50)
                    .background(ClaudePalette.panel, in: .rect(cornerRadius: 18))
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("conversation.renameField")
                Spacer()
            }.background(ClaudePalette.background).foregroundStyle(ClaudePalette.ink)
                .presentationDetents([.height(240)]).presentationDragIndicator(.visible).presentationCornerRadius(34)
        }
    }

    struct ClaudeSelectTextSheet: View {
        let text: String
        @Environment(\.dismiss) private var dismiss
        @State private var copied = false

        var body: some View {
            VStack(spacing: 12) {
                SheetHeader(
                    title: "Select text", trailing: copied ? "Copied" : "Copy all",
                    close: { dismiss() },
                    trailingAction: {
                        UIPasteboard.general.string = text
                        copied = true
                    })
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(size: 16))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }.background(ClaudePalette.panel, in: .rect(cornerRadius: 22)).padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }.background(ClaudePalette.background).foregroundStyle(ClaudePalette.ink)
                .presentationDragIndicator(.visible).presentationCornerRadius(38)
        }
    }

    struct ClaudeActivityShareSheet: UIViewControllerRepresentable {
        let items: [Any]
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items, applicationActivities: nil)
        }
        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
    }

    struct ThemeThumbnail: View {
        let appearance: ClaudeAppearance
        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    (appearance == .dark ? Color(white: 0.08) : Color.white)
                    if appearance == .system {
                        Path { p in
                            p.move(to: CGPoint(x: geo.size.width, y: 0))
                            p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                            p.addLine(to: CGPoint(x: 0, y: geo.size.height))
                            p.closeSubpath()
                        }.fill(Color(white: 0.08))
                    }
                    RoundedRectangle(cornerRadius: 9).stroke(.gray.opacity(0.3), lineWidth: 0.7).padding(8)
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().frame(width: 39, height: 3)
                        Capsule().frame(width: 27, height: 3)
                    }.foregroundStyle(.gray).padding(16)
                    Circle().fill(Color(red: 0.85, green: 0.47, blue: 0.34)).frame(width: 12, height: 12).position(
                        x: geo.size.width - 20, y: geo.size.height - 20)
                }.clipShape(.rect(cornerRadius: 14)).overlay {
                    RoundedRectangle(cornerRadius: 14).stroke(.gray.opacity(0.2), lineWidth: 0.6)
                }
            }
        }
    }

    struct ClaudeFeedbackSheet: View {
        let positive: Bool
        var submit: (FeedbackSubmission) -> Void
        @Environment(\.dismiss) private var dismiss
        @State private var comment = ""
        @State private var category = "Other"
        private let categories = [
            "Other", "UI bug", "Harmful content", "Overactive refusal", "Did not fully follow my request",
            "Not factually correct", "Incomplete response", "Issue with memory"
        ]
        var body: some View {
            VStack(spacing: 18) {
                SheetHeader(
                    title: "Feedback", trailing: "✓", close: { dismiss() },
                    trailingAction: {
                        submit(FeedbackSubmission(positive: positive, comment: comment, issue: category))
                        dismiss()
                    })
                if !positive {
                    HStack {
                        Text("Type of issue")
                        Spacer()
                        Picker("Type of issue", selection: $category) { ForEach(categories, id: \.self) { Text($0) } }
                    }.padding(.horizontal, 22)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $comment).scrollContentBackground(.hidden).padding(10)
                    if comment.isEmpty {
                        Text(
                            positive
                                ? "What was satisfying about this response?"
                                : "What was unsatisfying about this response?"
                        ).foregroundStyle(ClaudePalette.secondary).padding(18).allowsHitTesting(false)
                    }
                }.frame(height: positive ? 185 : 150).background(ClaudePalette.panel, in: .rect(cornerRadius: 24))
                    .padding(.horizontal, 16)
                Text("Feedback is stored locally on your device.").font(.footnote)
                    .foregroundStyle(ClaudePalette.secondary).padding(.horizontal, 24)
                Spacer()
            }.background(ClaudePalette.background).foregroundStyle(ClaudePalette.ink)
                .presentationDetents([.height(430)]).presentationDragIndicator(.visible).presentationCornerRadius(38)
        }
    }
#endif

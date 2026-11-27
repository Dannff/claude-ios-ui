import Foundation

public struct ClaudeExtractedArtifact: Equatable, Sendable {
    public var title: String
    public var language: String
    public var content: String
    public var isHTML: Bool

    public init(title: String, language: String, content: String, isHTML: Bool) {
        self.title = title
        self.language = language
        self.content = content
        self.isHTML = isHTML
    }
}

public enum ClaudeHTMLPreviewSupport {
    private static let previewLanguages: Set<String> = ["html", "htm", "xhtml", "svg"]

    public static func isPreviewableCode(language: String?, content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !lang.isEmpty {
            if previewLanguages.contains(lang) { return true }
            if lang == "xml" && trimmed.localizedCaseInsensitiveContains("<svg") { return true }
            return false
        }
        let lower = String(trimmed.prefix(256)).lowercased()
        return lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") || lower.hasPrefix("<svg")
    }

    public static func isSubstantialRawHTML(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 32 else { return false }
        let lower = trimmed.lowercased()
        return lower.contains("<html") || lower.contains("<!doctype html") || lower.contains("<svg")
            || (lower.contains("<div") && lower.contains("</div>"))
            || (lower.contains("<style") && lower.contains("</style>"))
            || (lower.contains("<canvas") && lower.contains("</canvas>"))
    }

    public static func extractTitle(from source: String, language: String? = nil) -> String {
        if let title = firstTagContent("title", in: source), !title.isEmpty { return title }
        if let heading = firstTagContent("h1", in: source), !heading.isEmpty { return heading }
        let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lang == "svg" || source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<svg") {
            return "SVG Preview"
        }
        return "HTML Preview"
    }

    public static func normalizedHTMLDocument(
        source: String, language: String? = nil, darkBackground: Bool = false
    ) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerLang = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isSVG = lowerLang == "svg" || trimmed.lowercased().hasPrefix("<svg")
        let bg = darkBackground ? "#141414" : "#ffffff"
        let fg = darkBackground ? "#ececec" : "#1c1c1e"

        let errorBridge = """
            <script>
            window.addEventListener('error', function(e) {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.claudePreviewError) {
                window.webkit.messageHandlers.claudePreviewError.postMessage(String(e.message || 'Runtime error'));
              }
            });
            </script>
            """

        if isSVG {
            return """
                <!DOCTYPE html>
                <html>
                <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <style>
                html, body { margin: 0; padding: 16px; background: \(bg); color: \(fg);
                  display: flex; align-items: center; justify-content: center; min-height: calc(100vh - 32px); }
                svg { max-width: 100%; height: auto; }
                </style>
                \(errorBridge)
                </head>
                <body>
                \(trimmed)
                </body>
                </html>
                """
        }

        let lower = trimmed.lowercased()
        if lower.contains("<html") || lower.contains("<!doctype html") {
            if lower.contains("<head") {
                if let range = trimmed.range(of: "<head>", options: .caseInsensitive) {
                    var result = trimmed
                    let viewportMeta =
                        lower.contains("name=\"viewport\"") || lower.contains("name='viewport'")
                        ? "" : "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
                    let charsetMeta = lower.contains("charset=") ? "" : "<meta charset=\"utf-8\">"
                    result.insert(
                        contentsOf: charsetMeta + viewportMeta + errorBridge,
                        at: range.upperBound)
                    return result
                }
            }
            return errorBridge + "\n" + trimmed
        }

        return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 16px;
              background: \(bg); color: \(fg); }
            </style>
            \(errorBridge)
            </head>
            <body>
            \(trimmed)
            </body>
            </html>
            """
    }

    public static func extractArtifacts(from markdown: String) -> [ClaudeExtractedArtifact] {
        let doc = MarkdownDocumentModel(source: markdown)
        var results: [ClaudeExtractedArtifact] = []
        for block in doc.blocks {
            switch block {
            case .code(let language, let content):
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let previewable = isPreviewableCode(language: language, content: trimmed)
                let lineCount = trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
                guard previewable || lineCount >= 12 else { continue }
                let cleanLang = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let lang = cleanLang.isEmpty ? (previewable ? "html" : "code") : cleanLang
                let title =
                    previewable
                    ? extractTitle(from: trimmed, language: lang)
                    : inferredCodeTitle(language: lang, content: trimmed)
                results.append(.init(title: title, language: lang, content: trimmed, isHTML: previewable))
            case .unsupported(let kind, let source) where kind == .html && isSubstantialRawHTML(source):
                let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
                results.append(
                    .init(
                        title: extractTitle(from: trimmed, language: "html"),
                        language: "html", content: trimmed, isHTML: true))
            default:
                break
            }
        }
        return results
    }

    private static func inferredCodeTitle(language: String, content: String) -> String {
        let firstLine =
            content.split(separator: "\n").first.map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
        let cleaned =
            firstLine
            .replacingOccurrences(of: "//", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "/*", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty, cleaned.count <= 48 { return cleaned }
        return language.uppercased() + " Snippet"
    }

    private static func firstTagContent(_ tag: String, in html: String) -> String? {
        let pattern = "<" + tag + "[^>]*>(.*?)</" + tag + ">"
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: html)
        else { return nil }
        let raw = String(html[range])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : String(raw.prefix(60))
    }
}

#if canImport(UIKit)
    import SwiftUI
    import UIKit
    import WebKit

    public struct ClaudeHTMLWebView: UIViewRepresentable {
        public let html: String
        public var reloadToken: Int
        public var desktopViewport: Bool
        public var onRuntimeError: ((String?) -> Void)?

        public init(
            html: String, reloadToken: Int = 0, desktopViewport: Bool = false,
            onRuntimeError: ((String?) -> Void)? = nil
        ) {
            self.html = html
            self.reloadToken = reloadToken
            self.desktopViewport = desktopViewport
            self.onRuntimeError = onRuntimeError
        }

        public func makeCoordinator() -> Coordinator { Coordinator(onRuntimeError: onRuntimeError) }

        public func makeUIView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.allowsInlineMediaPlayback = true
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            let controller = WKUserContentController()
            controller.add(WeakScriptHandler(delegate: context.coordinator), name: "claudePreviewError")
            config.userContentController = controller
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            return webView
        }

        public func updateUIView(_ webView: WKWebView, context: Context) {
            context.coordinator.onRuntimeError = onRuntimeError
            let payload = viewportAdjustedHTML()
            let key = "\(reloadToken):\(desktopViewport):\(payload)"
            guard context.coordinator.lastLoadedKey != key else { return }
            context.coordinator.lastLoadedKey = key
            context.coordinator.onRuntimeError?(nil)
            webView.loadHTMLString(payload, baseURL: URL(string: "https://preview.local/"))
        }

        public static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "claudePreviewError")
        }

        private func viewportAdjustedHTML() -> String {
            guard desktopViewport else { return html }
            return html.replacingOccurrences(
                of: "width=device-width, initial-scale=1",
                with: "width=980")
        }

        @MainActor public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
            var lastLoadedKey: String?
            var onRuntimeError: ((String?) -> Void)?

            init(onRuntimeError: ((String?) -> Void)?) { self.onRuntimeError = onRuntimeError }

            public func userContentController(
                _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
            ) {
                if let text = message.body as? String, !text.isEmpty {
                    onRuntimeError?(text)
                }
            }

            public func webView(
                _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
            ) async -> WKNavigationActionPolicy {
                guard let url = navigationAction.request.url else {
                    return .allow
                }
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme == "about" || scheme == "data" || scheme == "blob" || url.host == "preview.local" {
                    return .allow
                }
                if navigationAction.navigationType == .linkActivated, scheme == "https" || scheme == "http" {
                    await UIApplication.shared.open(url)
                    return .cancel
                }
                return .allow
            }
        }
    }

    @MainActor private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
        weak var delegate: WKScriptMessageHandler?
        init(delegate: WKScriptMessageHandler) { self.delegate = delegate }
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            delegate?.userContentController(userContentController, didReceive: message)
        }
    }

    struct ClaudeInlineHTMLCodeCard: View {
        let language: String?
        let content: String
        let theme: ClaudeMarkdownTheme
        let codeView: () -> AnyView
        let onAction: (MarkdownAction) -> Void
        @Environment(\.colorScheme) private var colorScheme
        @State private var showPreview = true
        @State private var tallFrame = false
        @State private var reloadToken = 0
        @State private var darkCanvas = false
        @State private var runtimeError: String?
        @State private var fullScreenPresented = false

        private var badgeTitle: String {
            let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
            if !lang.isEmpty { return lang }
            return content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<svg")
                ? "SVG" : "HTML"
        }

        private var renderedHTML: String {
            ClaudeHTMLPreviewSupport.normalizedHTMLDocument(
                source: content, language: language, darkBackground: darkCanvas)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(theme.rule).frame(height: 0.5)
                if showPreview {
                    VStack(spacing: 0) {
                        if let runtimeError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ClaudePalette.orange)
                                Text(runtimeError).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 12).padding(.vertical, 6)
                                .background(ClaudePalette.orange.opacity(0.14))
                        }
                        ClaudeHTMLWebView(html: renderedHTML, reloadToken: reloadToken) { err in
                            runtimeError = err
                        }
                        .frame(height: tallFrame ? 460 : 300)
                        .clipShape(.rect(bottomLeadingRadius: 24, bottomTrailingRadius: 24))
                    }
                } else {
                    ScrollView(.horizontal) {
                        codeView().accessibilityIdentifier("markdown.code.content")
                    }.scrollIndicators(.hidden).padding(16)
                }
            }
            .background(theme.codeBackground, in: .rect(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).stroke(theme.rule, lineWidth: 0.6) }
            .onAppear { darkCanvas = (colorScheme == .dark) }
            .fullScreenCover(isPresented: $fullScreenPresented) {
                ClaudeHTMLPreviewSheet(
                    title: ClaudeHTMLPreviewSupport.extractTitle(from: content, language: language),
                    language: language, content: content, codeView: codeView, onAction: onAction)
            }
        }

        private var header: some View {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    modePill(title: "Preview", icon: "safari", selected: showPreview) { showPreview = true }
                    modePill(title: badgeTitle, icon: "chevron.left.forwardslash.chevron.right", selected: !showPreview)
                    { showPreview = false }
                }.padding(3).background(ClaudePalette.adaptive(light: 0.93, dark: 0.19), in: .capsule)

                Spacer(minLength: 4)

                if showPreview {
                    Button {
                        darkCanvas.toggle()
                    } label: {
                        Image(systemName: darkCanvas ? "moon.fill" : "sun.max").frame(width: 28, height: 28)
                    }.accessibilityLabel("Toggle preview background")
                    Button {
                        tallFrame.toggle()
                    } label: {
                        Image(systemName: tallFrame ? "arrow.down.right.and.arrow.up.left" : "arrow.up.and.down")
                            .frame(width: 28, height: 28)
                    }.accessibilityLabel("Resize preview")
                    Button {
                        reloadToken &+= 1
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                    }.accessibilityLabel("Reload HTML preview")
                }

                Button {
                    onAction(.saveArtifact(language: language ?? "html", content: content))
                } label: {
                    Image(systemName: "plus.square.on.square").frame(width: 28, height: 28)
                }.accessibilityLabel("Save as artifact")

                Button {
                    onAction(.copyCode(content))
                } label: {
                    Image(systemName: "square.on.square").frame(width: 28, height: 28)
                }.accessibilityLabel("Copy code").accessibilityIdentifier("markdown.code.copy")

                Button {
                    fullScreenPresented = true
                    onAction(.expandCode(language: language, content: content))
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 28, height: 28)
                }.accessibilityLabel("Expand HTML preview").accessibilityIdentifier("markdown.code.expand")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }

        private func modePill(
            title: String, icon: String, selected: Bool, action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                    Text(title).font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? ClaudePalette.ink : theme.secondary)
                .background(selected ? ClaudePalette.panel : .clear, in: .capsule)
            }.buttonStyle(.plain)
        }
    }

    public struct ClaudeHTMLPreviewSheet: View {
        public let title: String
        public let language: String?
        public let content: String
        private let codeView: () -> AnyView
        private let onAction: (MarkdownAction) -> Void
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        @State private var showCode = false
        @State private var desktopViewport = false
        @State private var darkCanvas = false
        @State private var reloadToken = 0
        @State private var runtimeError: String?
        @State private var exportURL: URL?

        public init(
            title: String, language: String?, content: String,
            codeView: @escaping () -> AnyView,
            onAction: @escaping (MarkdownAction) -> Void = { _ in }
        ) {
            self.title = title
            self.language = language
            self.content = content
            self.codeView = codeView
            self.onAction = onAction
        }

        private var renderedHTML: String {
            ClaudeHTMLPreviewSupport.normalizedHTMLDocument(
                source: content, language: language, darkBackground: darkCanvas)
        }

        public var body: some View {
            VStack(spacing: 0) {
                topBar
                Divider()
                if let runtimeError, !showCode {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ClaudePalette.orange)
                        Text(runtimeError).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                        Spacer()
                        Button("Dismiss") { self.runtimeError = nil }.font(.caption)
                    }.padding(.horizontal, 16).padding(.vertical, 8).background(ClaudePalette.orange.opacity(0.14))
                }
                if showCode {
                    ScrollView([.vertical, .horizontal]) {
                        codeView().padding(16).accessibilityIdentifier("markdown.code.expandedContent")
                    }.defaultScrollAnchor(.topLeading, for: .alignment)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ClaudeHTMLWebView(
                        html: renderedHTML, reloadToken: reloadToken, desktopViewport: desktopViewport
                    ) { err in
                        runtimeError = err
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(ClaudePalette.background.ignoresSafeArea())
            .foregroundStyle(ClaudePalette.ink)
            .onAppear {
                darkCanvas = (colorScheme == .dark)
                prepareExportFile()
            }
        }

        private var topBar: some View {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 18)).frame(width: 40, height: 40)
                }.glassEffect(in: .circle).accessibilityLabel("Close code").accessibilityIdentifier(
                    "markdown.code.close")

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(desktopViewport ? "Desktop viewport (980px)" : "Mobile viewport")
                        .font(.system(size: 11)).foregroundStyle(ClaudePalette.secondary)
                }

                Spacer(minLength: 4)

                Picker("Mode", selection: $showCode) {
                    Text("Preview").tag(false)
                    Text("Code").tag(true)
                }.pickerStyle(.segmented).frame(width: 146)

                Menu {
                    Button {
                        reloadToken &+= 1
                    } label: {
                        Label("Reload preview", systemImage: "arrow.clockwise")
                    }
                    Button {
                        desktopViewport.toggle()
                    } label: {
                        Label(
                            desktopViewport ? "Switch to Mobile width" : "Switch to Desktop width",
                            systemImage: desktopViewport ? "iphone" : "desktopcomputer")
                    }
                    Button {
                        darkCanvas.toggle()
                    } label: {
                        Label(
                            darkCanvas ? "Light canvas background" : "Dark canvas background",
                            systemImage: darkCanvas ? "sun.max" : "moon.fill")
                    }
                    Divider()
                    Button {
                        onAction(.copyCode(content))
                    } label: {
                        Label("Copy HTML source", systemImage: "doc.on.doc")
                    }
                    Button {
                        onAction(.saveArtifact(language: language ?? "html", content: content))
                    } label: {
                        Label("Save to Artifacts", systemImage: "square.on.circle")
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Export / Open .html", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 20)).frame(width: 40, height: 40)
                }.glassEffect(in: .circle).accessibilityLabel("Preview options")
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }

        private func prepareExportFile() {
            let safeName =
                title.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let fileName = (safeName.isEmpty ? "preview" : safeName) + ".html"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try? renderedHTML.data(using: .utf8)?.write(to: url, options: .atomic)
            exportURL = url
        }
    }
#endif

#if canImport(UIKit)
    import SwiftUI
    import UIKit

    /// Keeps UIKit's active edit buffer authoritative while the host receives draft changes.
    /// Reassigning a stale SwiftUI value during an input event can replace characters in flight.
    struct ClaudeProfileTextField: UIViewRepresentable {
        let text: String
        let placeholder: String
        let identifier: String
        let update: (String) -> Void
        var isURL: Bool = false
        var isSecure: Bool = false
        var disablesAutocapitalization: Bool = false
        var revision: Int = 0
        func makeCoordinator() -> Coordinator { Coordinator(update: update, revision: revision) }
        func makeUIView(context: Context) -> UITextField {
            let field = UITextField()
            field.text = text
            field.placeholder = placeholder
            field.font = .systemFont(ofSize: 17)
            field.textColor = .label
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.isSecureTextEntry = isSecure
            if isSecure {
                field.textContentType = .password
                field.autocapitalizationType = .none
            } else if isURL {
                field.textContentType = .URL
                field.keyboardType = .URL
                field.autocapitalizationType = .none
            } else if disablesAutocapitalization {
                field.textContentType = .none
                field.keyboardType = .asciiCapable
                field.autocapitalizationType = .none
            } else {
                field.textContentType = .name
            }
            field.accessibilityIdentifier = identifier
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
            return field
        }
        func updateUIView(_ field: UITextField, context: Context) {
            context.coordinator.update = update
            if field.isSecureTextEntry != isSecure { field.isSecureTextEntry = isSecure }
            let revisionChanged = context.coordinator.revision != revision
            context.coordinator.revision = revision
            if (!field.isFirstResponder || revisionChanged), field.text != text { field.text = text }
        }
        final class Coordinator: NSObject {
            var update: (String) -> Void
            var revision: Int
            init(update: @escaping (String) -> Void, revision: Int) {
                self.update = update
                self.revision = revision
            }
            @objc func changed(_ field: UITextField) { update(field.text ?? "") }
        }
    }
#endif

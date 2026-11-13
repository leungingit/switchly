import SwiftUI

struct ActivityConsentView: View {
    let intent: ActivityConsentState.Intent
    let language: AppLanguage
    @Binding var clearText: String
    let canClear: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    private func t(_ key: String) -> String { language.localizedString(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text(t(title)).font(.headline)
            Text(t(message)).fixedSize(horizontal: false, vertical: true)
            if intent == .clear {
                Text(String(format: t("Type %@ to confirm deletion."), ActivityConsentState.requiredClearText))
                TextField(ActivityConsentState.requiredClearText, text: $clearText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text(t("Deletion confirmation")))
            }
            HStack {
                Spacer()
                Button(t("Cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                if intent == .clear {
                    Button(t("Clear"), role: .destructive, action: onConfirm).disabled(!canClear)
                } else {
                    Button(t("Allow"), action: onConfirm).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: DesignTokens.Plugin.confirmationWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private var title: String {
        switch intent {
        case .recording: return "Enable application activity?"
        case .screenshots: return "Enable activity screenshots?"
        case .clear: return "Clear activity..."
        }
    }
    private var message: String {
        switch intent {
        case .recording:
            return "This records application names and foreground time locally for up to 400 days (64 MiB). It never uploads data. You can stop recording or clear history at any time."
        case .screenshots:
            return "Only applications you explicitly select will be sampled. Images may contain private content. Small images stay on this Mac for 7 days by default, up to 256 MiB."
        case .clear:
            return "This deletes application intervals, screenshots and their backups. Recording will continue if enabled."
        }
    }
}

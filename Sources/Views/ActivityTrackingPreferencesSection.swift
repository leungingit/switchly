import AppKit
import CoreGraphics
import SwiftUI

struct ActivityTrackingPreferencesSection: View {
    @Binding var settings: ActivityTrackingSettings
    let language: AppLanguage
    let tracking: ActivityTrackingService?
    @State private var consent = ActivityConsentState()
    @State private var working = false
    @State private var error = false
    private func t(_ key: String) -> String { language.localizedString(key) }
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Toggle(t("Record application activity"), isOn: Binding(get: { settings.enabled }, set: { value in
                guard consent.request == nil else { return }
                if value { consent.present(.recording) } else { settings.enabled = false }
            }))
            Text(t("Stored only on this Mac. No window titles or typed text. After 5 minutes without input, time since the last input is excluded, including reading and video playback."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker(t("Activity retention"), selection: $settings.retentionDays) {
                ForEach([1,7,30,90,400], id: \.self) { Text("\($0) " + t("days")).tag($0) }
            }
            appList(title: "Excluded applications", values: $settings.excludedBundleIDs)
            Divider()
            Toggle(t("Sample activity screenshots"), isOn: Binding(get: { settings.screenshotsEnabled }, set: { value in
                guard consent.request == nil else { return }
                if value { consent.present(.screenshots) } else { settings.screenshotsEnabled = false }
            }))
            .disabled(!settings.enabled)
            Text(t("Screenshots are limited to applications you choose below. Private windows cannot always be detected. Screen Recording and Accessibility access are required."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if settings.screenshotsEnabled {
                if !CGPreflightScreenCaptureAccess() || !AXIsProcessTrusted() {
                    Label(t("Allow Screen Recording and Accessibility in System Settings."), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundColor(.secondary)
                }
                Picker(t("Screenshot retention"), selection: $settings.screenshotRetentionDays) {
                    ForEach([1,7,30,90], id: \.self) { Text("\($0) " + t("days")).tag($0) }
                }
                appList(title: "Applications allowed in screenshots", values: $settings.screenshotBundleIDs)
            }
            HStack {
                Button(t("Plugin Panels...")) { NotificationCenter.default.post(name: .openPluginPanels, object: nil) }
                Spacer()
                Button(t("Clear activity...")) { consent.present(.clear) }.disabled(working || tracking == nil)
            }
            if working { ProgressView().controlSize(.small) }
            if error { Text(t("Activity data could not be saved. Check available disk space and try again.")).font(.caption).foregroundColor(.secondary) }
        }
        .padding(DesignTokens.Spacing.lg)
        .disabled(working || consent.request != nil)
        .onReceive(NotificationCenter.default.publisher(for: .activityDataDidChange)) { _ in error = tracking?.errorKey != nil }
        .sheet(item: Binding(get: { consent.request }, set: { if $0 == nil { consent.cancel() } })) { request in
            confirmation(request).environment(\.isEnabled, true)
        }
    }
    private func confirmation(_ request: ActivityConsentState.Request) -> some View {
        ActivityConsentView(intent: request.intent, language: language, clearText: $consent.clearText,
                            canClear: consent.canClear && tracking != nil && !working,
                            onCancel: { consent.cancel() }, onConfirm: { confirm(request) })
    }
    private func confirm(_ request: ActivityConsentState.Request) {
        guard let intent = consent.consume(request) else { return }
        AppLogger.info("Activity consent confirmed. intent=\(intent.rawValue)")
        switch intent {
        case .recording: settings.enabled = true
        case .screenshots: settings.screenshotsEnabled = true
        case .clear:
            working = true
            Task { await tracking?.clear(); working = false; error = tracking?.errorKey != nil }
        }
    }
    private func appList(title: String, values: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Text(t(title)).font(.caption.weight(.semibold))
                Spacer()
                Button(t("Add application...")) { chooseApplication(values) }
                    .accessibilityLabel(Text(t("Add application...") + " " + t(title)))
            }
            if values.wrappedValue.isEmpty { Text(t("None selected")).font(.caption).foregroundColor(.secondary) }
            ForEach(values.wrappedValue, id: \.self) { id in
                HStack {
                    Text(displayName(id)).font(.caption).lineLimit(1)
                    Spacer()
                    Button { values.wrappedValue.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).accessibilityLabel(Text(t("Remove") + " " + displayName(id)))
                }
            }
        }
    }
    private func chooseApplication(_ values: Binding<[String]>) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.applicationBundle]
        AppLogger.info("Activity application picker requested")
        panel.begin { response in
            AppLogger.info("Activity application picker completed. response=\(response.rawValue)")
            guard response == .OK else { return }
            for url in panel.urls {
                if let id = Bundle(url: url)?.bundleIdentifier, !values.wrappedValue.contains(id) { values.wrappedValue.append(id) }
            }
        }
    }
    private func displayName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path)
    }
}

//
//  OnlineWeatherPreferences.swift
//  Switchly
//
//  Preferences → Plugins → Online weather. Opt-in and off by default: the only
//  place in Switchly that touches the network. Plugins never see the key or the
//  response — they read the snapshot the host already fetched.
//

import AppKit
import SwiftUI

struct OnlineWeatherPreferences: View {
    let value: OnlineWeatherSettings
    let language: AppLanguage
    let onChange: (OnlineWeatherSettings) -> Void
    /// Same material as the plugin cards around it.
    var material: CrystalMaterial = .legacyDefault
    var service: OnlineWeatherService = .shared

    @State private var isRefreshing = false

    private var isOnline: Binding<Bool> {
        Binding(get: { value.mode == .online }, set: { on in update { $0.mode = on ? .online : .manual } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if value.mode == .online {
                Divider()
                fields
            }
        }
        .cardSurface(
            fill: Color.crystalSurfaceBase.opacity(0.55),
            cornerRadius: DesignTokens.Radius.card,
            material: material,
            showsBorder: true
        )
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "cloud.sun")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(t("Online weather")).font(.headline)
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .help(t("Switchly's only network feature. It fetches the weather from the service you configure here, at most once every 15 minutes; plugins only read the result. Everything else stays local."))
                }
                Text(t("Used by the weather gacha. Off by default; manual weather applies when it is off."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignTokens.Spacing.md)
            Toggle("", isOn: isOnline)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text(t("Online weather")))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var fields: some View {
        VStack(spacing: 0) {
            row(t("Service URL")) {
                TextField(OnlineWeatherSettings.defaultEndpoint, text: text(\.endpoint))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    .help(t("Any service returning the OpenWeatherMap “current weather” shape over HTTPS."))
            }
            Divider().padding(.leading, 14)
            row(t("City")) {
                TextField(t("City name"), text: text(\.city))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            Divider().padding(.leading, 14)
            row(t("API key")) {
                SecureField("", text: text(\.apiKey))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .accessibilityLabel(Text(t("API key")))
            }
            Divider().padding(.leading, 14)
            row(statusText) {
                Button {
                    isRefreshing = true
                    service.forceRefresh()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(t("Refresh now"))
                    }
                }
                .controlSize(.small)
                .disabled(isRefreshing)
                .help(t("Fetches once; the result is reused for 15 minutes."))
            }
            if !value.isReady {
                Divider().padding(.leading, 14)
                Text(t("Fill in the URL, city and API key to use online weather; until then the gacha keeps using the manual weather above."))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
        }
    }

    private var statusText: String {
        guard let cached = service.cachedReading() else { return t("Not fetched yet") }
        let time = cached.fetchedAt.formatted(date: .omitted, time: .shortened)
        return String(format: t("Last updated: %@"), time)
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer(minLength: DesignTokens.Spacing.md)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func text(_ key: WritableKeyPath<OnlineWeatherSettings, String>) -> Binding<String> {
        Binding(get: { value[keyPath: key] },
                set: { new in
                    guard new != value[keyPath: key] else { return }
                    update { $0[keyPath: key] = new }
                    service.forceRefresh()
                })
    }

    private func update(_ change: (inout OnlineWeatherSettings) -> Void) {
        var updated = value
        change(&updated)
        onChange(updated)
    }

    private func t(_ key: String) -> String { language.localizedString(key) }
}

//
//  OnlineWeatherPreferences.swift
//  Switchly
//
//  Online weather block, shown inside the Weather Gacha card in Preferences →
//  Plugins. Opt-in and off by default: the only place in Switchly that touches
//  the network (Open-Meteo, no API key). Plugins only read the snapshot the
//  host already fetched.
//

import AppKit
import SwiftUI

struct OnlineWeatherPreferences: View {
    let value: OnlineWeatherSettings
    let language: AppLanguage
    let onChange: (OnlineWeatherSettings) -> Void
    var service: OnlineWeatherService = .shared

    @State private var isRefreshing = false

    private var isOn: Binding<Bool> {
        Binding(get: { value.enabled }, set: { on in update { $0.enabled = on } })
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.leading, 14)
            header
            if value.enabled {
                Divider().padding(.leading, 14)
                placeRow
                Divider().padding(.leading, 14)
                statusRow
                if !value.isReady {
                    Text(t("Enter a city to use online weather; until then the gacha keeps the manual weather above."))
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 9)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(t("Online weather")).font(.callout.weight(.medium))
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .help(t("Switchly's only network feature, using Open-Meteo (free, no API key): one lookup and one forecast per 15 minutes. Turn it off and everything stays local."))
                }
                Text(t("Open-Meteo · free, no API key · off by default"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: DesignTokens.Spacing.md)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text(t("Online weather")))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var placeRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(t("City"))
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer(minLength: DesignTokens.Spacing.md)
            TextField(t("City name"), text: Binding(
                get: { value.place },
                set: { new in
                    guard new != value.place else { return }
                    update { $0.place = new }
                }))
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
            .onSubmit { service.forceRefresh() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var statusRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: DesignTokens.Spacing.md)
            Button {
                isRefreshing = true
                service.forceRefresh()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    isRefreshing = false
                }
            } label: {
                if isRefreshing { ProgressView().controlSize(.small) } else { Text(t("Refresh now")) }
            }
            .controlSize(.small)
            .disabled(isRefreshing || !value.isReady)
            .help(t("Fetches once; the result is reused for 15 minutes."))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var statusText: String {
        guard let cached = service.cachedReading() else { return t("Not fetched yet") }
        let time = cached.fetchedAt.formatted(date: .omitted, time: .shortened)
        return String(format: t("Last updated: %@"), time)
    }

    private func update(_ change: (inout OnlineWeatherSettings) -> Void) {
        var updated = value
        change(&updated)
        onChange(updated)
        if updated.isReady { service.forceRefresh() }
    }

    private func t(_ key: String) -> String { language.localizedString(key) }
}

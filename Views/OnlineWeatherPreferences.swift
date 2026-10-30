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
    /// Called after a successful fetch so the host can mirror it into the
    /// plugin's own weather options.
    var onReading: (WeatherReading) -> Void = { _ in }
    var service: OnlineWeatherService = .shared
    /// Shown as if a fetch had failed; used by previews and tests.
    var injectedError: String? = nil

    @State private var isRefreshing = false
    @State private var cityError: String?

    private var shownError: String? { cityError ?? injectedError }

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
        VStack(spacing: 0) {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(t("City"))
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer(minLength: DesignTokens.Spacing.md)
            TextField(t("City name"), text: Binding(
                get: { value.place },
                set: { new in
                    guard new != value.place else { return }
                    cityError = nil
                    update { $0.place = new }
                }))
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .systemRed), lineWidth: shownError == nil ? 0 : 1.5))
            .onSubmit { refresh() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        if let shownError {
            Text(shownError)
                .font(.caption)
                .foregroundColor(Color(nsColor: .systemRed))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 9)
        }
        }
    }

    private var statusRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: DesignTokens.Spacing.md)
            Button {
                refresh()
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

    /// Fetches now and reports the failure in place, so a typo in the city is
    /// visible next to the field instead of only in the log.
    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        cityError = nil
        Task { @MainActor in
            let result = await service.refreshNow()
            isRefreshing = false
            switch result {
            case .success(let reading):
                cityError = nil
                onReading(reading)
            case .failure(let error):
                cityError = message(for: error)
            }
        }
    }

    private func message(for error: Error) -> String {
        switch error as? OnlineWeatherError {
        case .placeNotFound: return t("No such city — check the spelling.")
        case .badResponse: return t("The weather service refused the request. Try again later.")
        case .malformed: return t("Unexpected reply from the weather service.")
        case .notConfigured: return t("Enter a city first.")
        case nil: return t("Couldn't reach Open-Meteo. Check your connection.")
        }
    }

    private func update(_ change: (inout OnlineWeatherSettings) -> Void) {
        var updated = value
        change(&updated)
        onChange(updated)
    }

    private func t(_ key: String) -> String { language.localizedString(key) }
}

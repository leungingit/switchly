//
//  UsageStatisticsPreferencesSection.swift
//  Switchly
//
//  Preferences → General → "Usage statistics".
//
//  Its own file for two reasons: PreferencesView is already past the repo's
//  500-line guideline, and this section owns the baseline picker (the only
//  surface it renders in) plus the clear-statistics action.
//

import SwiftUI

struct UsageStatisticsPreferencesSection: View {
    @Binding var isEnabled: Bool
    @ObservedObject var model: StatisticsViewModel
    @State private var showClearConfirmation = false

    private var language: AppLanguage { model.language }

    var body: some View {
        VStack(spacing: 0) {
            row {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 22)
                Text(t("Enabled"))
                    .font(.body)
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .help(t("Record how often you use preview and quick switch. Stored locally, never uploaded."))
                Spacer(minLength: 16)
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
            }

            row {
                BaselinePicker(model: model)
            }

            row {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 22)
                Text(t("Clear Statistics..."))
                    .font(.body)
                Spacer(minLength: 16)
                Button(t("Clear Statistics...")) {
                    showClearConfirmation = true
                }
                .alert(isPresented: $showClearConfirmation) {
                    Alert(title: Text(t("Clear Statistics...")),
                          message: Text(t("This permanently deletes all locally recorded counts.")),
                          primaryButton: .destructive(Text(t("Clear"))) { model.clear() },
                          secondaryButton: .cancel(Text(t("Cancel"))))
                }
            }
        }
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func t(_ key: String) -> String {
        language.localizedString(key)
    }
}

//
//  Workspace.swift
//  Switchly
//
//  Models for workspace-based window switching
//

import Foundation

struct Workspace: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var shortcutKey: String?
    var appItems: [WorkspaceAppItem]
    var missingAppDisplayMode: WorkspaceMissingAppDisplayMode
    var windowSortStrategy: WorkspaceWindowSortStrategy

    init(
        id: UUID = UUID(),
        name: String,
        shortcutKey: String? = nil,
        appItems: [WorkspaceAppItem] = [],
        missingAppDisplayMode: WorkspaceMissingAppDisplayMode = .hidden,
        windowSortStrategy: WorkspaceWindowSortStrategy = .titleAscending
    ) {
        self.id = id
        self.name = name
        self.shortcutKey = shortcutKey
        self.appItems = appItems
        self.missingAppDisplayMode = missingAppDisplayMode
        self.windowSortStrategy = windowSortStrategy
    }
}

struct WorkspaceAppItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var bundleIdentifier: String
    var appName: String

    init(id: UUID = UUID(), bundleIdentifier: String, appName: String) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
    }
}

enum WorkspaceMissingAppDisplayMode: String, Codable, CaseIterable, Hashable {
    case hidden
    case placeholder

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .hidden:
            return language.localizedString("Hide missing apps")
        case .placeholder:
            return language.localizedString("Show placeholders")
        }
    }
}

enum WorkspaceWindowSortStrategy: String, Codable, CaseIterable, Hashable {
    case titleAscending

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .titleAscending:
            return language.localizedString("Title")
        }
    }
}

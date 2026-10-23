//
//  GridBackground.swift
//  Switchly
//
//  Wallpaper background for the desktop grid (settings axis "bg").
//  See docs/desktop-grid-design-spec.md §6.
//

import Foundation

/// Background of the desktop overview.
///
/// Only the light appearance uses the choice; the dark appearance always
/// draws the graphite wall. An unknown persisted value falls back to `.cream`
/// and is logged instead of failing the whole settings decode.
enum GridBackground: String, Codable, CaseIterable, Hashable {
    case cream
    case white

    static let `default`: GridBackground = .cream

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let background = GridBackground(rawValue: raw) else {
            AppLogger.warning("Unknown gridBackground rawValue=\(raw). Falling back to default=\(GridBackground.default.rawValue)")
            self = .default
            return
        }
        self = background
    }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .cream:
            return language.localizedString("Warm white")
        case .white:
            return language.localizedString("Pure white")
        }
    }
}

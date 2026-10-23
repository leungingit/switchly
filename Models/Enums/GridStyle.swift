//
//  GridStyle.swift
//  Switchly
//
//  Overview layout style for the desktop grid (settings axis "style").
//  See docs/desktop-grid-design-spec.md §6.
//

import Foundation

/// How the 3×3 desktop overview lays its cells out.
///
/// The raw values are persisted, so they stay short and stable. An unknown
/// value from a hand-edited settings file falls back to `.c` (the design
/// default) and is logged rather than failing the whole settings decode.
enum GridStyle: String, Codable, CaseIterable, Hashable {
    /// Direction C: full-screen spatial 3×3 grid in perspective.
    case c
    /// Direction B: centred panel with a flat 3×3 grid.
    case b

    static let `default`: GridStyle = .c

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let style = GridStyle(rawValue: raw) else {
            AppLogger.warning("Unknown gridStyle rawValue=\(raw). Falling back to default=\(GridStyle.default.rawValue)")
            self = .default
            return
        }
        self = style
    }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .c:
            return language.localizedString("Perspective Grid")
        case .b:
            return language.localizedString("Centered Panel")
        }
    }
}

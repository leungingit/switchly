//
//  PreviewHotspotEdge.swift
//  Switchly
//
//  Which screen edge hosts the pointer hotspot that opens the preview panel.
//  The bottom edge is not offered: the Dock owns it.
//

import Foundation

enum PreviewHotspotEdge: String, Codable, CaseIterable, Hashable {
    case top
    case left
    case right

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .top: return language.localizedString("Top edge")
        case .left: return language.localizedString("Left edge")
        case .right: return language.localizedString("Right edge")
        }
    }
}

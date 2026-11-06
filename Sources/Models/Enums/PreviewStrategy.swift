//
//  PreviewStrategy.swift
//  Switchly
//
//  Preview mode enumeration - controls which windows are displayed
//

import Foundation

enum PreviewStrategy: String, Codable, CaseIterable, Hashable {
    /// Show all application windows (including system apps)
    case allApplications = "all"
    
    /// Only show configured applications
    case configuredOnly = "configured"
    
    var displayName: String {
        displayName(language: .english)
    }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .allApplications:
            return language.localizedString("Preview All Windows")
        case .configuredOnly:
            return language.localizedString("Only Configured Apps")
        }
    }
    
    var systemImageName: String {
        switch self {
        case .allApplications:
            return "square.stack.3d.up"
        case .configuredOnly:
            return "target"
        }
    }
}

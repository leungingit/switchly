//
//  ShortcutPrefix.swift
//  Switchly
//
//  Key combination prefix enumeration for global shortcuts
//

import Foundation

enum ShortcutPrefix: String, Codable, CaseIterable, Hashable {
    case commandOption = "cmd+opt"
    case commandControl = "cmd+ctrl"
    case controlOption = "ctrl+opt"
    case commandShift = "cmd+shift"
    case commandOptionShift = "cmd+opt+shift"
    
    var displayName: String {
        switch self {
        case .commandOption:
            return "⌘⌥"
        case .commandControl:
            return "⌘⌃"
        case .controlOption:
            return "⌃⌥"
        case .commandShift:
            return "⌘⇧"
        case .commandOptionShift:
            return "⌘⌥⇧"
        }
    }
}

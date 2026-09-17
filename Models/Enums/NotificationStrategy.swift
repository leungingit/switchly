//
//  NotificationStrategy.swift
//  Switchly
//
//  Notification behavior strategy enumeration
//

import Foundation

enum NotificationStrategy: String, Codable, CaseIterable, Hashable {
    case intelligent = "intelligent"
    case all = "all"
    case silent = "silent"
    
    var displayName: String {
        switch self {
        case .intelligent:
            return NSLocalizedString("Intelligent Notifications", comment: "")
        case .all:
            return NSLocalizedString("All Notifications", comment: "")
        case .silent:
            return NSLocalizedString("Silent Mode", comment: "")
        }
    }
}

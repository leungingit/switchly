//
//  WindowInfo.swift
//  Switchly
//
//  Window information model - represents a single application window
//

import Foundation
import CoreGraphics

struct WindowInfo: Identifiable, Codable, Hashable {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let windowTitle: String
    let bounds: CGRect
    let isOnCurrentSpace: Bool
    let windowNumber: Int
    let isMinimized: Bool
    let isHidden: Bool
    /// 无归属信息时不宣称窗口在其他桌面。
    let isOnOtherSpace: Bool
    
    var canPerformWindowActions: Bool {
        isOnCurrentSpace || (isMinimized && !isOnOtherSpace)
    }

    var statusLocalizationKey: String? {
        if isMinimized { return "Window is minimized" }
        if isHidden { return "Window is hidden" }
        if isOnOtherSpace { return "Window is on another desktop" }
        if !isOnCurrentSpace { return "Window desktop is unknown" }
        return nil
    }

    var displayName: String {
        windowTitle.isEmpty ? ownerName : windowTitle
    }
    
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, ownerPID, ownerName, windowTitle, bounds, isOnCurrentSpace, windowNumber, isMinimized, isHidden, isOnOtherSpace
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CGWindowID.self, forKey: .id)
        ownerPID = try container.decode(pid_t.self, forKey: .ownerPID)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        windowTitle = try container.decode(String.self, forKey: .windowTitle)
        
        let boundsDict = try container.decode([String: CGFloat].self, forKey: .bounds)
        bounds = CGRect(
            x: boundsDict["x"] ?? 0,
            y: boundsDict["y"] ?? 0,
            width: boundsDict["width"] ?? 0,
            height: boundsDict["height"] ?? 0
        )
        
        isOnCurrentSpace = try container.decode(Bool.self, forKey: .isOnCurrentSpace)
        windowNumber = try container.decode(Int.self, forKey: .windowNumber)
        isMinimized = try container.decodeIfPresent(Bool.self, forKey: .isMinimized) ?? !isOnCurrentSpace
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        isOnOtherSpace = try container.decodeIfPresent(Bool.self, forKey: .isOnOtherSpace) ?? false
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ownerPID, forKey: .ownerPID)
        try container.encode(ownerName, forKey: .ownerName)
        try container.encode(windowTitle, forKey: .windowTitle)
        
        let boundsDict = [
            "x": bounds.origin.x,
            "y": bounds.origin.y,
            "width": bounds.size.width,
            "height": bounds.size.height
        ]
        try container.encode(boundsDict, forKey: .bounds)
        
        try container.encode(isOnCurrentSpace, forKey: .isOnCurrentSpace)
        try container.encode(windowNumber, forKey: .windowNumber)
        try container.encode(isMinimized, forKey: .isMinimized)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encode(isOnOtherSpace, forKey: .isOnOtherSpace)
    }
    
    init(
        id: CGWindowID,
        ownerPID: pid_t,
        ownerName: String,
        windowTitle: String,
        bounds: CGRect,
        isOnCurrentSpace: Bool,
        windowNumber: Int,
        isMinimized: Bool = false,
        isHidden: Bool = false,
        isOnOtherSpace: Bool = false
    ) {
        self.id = id
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.windowTitle = windowTitle
        self.bounds = bounds
        self.isOnCurrentSpace = isOnCurrentSpace
        self.windowNumber = windowNumber
        self.isMinimized = isMinimized
        self.isHidden = isHidden
        self.isOnOtherSpace = isOnOtherSpace
    }
}

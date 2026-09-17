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
        case id, ownerPID, ownerName, windowTitle, bounds, isOnCurrentSpace, windowNumber
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
    }
    
    init(
        id: CGWindowID,
        ownerPID: pid_t,
        ownerName: String,
        windowTitle: String,
        bounds: CGRect,
        isOnCurrentSpace: Bool,
        windowNumber: Int
    ) {
        self.id = id
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.windowTitle = windowTitle
        self.bounds = bounds
        self.isOnCurrentSpace = isOnCurrentSpace
        self.windowNumber = windowNumber
    }
}

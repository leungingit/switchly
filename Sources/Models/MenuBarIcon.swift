//
//  MenuBarIcon.swift
//  Switchly
//
//  Selectable menu bar glyphs. All are SF Symbols rendered as template
//  images, so the system tints them for light / dark menu bars.
//

import Foundation

enum MenuBarIcon: String, Codable, CaseIterable, Hashable {
    case squareOnSquare = "square.on.square"
    case rectangleOnRectangle = "rectangle.on.rectangle"
    case rectangleStack = "rectangle.stack"
    case rectangleGroup = "rectangle.3.group"
    case macwindow = "macwindow"
    case grid = "square.grid.2x2"

    var symbolName: String { rawValue }
}

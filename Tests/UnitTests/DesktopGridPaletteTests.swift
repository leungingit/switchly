import AppKit
import SwiftUI
import XCTest
@testable import Switchly

final class DesktopGridPaletteTests: XCTestCase {

    func testAppPaletteKeepsWhiteTextReadable() {
        XCTAssertEqual(DesignTokens.Grid.appPalette.count, 8)
        for color in DesignTokens.Grid.appPalette {
            XCTAssertGreaterThanOrEqual(contrast(rgba(color), (1, 1, 1)), 4.5)
        }
    }

    func testStatusColoursReadOnWhite() {
        for color in [DesignTokens.Grid.Status.ok, DesignTokens.Grid.Status.warn, DesignTokens.Grid.Status.bad] {
            XCTAssertGreaterThanOrEqual(contrast(rgba(color), (1, 1, 1)), 4.5)
        }
    }

    /// 窗口色必须按绘制视图自身的外观解析，而不是 App 级外观。
    func testWindowColoursFollowDrawingAppearance() {
        let light = rgba(DesignTokens.Grid.Window.background, appearance: .aqua)
        let dark = rgba(DesignTokens.Grid.Window.background, appearance: .darkAqua)
        XCTAssertGreaterThan(luminance(light), 0.9)
        XCTAssertLessThan(luminance(dark), 0.05)

        let lightText = rgba(DesignTokens.Grid.Window.text, appearance: .aqua)
        let darkText = rgba(DesignTokens.Grid.Window.text, appearance: .darkAqua)
        XCTAssertGreaterThanOrEqual(contrast(lightText, light), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(darkText, dark), 4.5)
    }

    func testWallsAreNeutralNotPurpleBlue() {
        for color in DesignTokens.Grid.Wall.cream + DesignTokens.Grid.Wall.white + DesignTokens.Grid.Wall.graphite {
            let c = rgba(color)
            XCTAssertLessThanOrEqual(c.2 - min(c.0, c.1), 0.04, "背景不得偏紫蓝（D10）")
        }
    }

    // MARK: - Helpers

    private typealias RGB = (Double, Double, Double)

    private func rgba(_ color: Color, appearance name: NSAppearance.Name = .aqua) -> RGB {
        var out: RGB = (0, 0, 0)
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            out = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        return out
    }

    private func luminance(_ c: RGB) -> Double {
        func ch(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.0) + 0.7152 * ch(c.1) + 0.0722 * ch(c.2)
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

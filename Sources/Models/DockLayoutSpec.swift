//
//  DockLayoutSpec.swift
//  Switchly
//
//  How the Dock preview arranges one app's window cards. The panel renders
//  and sizes itself from a DockLayoutSpec only; DockPreviewLayout is just the
//  user-facing preset list that maps onto it.
//

import CoreGraphics
import Foundation

/// Built-in Dock preview arrangements the user can pick in Preferences.
enum DockPreviewLayout: String, Codable, CaseIterable, Hashable {
    /// Historical behaviour: one row, scrolling sideways.
    case horizontal
    /// One column, scrolling vertically.
    case vertical
    /// Wrapped rows of `DockLayoutSpec.gridColumns`, scrolling vertically.
    case grid

    /// Localization key for the Preferences picker.
    var title: String {
        switch self {
        case .horizontal: return "Layout Horizontal"
        case .vertical: return "Layout Vertical"
        case .grid: return "Layout Grid"
        }
    }

    var spec: DockLayoutSpec {
        switch self {
        case .horizontal: return DockLayoutSpec(axis: .horizontal)
        case .vertical: return DockLayoutSpec(axis: .vertical)
        case .grid: return DockLayoutSpec(axis: .vertical, lanes: DockLayoutSpec.gridColumns)
        }
    }

    /// Falls back to the historical row so an unknown stored value never
    /// changes what the user sees.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DockPreviewLayout(rawValue: raw) ?? .horizontal
    }
}

/// Parameters that fully describe a card arrangement.
struct DockLayoutSpec: Equatable {
    enum Axis: Equatable {
        /// Cards flow left to right in a single row.
        case horizontal
        /// Cards fill `lanes` columns top to bottom.
        case vertical
    }

    static let gridColumns = 3

    let axis: Axis
    /// Columns for the vertical axis. The horizontal axis is always one row.
    let lanes: Int
    let spacing: CGFloat

    init(axis: Axis, lanes: Int = 1, spacing: CGFloat = 10) {
        self.axis = axis
        self.lanes = axis == .horizontal ? 1 : max(lanes, 1)
        self.spacing = spacing
    }

    /// Columns actually used for `count` cards (never more than the cards).
    func columns(for count: Int) -> Int {
        axis == .horizontal ? max(count, 1) : max(min(lanes, count), 1)
    }
}

/// Panel sizing for a Dock preview layout. Pure so it can be unit tested.
enum DockPanelMetrics {
    static let headerHeight: CGFloat = 40
    static let cardPadding: CGFloat = 12        // 6 + 6 around each card
    static let labelAllowance: CGFloat = 26     // spacing + title line
    static let stripHorizontalInset: CGFloat = 24 // 12 + 12
    static let stripVerticalInset: CGFloat = 20   // 10 + 10
    static let emptyWidth: CGFloat = 200
    static let screenMargin: CGFloat = 96       // 48 each side

    static func cardSize(cardWidth: CGFloat) -> CGSize {
        CGSize(width: cardWidth + cardPadding,
               height: cardWidth * 0.625 + cardPadding + labelAllowance)
    }

    /// Size of the whole panel, clamped to `visibleSize` minus a margin.
    static func panelSize(spec: DockLayoutSpec, count: Int, cardWidth: CGFloat, visibleSize: CGSize) -> CGSize {
        let card = cardSize(cardWidth: cardWidth)
        let maxWidth = visibleSize.width - screenMargin
        let maxHeight = visibleSize.height - screenMargin

        guard count > 0 else {
            return CGSize(width: emptyWidth, height: headerHeight + stripVerticalInset + card.height)
        }

        let columns = spec.columns(for: count)
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let contentWidth = CGFloat(columns) * card.width + CGFloat(columns - 1) * spec.spacing + stripHorizontalInset
        let contentHeight = CGFloat(rows) * card.height + CGFloat(rows - 1) * spec.spacing + stripVerticalInset
        return CGSize(width: min(maxWidth, contentWidth),
                      height: min(maxHeight, headerHeight + contentHeight))
    }
}

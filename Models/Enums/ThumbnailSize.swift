//
//  ThumbnailSize.swift
//  Switchly
//
//  Thumbnail size enumeration
//

import Foundation
import CoreGraphics

enum ThumbnailSize: String, Codable, CaseIterable, Hashable {
    case small = "small"
    case medium = "medium"
    case large = "large"
    
    var displayName: String {
        displayName(language: .english)
    }

    func displayName(language: AppLanguage) -> String {
        switch self {
        case .small:
            return language.localizedString("Small")
        case .medium:
            return language.localizedString("Medium")
        case .large:
            return language.localizedString("Large")
        }
    }
    
    /// Logical size in points. Drives SwiftUI layout, and is also the value
    /// views hand to `ThumbnailService` — the service converts it to real
    /// bitmap pixels using the display scale.
    ///
    /// Kept in points (not pixels) on purpose: it is consumed directly by
    /// `previewThumbnailHeight` and by the card layout, and existing tests
    /// assert the point values.
    var dimensions: CGSize {
        switch self {
        case .small:
            return CGSize(width: 160, height: 100)
        case .medium:
            return CGSize(width: 200, height: 125)
        case .large:
            return CGSize(width: 240, height: 150)
        }
    }

    /// Real bitmap size in pixels. A thumbnail bitmap must be captured at the
    /// display's pixel scale, otherwise every card loses half its sharpness on
    /// a 2x screen (a 240x150 point card would hold a 240x150 pixel bitmap).
    func pixelDimensions(scale: CGFloat) -> CGSize {
        let scale = scale > 0 ? scale : 1
        return CGSize(
            width: (dimensions.width * scale).rounded(),
            height: (dimensions.height * scale).rounded()
        )
    }

    var previewCardMinWidth: CGFloat {
        dimensions.width + 24
    }

    var previewCardMaxWidth: CGFloat {
        dimensions.width + 40
    }

    var previewThumbnailHeight: CGFloat {
        dimensions.height
    }
}

/// Cache tier for window thumbnails.
///
/// Resolution is a property of the cached entry: a window needs a small bitmap
/// for a grid tile and a native one for the enlarged preview. The tier is part
/// of the cache key, so adding another tier later is a new case here and
/// nothing else.
///
/// The `hero` tier this enum used to carry is gone with the large-preview pane
/// that read it: the merged mode replays the window at its own size instead
/// (docs/plan/2026-09-28-preview-panel-live-switch.md §15), so nothing ever
/// captured or read that tier any more.
enum ThumbnailTier: String, CaseIterable, Hashable {
    /// Grid / list thumbnails. Size comes from `AppSettings.thumbnailSize`.
    case grid
    /// The window at its own size, in display pixels — what the window replica
    /// replays. It is captured at the window's point size times the display
    /// scale, so drawing it into a window-sized frame is 1:1.
    case native

    var displayName: String {
        switch self {
        case .grid:
            return "Grid"
        case .native:
            return "Native"
        }
    }

    /// Hard cap on the bitmap this tier may hold, in pixels. Nil means "only
    /// bounded by what the display can produce".
    ///
    /// The cap exists so a tier's envelope cannot be blown by an extreme
    /// request:
    ///
    /// - native holds one entry inside a 128 MB budget. A window the size of the
    ///   largest display that exists today (6K XDR, 6016x3384 pt) is 325 MB at
    ///   2x — three times the budget, so without a cap that entry would evict
    ///   itself on the very store that created it and the replica would never
    ///   keep an image. Capping at 6016x3384 px (77.7 MB) leaves the real cases
    ///   (a maximized window on a 1080p or 4K display) fully native and trades
    ///   only sharpness on a 6K display, where the native bitmap does not fit
    ///   the budget at all.
    /// - grid is bounded by what `AppSettings.thumbnailSize` asks for (240x150 pt
    ///   at the largest), so it needs no cap.
    var maxPixelSize: CGSize? {
        switch self {
        case .grid:
            return nil
        case .native:
            return CGSize(width: 6016, height: 3384)
        }
    }
}

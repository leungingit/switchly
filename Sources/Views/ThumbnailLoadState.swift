//
//  ThumbnailLoadState.swift
//  Switchly
//
//  Shared thumbnail load state for the preview panel and dock cards. Kept
//  standalone so hosts that only draw cards (the plugin preview app) can
//  compile it without the preview panel.
//

import AppKit

enum ThumbnailLoadState: Equatable {
    case loading
    case placeholder(NSImage?)
    case loaded(NSImage)
    case failed(NSImage?)

    /// Identity-based comparison: images are compared by reference so the
    /// animation driver only fires when the state genuinely changes.
    static func == (lhs: ThumbnailLoadState, rhs: ThumbnailLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading):
            return true
        case (.placeholder(let lhsImage), .placeholder(let rhsImage)):
            return lhsImage === rhsImage
        case (.loaded(let lhsImage), .loaded(let rhsImage)):
            return lhsImage === rhsImage
        case (.failed(let lhsImage), .failed(let rhsImage)):
            return lhsImage === rhsImage
        default:
            return false
        }
    }
}

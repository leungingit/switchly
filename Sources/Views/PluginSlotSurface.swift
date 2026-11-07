//
//  PluginSlotSurface.swift
//  Switchly
//
//  Shared plugin-slot presentation used by the Dock preview and the standalone
//  preview tool. Host-specific observation, slot selection and fallbacks stay
//  with their callers; both surfaces route actions back with the owning plugin
//  ID and draw the same native PluginOverlayView with the same assets/material.
//

import AppKit
import SwiftUI

struct PluginSlotSurface: View {
    struct Entry: Identifiable, Equatable {
        let id: String
        let node: PluginUINode
        let assetDirectory: URL?
    }

    let entries: [Entry]
    let material: CrystalMaterial
    let isGlassActive: Bool
    let artwork: NSImage?
    let fallback: AnyView?
    let onAction: (_ pluginID: String, _ actionID: String, _ value: Double?) -> Void

    var body: some View {
        if entries.isEmpty {
            fallback
        } else {
            VStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(entries) { entry in
                    PluginOverlayView(
                        node: entry.node,
                        material: material,
                        isGlassActive: isGlassActive,
                        artwork: artwork,
                        assetDirectory: entry.assetDirectory,
                        pluginID: entry.id,
                        onAction: { onAction(entry.id, $0, $1) }
                    )
                }
            }
            .padding(fallback == nil ? 0 : DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, maxHeight: fallback == nil ? nil : .infinity)
            .transition(.opacity)
        }
    }
}

//
//  PluginActivityImage.swift
//  Switchly
//
//  Activity snapshot references are opaque identifiers. The host injects the
//  resolver that enforces activity permissions; this view never reads a path
//  and never reaches for process-wide image state.
//

import AppKit
import SwiftUI

struct PluginActivityImage: View {
    let reference: String
    let pluginID: String
    let size: PluginControlSize
    let corner: PluginCorner?
    let resolver: PluginActivityImageResolving?

    @State private var image: NSImage?
    @State private var generation = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(Color.primary.opacity(0.08))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: maximumWidth * 0.14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .aspectRatio(DesignTokens.Plugin.activityImageAspectRatio, contentMode: .fit)
        .frame(maxWidth: maximumWidth)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: loadID) {
            generation += 1
            let requestGeneration = generation
            image = nil
            guard let resolver else { return }
            let resolved = await resolver.image(reference: reference, pluginID: pluginID)
            guard !Task.isCancelled, generation == requestGeneration else { return }
            image = resolved
        }
        .onDisappear {
            generation += 1
            image = nil
        }
        .accessibilityHidden(true)
    }

    private var maximumWidth: CGFloat {
        switch size {
        case .s: return DesignTokens.Plugin.activityImageSmallWidth
        case .m: return DesignTokens.Plugin.activityImageMediumWidth
        case .l: return DesignTokens.Plugin.activityImageLargeWidth
        }
    }

    private var radius: CGFloat {
        corner == .m ? DesignTokens.Radius.thumbnail : DesignTokens.Radius.chip
    }

    private var loadID: String {
        "\(pluginID)\u{0}\(reference)"
    }

}

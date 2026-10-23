//
//  GridThumbnailView.swift
//  Switchly
//
//  Miniature desktop preview (design spec §9.1).
//
//  Real window bitmaps come from the injected loader (production plugs in the
//  shared ThumbnailService, so the 24 h / 64 MB disk budget is unchanged).
//  Without Screen Recording the same layout degrades to labelled colour blocks
//  — never an empty white card and never a fake screenshot.
//

import SwiftUI
import AppKit

struct GridThumbnailView: View {
    let desktop: Desktop
    let number: Int
    /// False when Screen Recording is missing.
    let allowsRealCaptures: Bool
    /// Hidden when the thumbnail is narrower than 150 pt (spec §4).
    let showsWindowNames: Bool
    let revision: Int
    let loader: (WindowInfo, CGSize) async -> NSImage?
    let t: (String) -> String

    @Environment(\.colorScheme) private var colorScheme
    @State private var images: [CGWindowID: NSImage] = [:]
    @State private var isLoading = false

    private static let captureSize = CGSize(width: 320, height: 200)

    var body: some View {
        ZStack {
            wallpaper
            menuBarHint

            if desktop.isEmpty {
                Text(t("This desktop is quiet"))
                    .font(DesignTokens.Typography.gridMeta)
                    .foregroundColor(.secondary)
                    .padding(DesignTokens.Spacing.sm)
            } else {
                windowLayers
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail, style: .continuous)
                .strokeBorder(DesignTokens.Grid.Window.edge, lineWidth: DesignTokens.hairline)
        )
        .task(id: "\(revision)-\(allowsRealCaptures)-\(desktop.id)") {
            await loadThumbnails()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Layers

    private var wallpaper: some View {
        LinearGradient(
            colors: DesignTokens.Grid.Wall.thumbnailBase(for: number),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(colorScheme == .dark ? Color.black.opacity(0.46) : Color.clear)
    }

    /// ~7% menu bar strip, as in the design asset spec.
    private var menuBarHint: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color.black.opacity(colorScheme == .dark ? 0.26 : 0.07),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 14)
            .overlay(alignment: .trailing) {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(DesignTokens.Grid.Window.dot)
                            .frame(width: 3, height: 3)
                    }
                }
                .padding(.trailing, 6)
            }
            Spacer(minLength: 0)
        }
    }

    private var windowLayers: some View {
        GeometryReader { geo in
            let size = geo.size
            let visible = Array(desktop.windows.prefix(3))

            ZStack {
                ForEach(Array(layerSpecs(for: visible.count).enumerated()), id: \.offset) { index, spec in
                    if index < visible.count {
                        let window = visible[index]
                        let ratio = min(max(window.bounds.width / max(window.bounds.height, 1), 1.35), 1.55)
                        let blockHeightLimit = max(18, size.height - 6)
                        let blockWidth = min(size.width * spec.widthRatio, blockHeightLimit * 1.35)
                        let blockHeight = blockWidth / ratio
                        let spareX = max(0, (size.width - blockWidth) / 2 - 2)
                        let spareY = max(0, (size.height - blockHeight) / 2 - 2)

                        windowBlock(
                            window: window,
                            image: images[window.id],
                            width: blockWidth,
                            showsName: showsWindowNames,
                            isFront: spec.isFront
                        )
                        .offset(x: spareX * spec.xFactor, y: spareY * spec.yFactor)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .padding(DesignTokens.Spacing.sm)
    }

    private struct LayerSpec {
        let widthRatio: CGFloat
        /// Offset as a fraction of the spare space, so stacked windows never
        /// leave the 6 %–94 % safe area.
        let xFactor: CGFloat
        let yFactor: CGFloat
        let isFront: Bool
    }

    /// Front-to-back order, matching `desktop.windows`.
    private func layerSpecs(for count: Int) -> [LayerSpec] {
        switch count {
        case 1:
            return [LayerSpec(widthRatio: 0.56, xFactor: 0.10, yFactor: 0, isFront: true)]
        case 2:
            return [
                LayerSpec(widthRatio: 0.58, xFactor: 0.30, yFactor: 0.05, isFront: true),
                LayerSpec(widthRatio: 0.46, xFactor: -0.55, yFactor: 0.55, isFront: false),
            ]
        default:
            return [
                LayerSpec(widthRatio: 0.54, xFactor: 0.32, yFactor: 0.16, isFront: true),
                LayerSpec(widthRatio: 0.46, xFactor: -0.60, yFactor: 0.62, isFront: false),
                LayerSpec(widthRatio: 0.40, xFactor: -0.12, yFactor: -0.62, isFront: false),
            ]
        }
    }

    private func windowBlock(
        window: WindowInfo,
        image: NSImage?,
        width: CGFloat,
        showsName: Bool,
        isFront: Bool
    ) -> some View {
        let ratio = min(max(window.bounds.width / max(window.bounds.height, 1), 1.35), 1.55)
        let height = max(18, width / ratio)
        let appColor = DesignTokens.Grid.appColor(for: window.ownerName)

        return VStack(spacing: 0) {
            // A real capture already contains the window's own title bar, so
            // drawing the synthetic one on top would double it. The synthetic
            // bar is for the labelled colour-block fallback and the skeleton.
            if image == nil {
                windowTitleBar(name: window.ownerName, showsName: showsName, appColor: appColor)
            }
            ZStack {
                DesignTokens.Grid.Window.background

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if allowsRealCaptures && isLoading {
                    skeletonLines
                } else {
                    // Screen Recording is off, or the capture failed: a labelled
                    // colour block, not a fake screenshot.
                    LinearGradient(
                        colors: [appColor.opacity(0.88), appColor.opacity(0.66)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .overlay(alignment: .bottomLeading) {
                        if showsName {
                            Text(window.ownerName)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 3)
                        }
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(DesignTokens.Grid.Window.edge, lineWidth: DesignTokens.hairline)
        )
        .shadow(
            color: .black.opacity(isFront ? 0.32 : 0.20),
            radius: isFront ? 9 : 4,
            x: 0,
            y: isFront ? 5 : 2
        )
    }

    private func windowTitleBar(name: String, showsName: Bool, appColor: Color) -> some View {
        HStack(spacing: 2) {
            HStack(spacing: 1.5) {
                Circle().fill(Color(red: 0.95, green: 0.42, blue: 0.38))
                Circle().fill(Color(red: 0.96, green: 0.75, blue: 0.30))
                Circle().fill(Color(red: 0.35, green: 0.78, blue: 0.38))
            }
            .frame(width: 12, height: 3)

            if showsName {
                Text(name)
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundColor(DesignTokens.Grid.Window.text)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 12)
        .background(
            ZStack {
                DesignTokens.Grid.Window.background
                appColor.opacity(0.20)
            }
        )
    }

    private var skeletonLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(DesignTokens.Grid.Window.line).frame(width: 44, height: 3)
            RoundedRectangle(cornerRadius: 2).fill(DesignTokens.Grid.Window.line).frame(width: 60, height: 3)
            RoundedRectangle(cornerRadius: 2).fill(DesignTokens.Grid.Window.line).frame(width: 36, height: 3)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .redacted(reason: .placeholder)
    }

    // MARK: - Loading

    private func loadThumbnails() async {
        guard allowsRealCaptures, !desktop.isEmpty else {
            isLoading = false
            return
        }

        isLoading = images.isEmpty
        var loaded: [CGWindowID: NSImage] = [:]
        for window in desktop.windows.prefix(3) {
            if Task.isCancelled { return }
            if let image = await loader(window, Self.captureSize) {
                loaded[window.id] = image
            }
        }
        guard !Task.isCancelled else { return }
        images = loaded
        isLoading = false
    }

    private var accessibilityLabel: String {
        let name = String(format: t("Desktop %d"), number)
        if desktop.isEmpty {
            return "\(name), \(t("This desktop is quiet"))"
        }
        let windows = String(format: t("%d windows"), desktop.windowCount)
        if allowsRealCaptures {
            return "\(name), \(windows)"
        }
        return "\(name), \(windows), \(t("Desktop preview (illustration)"))"
    }
}

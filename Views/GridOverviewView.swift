//
//  GridOverviewView.swift
//  Switchly
//
//  The 3×3 desktop overview. Two layouts share one information hierarchy:
//  C (perspective grid, default) and B (centred panel).
//  See docs/desktop-grid-design-spec.md §3.1, §4, §5 and §10.
//

import SwiftUI
import AppKit

struct GridOverviewView: View {
    @ObservedObject var viewModel: GridOverviewViewModel

    let thumbnailLoader: (WindowInfo, CGSize) async -> NSImage?
    let openSystemSettings: () -> Void
    let openMissionControl: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var style: GridStyle { viewModel.style }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                glassBase
                wall.opacity(style == .b ? 0.90 : 1)
                content
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: style == .b ? DesignTokens.Radius.panel : 0,
                    style: .continuous
                )
            )
            .overlay(alignment: .center) {
                if style == .b {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                        .strokeBorder(
                            Color.appearanceAware(dark: .white.opacity(0.12), light: .black.opacity(0.06)),
                            lineWidth: DesignTokens.hairline
                        )
                }
            }
            .shadow(
                color: style == .b ? .black.opacity(0.18) : .clear,
                radius: style == .b ? 24 : 0,
                x: 0,
                y: style == .b ? 12 : 0
            )
        }
    }

    // MARK: - Surface

    private var content: some View {
        VStack(spacing: 0) {
            header

            if !viewModel.banners.isEmpty {
                bannerStack
                    .padding(.top, DesignTokens.Spacing.md)
            }

            bodyContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            Text(footerHint)
                .font(DesignTokens.Typography.gridMeta)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.bottom, DesignTokens.Spacing.md)
        }
    }

    private var glassBase: some View {
        Color.clear
            .panelGlass(
                isActive: viewModel.enableGlass,
                opacity: viewModel.glassOpacity,
                cornerRadius: style == .b ? DesignTokens.Radius.panel : 0,
                material: viewModel.material
            )
    }

    private var wall: some View {
        ZStack {
            LinearGradient(
                colors: wallStops,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if colorScheme == .light {
                RadialGradient(
                    colors: [Color.white.opacity(viewModel.background == .cream ? 0.52 : 0.20), .clear],
                    center: UnitPoint(x: 0.18, y: 0.04),
                    startRadius: 0,
                    endRadius: 880
                )
            }
        }
    }

    private var wallStops: [Color] {
        if colorScheme == .dark {
            return DesignTokens.Grid.Wall.graphite
        }
        return viewModel.background == .cream
            ? DesignTokens.Grid.Wall.cream
            : DesignTokens.Grid.Wall.white
    }

    // MARK: - Header

    private var header: some View {
        statusPill
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.top, DesignTokens.Spacing.lg)
    }

    private var statusPill: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(statusTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            if let target = viewModel.targetNumber {
                Text("\u{2303}\(target)")
                    .font(DesignTokens.Typography.gridMeta.monospacedDigit())
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.chip, style: .continuous)
                            .fill(Color.appearanceAware(dark: .white.opacity(0.10), light: .black.opacity(0.05)))
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.appearanceAware(dark: .white.opacity(0.12), light: .white.opacity(0.82)))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    Color.appearanceAware(dark: .white.opacity(0.14), light: .black.opacity(0.06)),
                    lineWidth: DesignTokens.hairline
                )
        )
        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
    }

    private var statusTitle: String {
        if viewModel.snapshot.availability.isUnavailable {
            return t("Desktop Grid")
        }
        guard let current = viewModel.currentNumber else {
            return t("Desktop Grid")
        }
        if let target = viewModel.targetNumber, target != current {
            return String(format: t("Desktop %d → %d"), current, target)
        }
        return String(format: t("Desktop %d"), current)
    }

    // MARK: - Banners

    private var bannerStack: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            if viewModel.banners.spacesUnavailable {
                banner(
                    text: t("Desktop information is unavailable. Try again after the system finishes switching."),
                    actionTitle: nil,
                    action: nil
                )
            }
            if viewModel.banners.accessibilityMissing {
                banner(
                    text: t("Accessibility is off. Window names and switching may be incomplete."),
                    actionTitle: t("Open System Settings"),
                    action: openSystemSettings
                )
            }
            if viewModel.banners.screenRecordingMissing {
                banner(
                    text: t("Screen recording is off, so previews are simplified. Icons and titles are unaffected."),
                    actionTitle: t("Open System Settings"),
                    action: openSystemSettings
                )
            }
            if viewModel.banners.notCreatedCount > 0 {
                banner(
                    text: String(
                        format: t("Only %d desktops exist. macOS creates desktops; use Mission Control to add one."),
                        viewModel.slots.filter(\.isCreated).count
                    ),
                    actionTitle: t("Open Mission Control"),
                    action: openMissionControl
                )
            }
        }
        .frame(maxWidth: 700)
        .padding(.horizontal, DesignTokens.Spacing.xl)
    }

    private func banner(text: String, actionTitle: String?, action: (() -> Void)?) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text(text)
                .font(DesignTokens.Typography.gridMeta)
                .foregroundColor(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: DesignTokens.Spacing.sm)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(DesignTokens.Typography.gridMeta.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule(style: .continuous).fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.appearanceAware(dark: .white.opacity(0.10), light: .white.opacity(0.84)))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    Color.appearanceAware(dark: .white.opacity(0.12), light: .black.opacity(0.05)),
                    lineWidth: DesignTokens.hairline
                )
        )
    }

    // MARK: - Body

    @ViewBuilder
    private var bodyContent: some View {
        if viewModel.isLoading && viewModel.snapshot.desktops.isEmpty {
            VStack(spacing: DesignTokens.Spacing.md) {
                ProgressView()
                Text(t("Loading desktops…"))
                    .font(DesignTokens.Typography.gridMeta)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.snapshot.availability.isUnavailable {
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text(t("Desktop information is unavailable"))
                    .font(DesignTokens.Typography.gridTitle)
                Text(t("Switchly could not read the system desktops. Nothing was changed."))
                    .font(DesignTokens.Typography.gridMeta)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignTokens.Spacing.xl)
        } else if style == .c {
            perspectiveGrid
        } else {
            flatGrid
        }
    }

    /// Style C: the 3×3 perspective grid.
    ///
    /// The grid is laid out at most `styleCMaxWidth` wide and centred, so the
    /// leftover screen width becomes equal left/right margin (the prototype
    /// caps its `.gridwrap` the same way). It is tilted about the horizontal
    /// axis with the shared perspective token, which foreshortens the top row
    /// and pulls the third row in — the direction the prototype shows.
    private var perspectiveGrid: some View {
        GeometryReader { geo in
            let horizontalSpacing = DesignTokens.Spacing.xl
            let verticalSpacing = DesignTokens.Spacing.xl
            let gridWidth = max(320, min(geo.size.width, DesignTokens.Grid.styleCMaxWidth))
            let unitWidth = max(
                1,
                (gridWidth - horizontalSpacing * 2) / DesignTokens.Grid.columnFractions.reduce(0, +)
            )
            let unitHeight = max(
                1,
                (geo.size.height - verticalSpacing * 2) / DesignTokens.Grid.rowFractions.reduce(0, +)
            )

            VStack(spacing: verticalSpacing) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: horizontalSpacing) {
                        ForEach(0..<3, id: \.self) { column in
                            let number = row * 3 + column + 1
                            let width = unitWidth * DesignTokens.Grid.columnFractions[column]
                            cell(number: number, width: width)
                                .frame(
                                    width: width,
                                    height: unitHeight * DesignTokens.Grid.rowFractions[row]
                                )
                        }
                    }
                }
            }
            .frame(width: gridWidth, height: geo.size.height)
            .rotation3DEffect(
                .degrees(DesignTokens.Grid.tilt),
                axis: (x: 1, y: 0, z: 0),
                anchor: .center,
                perspective: DesignTokens.Grid.perspective
            )
            .scaleEffect(DesignTokens.Grid.overviewScale)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 56)
        .padding(.top, DesignTokens.Spacing.xl)
        .padding(.bottom, DesignTokens.Spacing.lg)
        .clipped()
    }

    private var flatGrid: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: DesignTokens.Spacing.md) {
                    ForEach(0..<3, id: \.self) { column in
                        cell(number: row * 3 + column + 1, width: DesignTokens.Grid.styleBMaxWidth / 3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: DesignTokens.Grid.styleBCellHeight)
            }
        }
        .frame(maxWidth: DesignTokens.Grid.styleBMaxWidth)
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.top, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// `number` is the 1-based grid position; the slot carries the real
    /// desktop number placed there by the user's layout.
    private func cell(number position: Int, width: CGFloat) -> some View {
        let slot = viewModel.slots.indices.contains(position - 1)
            ? viewModel.slots[position - 1]
            : DesktopGridSlot(number: position, desktop: nil)
        let number = slot.number

        return GridCellView(
            slot: slot,
            isTarget: viewModel.targetNumber == number,
            isFocused: viewModel.selectedNumber == number,
            style: style,
            // T22: a hidden overview keeps its cells but stops capturing. The
            // thumbnail task is keyed by this flag, so hiding cancels the
            // in-flight load instead of finishing a screenshot nobody sees.
            allowsRealCaptures: viewModel.shouldCaptureThumbnails,
            thumbnailRevision: viewModel.thumbnailRevision,
            thumbnailLoader: thumbnailLoader,
            showsAppIcons: width >= 220,
            cellWidth: width,
            language: viewModel.language,
            material: viewModel.material,
            onTap: { viewModel.selectAndActivate(number) }
        )
        // Drag feedback: the source dims, the swap target gets the accent
        // ring and a slight lift. A static ring needs no motion, so it stays
        // under Reduce Motion.
        .opacity(viewModel.draggingPosition == position - 1 ? 0.45 : 1)
        .overlay(dropHighlight(isTarget: viewModel.dropTargetPosition == position - 1))
        .animation(MotionTokens.animated(MotionTokens.microSpring), value: viewModel.dropTargetPosition)
        .onHover { hovering in
            // A cancelled drag never reports its end; the first hover after
            // the button is released clears the stale dimming.
            if hovering, viewModel.draggingPosition != nil, NSEvent.pressedMouseButtons & 1 == 0 {
                viewModel.endDrag()
            }
        }
        .onDrag {
            viewModel.beginDrag(position - 1)
            return NSItemProvider(object: String(position - 1) as NSString)
        }
        .onDrop(of: [.plainText], delegate: GridCellDropDelegate(position: position - 1, viewModel: viewModel))
    }

    @ViewBuilder
    private func dropHighlight(isTarget: Bool) -> some View {
        if isTarget {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card + 4, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                .allowsHitTesting(false)
        }
    }

    // MARK: - Copy

    private var footerHint: String {
        t("⌃1–9 to jump directly") + " · " + t("←→↑↓ to move · Return to switch · Esc to close")
            + " · " + t("Tab moves between cells")
    }

    private func t(_ key: String) -> String {
        viewModel.language.localizedString(key)
    }
}

/// Drop target for one grid position: reports the hover for the highlight and
/// swaps the dragged card with this one on drop.
private struct GridCellDropDelegate: DropDelegate {
    let position: Int
    let viewModel: GridOverviewViewModel

    func validateDrop(info: DropInfo) -> Bool {
        viewModel.draggingPosition != nil
    }

    func dropEntered(info: DropInfo) {
        guard let source = viewModel.draggingPosition, source != position else { return }
        viewModel.setDropTarget(position)
    }

    func dropExited(info: DropInfo) {
        if viewModel.dropTargetPosition == position { viewModel.setDropTarget(nil) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let source = viewModel.draggingPosition else { return false }
        viewModel.swapPositions(source, position)
        return true
    }
}

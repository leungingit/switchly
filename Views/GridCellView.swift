//
//  GridCellView.swift
//  Switchly
//
//  One desktop card: number, name, key chip, state chip, thumbnail, app icon
//  row and window count (design spec §3.1, §10).
//

import SwiftUI
import AppKit

struct GridCellView: View {
    let slot: DesktopGridSlot
    let isTarget: Bool
    /// True for the keyboard selection, which also drives the target ring.
    /// Kept separate from `isTarget` so a selected current desktop still shows
    /// a focus ring (T21).
    let isFocused: Bool
    let style: GridStyle
    let allowsRealCaptures: Bool
    let thumbnailRevision: Int
    let thumbnailLoader: (WindowInfo, CGSize) async -> NSImage?
    let showsAppIcons: Bool
    let cellWidth: CGFloat
    let language: AppLanguage
    let material: CrystalMaterial
    let onTap: () -> Void

    @State private var isHovered = false

    private var number: Int { slot.number }
    private var desktop: Desktop? { slot.desktop }
    private var isCurrent: Bool { slot.isCurrent }
    private var isCreated: Bool { slot.isCreated }

    var body: some View {
        Group {
            if let desktop {
                createdCell(desktop)
            } else {
                notCreatedCell
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
        .overlay(cardBorder)
        .overlay(focusRing)
        .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: 5)
        .offset(y: isHovered && style == .c ? -DesignTokens.Grid.hoverLift : 0)
        .scaleEffect(isTarget ? DesignTokens.Grid.targetScale : 1)
        .animation(MotionTokens.animated(MotionTokens.microSpring), value: isHovered)
        .animation(
            MotionTokens.animated(.easeOut(duration: MotionTokens.morphDuration)),
            value: isTarget
        )
        .animation(
            MotionTokens.animated(.easeOut(duration: MotionTokens.morphDuration)),
            value: isCurrent
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Text(language.localizedString("Press Return to switch to this desktop.")))
    }

    /// Visible keyboard focus. Drawn outside the card so it never hides the
    /// current/target ring, and kept under Reduce Motion because a static ring
    /// is not movement (T21).
    private var focusRing: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.card + 4, style: .continuous)
            .strokeBorder(
                Color.accentColor,
                style: StrokeStyle(lineWidth: isFocused ? 3 : 0)
            )
            .padding(-4)
            .opacity(isFocused ? 1 : 0)
            .accessibilityHidden(true)
    }

    // MARK: - Created desktop

    private func createdCell(_ desktop: Desktop) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            header

            GridThumbnailView(
                desktop: desktop,
                number: number,
                allowsRealCaptures: allowsRealCaptures,
                showsWindowNames: cellWidth > 150,
                revision: thumbnailRevision,
                loader: thumbnailLoader,
                t: t
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            footer(desktop)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Text("\(number)")
                .font(DesignTokens.Typography.gridNumber)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(String(format: t("Desktop %d"), number))
                .font(DesignTokens.Typography.gridCard)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: DesignTokens.Spacing.xs)

            HStack(spacing: DesignTokens.Spacing.xs) {
                if isCurrent {
                    stateChip(
                        text: t("Current"),
                        filled: true
                    )
                } else if isTarget {
                    stateChip(
                        text: "↘ \(t("Target"))",
                        filled: false
                    )
                }

                keyChip
            }
        }
    }

    private var keyChip: some View {
        Text("\u{2303}\(number)")
            .font(DesignTokens.Typography.gridMeta.monospacedDigit())
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.chip, style: .continuous)
                    .fill(Color.appearanceAware(dark: .white.opacity(0.10), light: .black.opacity(0.06)))
            )
    }

    private func stateChip(text: String, filled: Bool) -> some View {
        Text(text)
            .font(DesignTokens.Typography.gridMeta.weight(.semibold))
            .foregroundColor(filled ? Color.white : Color.accentColor)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.chip, style: .continuous)
                    .fill(filled ? Color.accentColor : Color.accentColor.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.chip, style: .continuous)
                    .strokeBorder(
                        filled ? Color.clear : Color.accentColor.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1, dash: filled ? [] : [3, 2])
                    )
            )
    }

    private func footer(_ desktop: Desktop) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            if showsAppIcons && !desktop.isEmpty {
                appIcons(for: desktop)
            }

            Spacer(minLength: DesignTokens.Spacing.xs)

            Text(String(format: t("%d windows"), desktop.windowCount))
                .font(DesignTokens.Typography.gridMeta)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(height: 18)
    }

    private func appIcons(for desktop: Desktop) -> some View {
        let owners = desktop.appOwners(limit: 4)
        return HStack(spacing: DesignTokens.Spacing.xs) {
            ForEach(owners.owners) { owner in
                appIcon(owner)
            }
            if owners.total > owners.owners.count {
                Text("+\(owners.total - owners.owners.count)")
                    .font(DesignTokens.Typography.gridMeta)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func appIcon(_ owner: DesktopAppOwner) -> some View {
        if let icon = AppIconCache.icon(forPID: owner.pid) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: DesignTokens.hairline)
                )
                .accessibilityLabel(owner.name.isEmpty ? t("Unknown application") : owner.name)
        } else {
            letterBlock(owner)
        }
    }

    private func letterBlock(_ owner: DesktopAppOwner) -> some View {
        let color = DesignTokens.Grid.appColor(for: owner.name)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [color, color.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 18, height: 18)
            .overlay(
                Text(owner.initial.isEmpty ? "?" : owner.initial)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: DesignTokens.hairline)
            )
            .accessibilityLabel(owner.name.isEmpty ? t("Unknown application") : owner.name)
    }

    // MARK: - Not created

    private var notCreatedCell: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text("\(number)")
                .font(DesignTokens.Typography.gridNumber)
                .foregroundColor(.secondary.opacity(0.55))
                .minimumScaleFactor(0.6)

            Text(t("Desktop not created"))
                .font(DesignTokens.Typography.gridCard)
                .foregroundColor(.secondary)

            Text(t("Open Mission Control and click + to add a desktop."))
                .font(DesignTokens.Typography.gridMeta)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chrome

    private var cardBackground: some View {
        var cardMaterial = material
        // The shared crystal sheen is tuned for small glass cards; at this
        // card size it paints a grey band across the top and fights the
        // wallpaper. Keep the material's tint/rim identity, drop the sheen.
        cardMaterial.topSheenOpacity = 0

        let accentTint: Color = isCurrent
            ? Color.accentColor.opacity(0.06)
            : (isTarget ? Color.accentColor.opacity(0.04) : .clear)

        return Color.clear
            .cardSurface(
                fill: Color.appearanceAware(
                    dark: .white.opacity(isCreated ? (isCurrent ? 0.10 : 0.07) : 0.02),
                    light: .white.opacity(isCreated ? (isCurrent ? 0.90 : 0.76) : 0.28)
                ),
                cornerRadius: DesignTokens.Radius.card,
                material: cardMaterial
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                    .fill(accentTint)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
    }

    @ViewBuilder
    private var cardBorder: some View {
        if isCurrent {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2.5)
        } else if isTarget {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .strokeBorder(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 1.8, dash: [5, 4])
                )
        } else if !isCreated {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .strokeBorder(
                    Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
        } else {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .strokeBorder(DesignTokens.Grid.Window.edge, lineWidth: DesignTokens.hairline)
        }
    }

    private var shadowColor: Color {
        if isCurrent { return Color.accentColor.opacity(0.20) }
        if isTarget { return Color.accentColor.opacity(0.14) }
        return .black.opacity(0.10)
    }

    private var shadowRadius: CGFloat {
        isCurrent || isTarget ? 16 : 10
    }

    /// "Desktop 5, Current" — number + name + state, in that order (design
    /// spec §11, T21). Desktops have no user-editable alias yet, so the name
    /// is "Desktop N" and the label does not repeat it; when aliases land the
    /// name slot is already in the middle of this sentence.
    private var accessibilityLabel: String {
        var parts = [desktopName]
        if desktop == nil {
            parts.append(t("Desktop not created"))
        }
        if isCurrent { parts.append(t("Current")) }
        if isTarget { parts.append(t("Target")) }
        return parts.joined(separator: ", ")
    }

    private var accessibilityValue: String {
        guard let desktop else { return "" }
        if desktop.isEmpty { return t("This desktop is quiet") }
        return String(format: t("%d windows"), desktop.windowCount)
    }

    private var desktopName: String {
        String(format: t("Desktop %d"), number)
    }

    private func t(_ key: String) -> String {
        language.localizedString(key)
    }
}

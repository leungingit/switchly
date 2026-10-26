//
//  GridHUDView.swift
//  Switchly
//
//  The gesture HUD: glass pill with a direction ring, "current → target",
//  the gesture/keyboard hint and a 3×3 mini map (design spec §3.2, §10).
//
//  Reuses the shared crystal material and tokens; no bespoke blur or colour.
//

import SwiftUI
import AppKit

struct GridHUDView: View {
    @ObservedObject var viewModel: GridHUDViewModel

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            directionRing
            textBlock
            if viewModel.currentNumber != nil {
                miniMap
            }
        }
        .padding(.leading, DesignTokens.Spacing.md)
        .padding(.trailing, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(
            Color.clear.panelGlass(
                isActive: viewModel.enableGlass,
                opacity: viewModel.glassOpacity,
                cornerRadius: DesignTokens.Radius.panel,
                material: viewModel.material
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                .strokeBorder(
                    warningRingColor,
                    lineWidth: viewModel.phase?.isWarning == true ? 2 : DesignTokens.hairline
                )
        )
        .crystalSpecularRim(
            cornerRadius: DesignTokens.Radius.panel,
            material: viewModel.material
        )
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        .frame(maxWidth: DesignTokens.Grid.HUD.maxWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Ring

    private var directionRing: some View {
        ZStack {
            Circle()
                .fill(Color.appearanceAware(dark: .white.opacity(0.10), light: .black.opacity(0.08)))

            ForEach(SwipeDirection.allCases, id: \.self) { direction in
                ringDot(direction)
            }

            if viewModel.arrowSymbol.isEmpty {
                Image(systemName: warningSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(viewModel.phase == .locate ? .primary : warningTint)
            } else {
                Image(systemName: viewModel.arrowSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.primary)
            }
        }
        .frame(width: DesignTokens.Grid.HUD.ringSize, height: DesignTokens.Grid.HUD.ringSize)
    }

    private func ringDot(_ direction: SwipeDirection) -> some View {
        let highlighted = viewModel.isHighlighted(direction)
        // Swipe angles are measured with y up; SwiftUI's y grows downward, so
        // the vertical component is negated (315° = right and down).
        let radians = direction.angleDegrees * .pi / 180
        return Circle()
            .fill(highlighted ? Color.accentColor : Color.secondary.opacity(0.55))
            .frame(
                width: highlighted ? DesignTokens.Grid.HUD.ringDotActive : DesignTokens.Grid.HUD.ringDot,
                height: highlighted ? DesignTokens.Grid.HUD.ringDotActive : DesignTokens.Grid.HUD.ringDot
            )
            .overlay(
                Circle().strokeBorder(
                    highlighted ? Color.white.opacity(0.9) : Color.clear,
                    lineWidth: 2
                )
            )
            .offset(
                x: CGFloat(cos(radians)) * DesignTokens.Grid.HUD.ringDotRadius,
                y: -CGFloat(sin(radians)) * DesignTokens.Grid.HUD.ringDotRadius
            )
    }

    // MARK: - Text

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(viewModel.headline)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(viewModel.subtitle)
                .font(DesignTokens.Typography.gridMeta)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let hint = viewModel.gestureHint {
                Text(hint)
                    .font(DesignTokens.Typography.gridMeta)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    // MARK: - Mini map

    private var miniMap: some View {
        VStack(spacing: DesignTokens.Grid.HUD.miniGap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: DesignTokens.Grid.HUD.miniGap) {
                    ForEach(0..<3, id: \.self) { column in
                        miniCell(number: viewModel.layout[row * 3 + column])
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func miniCell(number: Int) -> some View {
        let state = viewModel.miniState(for: number)
        return Text("\(number)")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(foreground(for: state))
            .frame(
                width: DesignTokens.Grid.HUD.miniCell,
                height: DesignTokens.Grid.HUD.miniCell
            )
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fill(for: state))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        stroke(for: state),
                        style: StrokeStyle(lineWidth: 1.5, dash: state == .target ? [3, 2] : [])
                    )
            )
    }

    private func fill(for state: GridHUDMiniState) -> Color {
        switch state {
        case .current: return .accentColor
        case .target, .missing: return .clear
        case .plain: return Color.appearanceAware(dark: .white.opacity(0.12), light: .black.opacity(0.10))
        }
    }

    private func stroke(for state: GridHUDMiniState) -> Color {
        switch state {
        case .target: return .accentColor
        case .missing: return Color.secondary.opacity(0.45)
        default: return .clear
        }
    }

    private func foreground(for state: GridHUDMiniState) -> Color {
        switch state {
        case .current: return .white
        case .target: return .accentColor
        default: return .secondary
        }
    }

    // MARK: - State decoration

    private var warningRingColor: Color {
        viewModel.phase?.isWarning == true
            ? DesignTokens.Grid.Status.warn.opacity(0.85)
            : Color.appearanceAware(dark: .white.opacity(0.14), light: .black.opacity(0.06))
    }

    private var warningTint: Color {
        DesignTokens.Grid.Status.warn
    }

    private var warningSymbol: String {
        switch viewModel.phase {
        case .edge: return "nosign"
        case .coolingDown: return "hourglass"
        case .notCreated: return "questionmark.square.dashed"
        case .accessibilityMissing: return "lock"
        case .spacesUnavailable, .failed: return "exclamationmark.triangle"
        case .locate: return "mappin.and.ellipse"
        case .switching, .none: return "arrow.up.arrow.down"
        }
    }

    private var accessibilityText: String {
        [viewModel.headline, viewModel.subtitle, viewModel.gestureHint]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

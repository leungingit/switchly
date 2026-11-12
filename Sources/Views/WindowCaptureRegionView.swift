import AppKit
import SwiftUI

/// 与源窗口同大小、同位置的冻结图；操作栏由独立面板承载，不挤压图像。
struct WindowCaptureRegionView: View {
    @ObservedObject var model: WindowCaptureSessionModel
    let cancel: () -> Void
    @State private var selection: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let pixels = CGSize(width: model.image.width, height: model.image.height)
            ZStack(alignment: .topLeading) {
                Image(decorative: model.image, scale: 1).resizable().interpolation(.high)
                    .frame(width: rect.width, height: rect.height)
                if let selection, let crop = model.regionSelection {
                    Rectangle().stroke(Color.accentColor, lineWidth: DesignTokens.hairline * 4)
                        .frame(width: selection.width, height: selection.height)
                        .offset(x: selection.minX, y: selection.minY)
                    Text("\(Int(crop.width)) × \(Int(crop.height))")
                        .font(.caption.monospacedDigit()).padding(DesignTokens.Spacing.xs)
                        .background(.regularMaterial)
                        .offset(x: selection.minX, y: max(0, selection.minY - DesignTokens.Spacing.xl))
                }
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        let raw = CGRect(x: min(value.startLocation.x, value.location.x),
                                         y: min(value.startLocation.y, value.location.y),
                                         width: abs(value.location.x - value.startLocation.x),
                                         height: abs(value.location.y - value.startLocation.y))
                        let clipped = raw.intersection(rect)
                        selection = clipped.isNull ? nil : clipped
                        model.regionSelection = WindowCaptureGeometry.pixelRect(selection: raw, imageRect: rect, pixels: pixels)
                    })
                    .accessibilityLabel(Text(model.t("Screenshot selection area")))
            }
            .background(HStack {
                Button(model.t("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(model.t("Crop selection")) { if let rect = model.regionSelection { model.crop(rect) } }
                    .keyboardShortcut(.defaultAction).disabled(model.regionSelection == nil)
            }.hidden())
            .onAppear { model.regionSelection = nil }
        }
    }
}

struct WindowCaptureRegionToolbar: View {
    @ObservedObject var model: WindowCaptureSessionModel
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Text(model.t("Drag to select an area, then press Return to crop. Escape cancels."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(model.t("Cancel"), action: cancel)
            Button(model.t("Crop selection")) { if let rect = model.regionSelection { model.crop(rect) } }
                .disabled(model.regionSelection == nil)
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }
}

final class WindowCaptureRegionPanel: NSPanel {
    private let acceptsKeyboard: Bool
    init(frame: CGRect, acceptsKeyboard: Bool) {
        self.acceptsKeyboard = acceptsKeyboard
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false; backgroundColor = .clear
        hasShadow = false; hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

final class WindowCaptureRegionHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

import AppKit
import SwiftUI

struct WindowCaptureView: View {
    @ObservedObject var model: WindowCaptureSessionModel
    let save: () -> Void
    let cancel: () -> Void
    @State private var selection: CGRect?
    @State private var dragOrigin: CGPoint?
    @State private var viewportSize: CGSize = .zero
    @State private var fitsWindow = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            HStack {
                Text(model.t(model.selecting ? "Select an area" : "Window screenshot")).font(.headline)
                Spacer()
                Picker(model.t("Image size"), selection: $fitsWindow) {
                    Text(model.t("Actual size")).tag(false)
                    Text(model.t("Fit to window")).tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                .accessibilityLabel(Text(model.t("Image size")))
                Text("\(model.image.width) × \(model.image.height)").font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            if model.selecting {
                Text(model.t("Drag to select an area, then press Return to crop. Escape cancels."))
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            GeometryReader { proxy in
                let pixels = CGSize(width: model.image.width, height: model.image.height)
                let rect = WindowCaptureGeometry.displayRect(image: pixels, viewport: proxy.size,
                                                            displayScale: displayScale, fitsWindow: fitsWindow)
                let canvas = CGSize(width: max(proxy.size.width, rect.maxX), height: max(proxy.size.height, rect.maxY))
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Color(nsColor: .underPageBackgroundColor)
                        Image(decorative: model.image, scale: 1)
                            .resizable().interpolation(.high)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                        if model.selecting {
                            Color.black.opacity(0.25).allowsHitTesting(false)
                            if let selection, let crop = WindowCaptureGeometry.pixelRect(selection: selection, imageRect: rect, pixels: pixels) {
                                Rectangle().stroke(Color.accentColor, lineWidth: DesignTokens.hairline * 4)
                                    .frame(width: selection.width, height: selection.height)
                                    .offset(x: selection.minX, y: selection.minY)
                                Text("\(Int(crop.width)) × \(Int(crop.height))")
                                    .font(.caption.monospacedDigit()).padding(DesignTokens.Spacing.xs)
                                    .background(.regularMaterial)
                                    .offset(x: min(selection.minX, max(0, proxy.size.width - 100)),
                                            y: max(0, selection.minY - DesignTokens.Spacing.xl))
                            }
                            Color.clear.contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        let origin = dragOrigin ?? value.startLocation
                                        if dragOrigin == nil { dragOrigin = origin }
                                        let raw = CGRect(x: min(origin.x, value.location.x), y: min(origin.y, value.location.y),
                                                         width: abs(value.location.x - origin.x), height: abs(value.location.y - origin.y))
                                        let clipped = raw.intersection(rect)
                                        selection = clipped.isNull ? nil : clipped
                                    }
                                    .onEnded { _ in dragOrigin = nil })
                                .accessibilityLabel(Text(model.t("Screenshot selection area")))
                        }
                    }
                    .frame(width: canvas.width, height: canvas.height)
                }
                .onAppear { viewportSize = proxy.size }
                .onChange(of: proxy.size) { viewportSize = $0; selection = nil; dragOrigin = nil }
                .onChange(of: displayScale) { _ in selection = nil; dragOrigin = nil }
                .onChange(of: fitsWindow) { _ in selection = nil; dragOrigin = nil }
                .onChange(of: model.selecting) { _ in selection = nil; dragOrigin = nil }
                .clipped()
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.chip).stroke(.secondary.opacity(0.3), lineWidth: DesignTokens.hairline))
            }
            if model.editingExternally {
                Text(model.t("Save and close this image in Preview, then reload the saved changes here."))
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.errorKey {
                Label(model.t(error), systemImage: "exclamationmark.triangle")
                    .foregroundColor(.secondary).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button(model.t("Cancel"), action: cancel).keyboardShortcut(.cancelAction).disabled(model.working)
                if model.working { ProgressView().controlSize(.small) }
                Spacer()
                if model.editingExternally {
                    Button(model.t("Saved and closed — reload changes")) { model.reloadEdits() }
                        .disabled(model.working || model.revoked).keyboardShortcut(.defaultAction)
                } else if model.selecting {
                    Button(model.t("Crop selection"), action: confirmCrop)
                        .disabled(selection == nil).keyboardShortcut(.defaultAction)
                } else {
                    Button(model.t("Select again")) { model.reselect() }.disabled(!model.canOutput)
                }
            }
            if !model.editingExternally && !model.selecting {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Spacer()
                    Button(model.t("Edit in Preview")) { model.edit() }.disabled(!model.canOutput)
                    CaptureShareButton(image: model.image, title: model.t("Share"), enabled: model.canOutput) { model.shared() }
                        .fixedSize()
                    Button(model.t("Save…"), action: save).disabled(!model.canOutput).keyboardShortcut("s", modifiers: .command)
                    Button(model.t("Copy")) { model.copy() }.disabled(!model.canOutput).keyboardShortcut("c", modifiers: .command)
                }
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func confirmCrop() {
        let pixels = CGSize(width: model.image.width, height: model.image.height)
        let rect = WindowCaptureGeometry.displayRect(image: pixels, viewport: viewportSize,
                                                    displayScale: displayScale, fitsWindow: fitsWindow)
        guard let selection, let crop = WindowCaptureGeometry.pixelRect(selection: selection, imageRect: rect, pixels: pixels) else { return }
        model.crop(crop)
        self.selection = nil
    }
}

private struct CaptureShareButton: NSViewRepresentable {
    let image: CGImage
    let title: String
    let enabled: Bool
    let completed: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self; button.title = title; button.isEnabled = enabled
    }
    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        var parent: CaptureShareButton
        var picker: NSSharingServicePicker?
        init(_ parent: CaptureShareButton) { self.parent = parent }
        @objc func share(_ sender: NSButton) {
            guard parent.enabled else { return }
            let image = NSImage(cgImage: parent.image, size: NSSize(width: parent.image.width, height: parent.image.height))
            picker = NSSharingServicePicker(items: [image]); picker?.delegate = self
            picker?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? { self }
        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { picker = nil; parent.completed() }
        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { picker = nil }
    }
}

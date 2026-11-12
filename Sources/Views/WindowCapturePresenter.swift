import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WindowCapturePresenter: NSObject, WindowCapturePresenting, NSWindowDelegate {
    private let documents: WindowCaptureDocumentServicing
    private let settings: () -> AppSettings
    private var window: NSWindow?
    private var model: WindowCaptureSessionModel?
    private var finish: (() -> Void)?
    private var closing = false
    private var sourceFrame: CGRect?
    private var selectionWindow: WindowCaptureRegionPanel?
    private var selectionToolbar: WindowCaptureRegionPanel?
    private var selectionSubscription: AnyCancellable?

    init(documents: WindowCaptureDocumentServicing, settings: @escaping () -> AppSettings) {
        self.documents = documents; self.settings = settings
    }

    func present(image: CGImage, mode: WindowCaptureMode, sourceBounds: CGRect? = nil, sessionID: UUID, finished: @escaping () -> Void) {
        let settings = settings()
        let model = WindowCaptureSessionModel(image: image, mode: mode, sessionID: sessionID,
                                             language: settings.language, documents: documents,
                                             openEditor: { url in
            guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
                throw WindowCaptureFailure.windowUnavailable
            }
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        }) { [weak self] in self?.complete() }
        self.model = model; finish = finished
        sourceFrame = sourceBounds.map {
            PreviewReplicaPanel.replicaRect(forWindowBounds: $0,
                                           primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0,
                                           visibleFrame: .zero)
        }
        selectionSubscription = model.$selecting.dropFirst().sink { [weak self, weak model] selecting in
            DispatchQueue.main.async { [weak self, weak model] in
                guard let self, let model, self.model === model else { return }
                self.updateSelection(selecting)
            }
        }
        updateSelection(model.selecting)
    }

    private func updateSelection(_ selecting: Bool) {
        guard let model else { return }
        AppLogger.debug("Window capture presentation changed. selecting=\(selecting) original=\(model.usesOriginalSelectionSource) pixels=\(model.image.width)x\(model.image.height)")
        if selecting, model.usesOriginalSelectionSource, let sourceFrame, sourceFrame.width > 0, sourceFrame.height > 0 {
            window?.orderOut(nil)
            showRegion(model: model, frame: sourceFrame)
        } else {
            closeRegion()
            NSApp.activate(ignoringOtherApps: true)
            if let window { window.makeKeyAndOrderFront(nil) }
            else { showEditor(model: model) }
        }
    }

    private func showEditor(model: WindowCaptureSessionModel) {
        let available = sourceFrame.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let size = NSSize(width: min(available.width, DesignTokens.Capture.windowWidth),
                          height: min(available.height, DesignTokens.Capture.windowHeight))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = model.t("Window screenshot")
        window.isReleasedWhenClosed = false
        var frame = window.frame
        frame.size.width = min(frame.width, available.width)
        frame.size.height = min(frame.height, available.height)
        frame.origin = NSPoint(x: available.midX - frame.width / 2, y: available.midY - frame.height / 2)
        window.setFrame(frame, display: false)
        let minimum = NSSize(width: min(frame.width, DesignTokens.Capture.minimumWidth),
                             height: min(frame.height, DesignTokens.Capture.minimumHeight))
        let minimumContent = window.contentRect(forFrameRect: NSRect(origin: .zero, size: minimum)).size
        window.appearance = NSApp.appearance
        let hosting = NSHostingView(rootView: WindowCaptureView(model: model,
                                                                save: { [weak self] in self?.save() },
                                                                cancel: { [weak self] in self?.requestClose() })
            .frame(minWidth: minimumContent.width, minHeight: minimumContent.height))
        if #available(macOS 13.0, *) { hosting.sizingOptions = [.minSize] }
        window.contentView = hosting
        window.setFrame(frame, display: false)
        window.minSize = minimum
        window.contentMinSize = minimumContent
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func showRegion(model: WindowCaptureSessionModel, frame: CGRect) {
        closeRegion()
        let panel = WindowCaptureRegionPanel(frame: frame, acceptsKeyboard: true)
        panel.title = model.t("Select an area")
        panel.appearance = NSApp.appearance
        let hosting = WindowCaptureRegionHostingView(rootView: WindowCaptureRegionView(model: model,
                                                                     cancel: { [weak self] in self?.requestClose() }))
        // 原位覆盖层必须保持源窗口尺寸，不能被控件的最小布局反向撑大。
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        panel.delegate = self
        selectionWindow = panel

        let available = NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? frame
        let size = CGSize(width: min(available.width, DesignTokens.Capture.selectionToolbarWidth),
                          height: min(available.height, DesignTokens.Capture.selectionToolbarHeight))
        let gap = DesignTokens.Spacing.sm
        let below = frame.minY - size.height - gap
        let y = below >= available.minY ? below : frame.maxY + gap
        let toolbarFrame = CGRect(x: min(max(frame.midX - size.width / 2, available.minX), available.maxX - size.width),
                                  y: min(max(y, available.minY), available.maxY - size.height),
                                  width: size.width, height: size.height)
        let toolbar = WindowCaptureRegionPanel(frame: toolbarFrame, acceptsKeyboard: false)
        toolbar.title = model.t("Select an area")
        toolbar.appearance = NSApp.appearance
        let controls = WindowCaptureRegionHostingView(rootView: WindowCaptureRegionToolbar(model: model,
                                                                          cancel: { [weak self] in self?.requestClose() }))
        if #available(macOS 13.0, *) { controls.sizingOptions = [] }
        toolbar.contentView = controls
        toolbar.setFrame(toolbarFrame, display: false)
        selectionToolbar = toolbar
        panel.makeKeyAndOrderFront(nil)
        toolbar.orderFront(nil)
    }

    private func closeRegion() {
        closing = true
        selectionWindow?.close(); selectionToolbar?.close()
        closing = false
        selectionWindow = nil; selectionToolbar = nil
    }

    func showFailure(_ failure: WindowCaptureFailure) {
        let language = settings().language
        let alert = NSAlert()
        alert.messageText = language.localizedString("Window screenshot")
        alert.informativeText = language.localizedString(failure.messageKey)
        alert.addButton(withTitle: language.localizedString("OK"))
        alert.runModal()
    }

    private func save() {
        guard let model, model.canOutput, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Switchly-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-" )).png"
        panel.beginSheetModal(for: window) { [weak model] response in
            if response == .OK, let url = panel.url { model?.save(to: url) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        requestClose()
        return false
    }

    private func requestClose() {
        guard let model, !model.working else { return }
        guard model.needsEditorCloseConfirmation, let window else { model.close(); return }
        let alert = NSAlert()
        alert.messageText = model.t("Close the image in Preview first")
        alert.informativeText = model.t("Save and close the image in Preview before ending this screenshot. The temporary image will then be deleted.")
        alert.addButton(withTitle: model.t("Keep editing"))
        alert.addButton(withTitle: model.t("Image closed — end screenshot"))
        alert.beginSheetModal(for: window) { [weak model] response in
            if response == .alertSecondButtonReturn { model?.close(editorClosed: true) }
        }
    }

    func interrupt() { model?.interrupt() }

    func abandon() {
        selectionSubscription?.cancel(); selectionSubscription = nil
        model?.abandon()
        closeRegion()
        closing = true; window?.close(); closing = false
        window = nil; model = nil; finish = nil
    }

    private func complete() {
        AppLogger.debug("Window capture presentation completed.")
        selectionSubscription?.cancel(); selectionSubscription = nil
        closeRegion()
        closing = true; window?.close(); closing = false
        window = nil; model = nil
        let callback = finish; finish = nil; callback?()
    }
}

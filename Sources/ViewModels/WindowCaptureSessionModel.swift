import AppKit
import Combine

@MainActor
final class WindowCaptureSessionModel: ObservableObject {
    @Published private(set) var image: CGImage
    @Published private(set) var selecting: Bool
    @Published private(set) var editingExternally = false
    @Published private(set) var working = false
    @Published private(set) var revoked = false
    @Published var errorKey: String?
    let language: AppLanguage
    private let sessionID: UUID
    private let documents: WindowCaptureDocumentServicing
    private let openEditor: (URL) async throws -> Void
    private let finished: () -> Void
    private var task: Task<Void, Never>?
    private var closed = false
    private var editURL: URL?
    private var exporting = false

    init(image: CGImage, mode: WindowCaptureMode, sessionID: UUID, language: AppLanguage,
         documents: WindowCaptureDocumentServicing,
         openEditor: @escaping (URL) async throws -> Void,
         finished: @escaping () -> Void) {
        self.image = image; self.selecting = mode == .region
        self.sessionID = sessionID; self.language = language
        self.documents = documents; self.openEditor = openEditor; self.finished = finished
    }

    var canOutput: Bool { !closed && !selecting && !editingExternally && !working && !revoked }
    var needsEditorCloseConfirmation: Bool { editingExternally }
    func t(_ key: String) -> String { language.localizedString(key) }

    func crop(_ rect: CGRect) {
        guard !closed, selecting, !revoked, let cropped = image.cropping(to: rect) else { return }
        image = cropped; selecting = false
    }

    func edit() {
        guard canOutput else { return }
        working = true; errorKey = nil
        let image = image
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await documents.makeEditingFile(image: image, sessionID: sessionID)
                guard !closed, !revoked else {
                    await documents.cleanup(sessionID: sessionID); working = false
                    if revoked { close(editorClosed: true) }; return
                }
                editURL = url
                // From this point the editor may already own the file, even before its open callback.
                editingExternally = true
                try await openEditor(url)
            } catch {
                editingExternally = false
                errorKey = "Preview could not open the image. Please try again."
                await documents.cleanup(sessionID: sessionID)
                editURL = nil
            }
            working = false
        }
    }

    /// This is an explicit user acknowledgement that the file was saved and closed in Preview.
    func reloadEdits() {
        guard !closed, editingExternally, !working, !revoked, let editURL else { return }
        working = true; errorKey = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let edited = try await documents.loadEditedImage(url: editURL)
                guard !closed, !revoked else { working = false; return }
                image = edited
                editingExternally = false
                self.editURL = nil
                await documents.cleanup(sessionID: sessionID)
            } catch { errorKey = (error as? WindowCaptureFailure)?.messageKey ?? "The saved image could not be read. Save it as PNG and try again." }
            working = false
        }
    }

    func copy() {
        guard canOutput else { return }
        working = true
        exporting = true
        task = Task {
            do {
                try await documents.copy(image: image)
                working = false; exporting = false; close(editorClosed: true)
            } catch {
                working = false; exporting = false
                errorKey = revoked ? WindowCaptureFailure.permissionDenied.messageKey : WindowCaptureFailure.captureFailed.messageKey
            }
        }
    }

    func save(to url: URL) {
        guard canOutput else { return }
        working = true; errorKey = nil
        exporting = true
        let image = image
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await documents.save(image: image, to: url)
                working = false
                exporting = false
                close(editorClosed: true)
            } catch {
                working = false; exporting = false
                errorKey = revoked ? WindowCaptureFailure.permissionDenied.messageKey : "The image could not be saved. Choose another location and try again."
            }
        }
    }

    func shared() { if canOutput { close(editorClosed: true) } }

    func interrupt() {
        revoked = true
        if exporting { task?.cancel() }
        errorKey = WindowCaptureFailure.permissionDenied.messageKey
        if !editingExternally && !working { close(editorClosed: true) }
    }

    func close(editorClosed: Bool = false) {
        guard !closed, !working, !editingExternally || editorClosed else { return }
        closed = true
        task?.cancel()
        task = Task { [documents, sessionID, finished] in
            await documents.cleanup(sessionID: sessionID)
            finished()
        }
    }

    /// App termination preserves a file that may still be open in the external editor.
    func abandon() {
        closed = true; task?.cancel()
        if !editingExternally { Task { await documents.cleanup(sessionID: sessionID) } }
    }
}

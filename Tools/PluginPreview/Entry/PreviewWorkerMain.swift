import Foundation

/// Framed standard-stream entry point for the isolated preview worker.
@main
struct SwitchlyPluginPreviewWorkerMain {
    static func main() {
        exit(PluginPreviewWorkerService.runStandardStreams())
    }
}

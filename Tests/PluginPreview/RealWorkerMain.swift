import Darwin
import Foundation

@main
struct RealWorkerMain {
    static func main() {
        exit(PluginPreviewWorkerService.runStandardStreams())
    }
}

import Foundation

#if PLUGIN_FIXTURE_SMOKE
@main
private struct PluginFixtureFileReaderSmoke {
    static func main() throws {
        guard let markerPath = CommandLine.arguments.dropFirst().first else {
            throw SmokeError.failed("missing marker path")
        }
        let reader = try PluginFixtureFileReader(
            roots: [
                "session": .init(entries: [
                    .init(path: "empty", isDirectory: true),
                    .init(path: "a.txt", text: "hello", modified: 10),
                    .init(path: "nested", isDirectory: true),
                    .init(path: "nested/b.txt", text: "deep", modified: 20),
                    .init(path: "session.lock", text: "", modified: 30, locked: true),
                    .init(path: "logs", isDirectory: true),
                    .init(path: "logs/new.jsonl", text: "new", modified: 80),
                    .init(path: "logs/old.jsonl", text: "old", modified: 10),
                    .init(path: "logs/tie-b.jsonl", text: "b", modified: 80),
                    .init(path: "logs/tie-a.jsonl", text: "a", modified: 80),
                ])
            ],
            now: { 100 }
        )

        guard try reader.readText(root: "session", path: "a.txt") == "hello",
              try reader.list(root: "session", path: "").map(\.name) == ["a.txt", "empty", "logs", "nested", "session.lock"],
              try reader.isLocked(root: "session", path: "session.lock"),
              try reader.scan(root: "session", path: "logs", depth: 1, suffix: ".jsonl", modifiedWithin: 50).map(\.path)
                == ["new.jsonl", "tie-a.jsonl", "tie-b.jsonl"] else {
            throw SmokeError.failed("basic fixture contract")
        }

        for path in ["../x", "/etc/passwd", "logs//new.jsonl", "missing"] {
            do {
                _ = try reader.readText(root: "session", path: path)
                throw SmokeError.failed("path should fail: \(path)")
            } catch PluginFSError.denied where path != "missing" {
            } catch PluginFSError.notFound where path == "missing" {
            }
        }

        do {
            _ = try reader.readText(root: "session", path: "a.txt", maxBytes: 2)
            throw SmokeError.failed("read limit")
        } catch PluginFSError.tooLarge {
        }

        reader.resetCalls()
        for _ in 0..<PluginFileReader.maxCallsPerRender {
            _ = try reader.stat(root: "session", path: "a.txt")
        }
        do {
            _ = try reader.stat(root: "session", path: "a.txt")
            throw SmokeError.failed("call quota")
        } catch PluginFSError.tooManyCalls {
        }
        reader.resetCalls()
        _ = try reader.stat(root: "session", path: "a.txt")

        try Data("plugin-fixture-fs-smoke=passed\n".utf8).write(to: URL(fileURLWithPath: markerPath))
    }

    private enum SmokeError: Error {
        case failed(String)
    }
}
#endif

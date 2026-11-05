import Foundation

@main
struct ScenarioTests {
    static func main() async throws {
        try await StepTests.run()
        try DefaultScenarioTests.run()
        await LauncherLogicTests.run()
        DebugModelTests.run()
        MockDockTests.run()
        let valid = #"{"schemaVersion":1,"id":"default","environment":{"locale":"zh-Hans","appearance":"dark","glass":false,"reduceMotion":true,"contentWidthPoints":360},"target":{"bundleID":"example.app","appName":"Example"},"steps":[]}"#
        let parsed = try PreviewScenario.decode(Data(valid.utf8))
        precondition(parsed.id == "default" && parsed.environment.contentWidthPoints == 360)
        func reject(_ input: String, expected: PreviewScenario.Failure) {
            do {
                _ = try PreviewScenario.decode(Data(input.utf8))
                fatalError("unexpectedly accepted scenario")
            } catch let error as PreviewScenario.Failure {
                precondition(error == expected, "unexpected error: \(error)")
            } catch { fatalError("unexpected error: \(error)") }
        }
        reject(valid.replacingOccurrences(of: "\"steps\":[]", with: "\"steps\":[{}]"), expected: .unsupportedSteps)
        reject(valid.replacingOccurrences(of: "\"steps\":[]", with: "\"steps\":null"), expected: .invalidScenario)
        reject(valid.replacingOccurrences(of: "\"steps\":[]", with: "\"supported\":true"), expected: .invalidScenario)
        reject(valid.replacingOccurrences(of: "\"contentWidthPoints\":360", with: "\"contentWidthPoints\":0"), expected: .invalidScenario)
        reject("{", expected: .invalidScenario)
        let stepsJSON = "\"clock\":{\"startEpochMs\":1,\"seed\":1},\"steps\":[{\"type\":\"advance\",\"ms\":50},{\"type\":\"expectText\",\"contains\":\"x\"}]"
        let typed = try PreviewScenario.decode(Data(valid.replacingOccurrences(of: "\"steps\":[]", with: stepsJSON).utf8))
        precondition(typed.typedSteps == [.advance(milliseconds: 50), .expectText(contains: "x")])
        precondition(parsed.typedSteps.isEmpty)
        reject(valid.replacingOccurrences(of: "\"steps\":[]", with: "\"steps\":[{\"type\":\"advance\",\"ms\":5}]"), expected: .invalidScenario)
        let withClock = valid.replacingOccurrences(of: "\"steps\":[]", with: "\"clock\":{\"startEpochMs\":1700000000000,\"seed\":7},\"steps\":[]")
        let clocked = try PreviewScenario.decode(Data(withClock.utf8))
        precondition(clocked.clock?.seed == 7 && clocked.clock?.startEpochMs == 1_700_000_000_000)
        precondition(parsed.clock == nil, "absent clock keeps realtime behaviour")
        reject(valid.replacingOccurrences(of: "\"steps\":[]", with: "\"clock\":{\"startEpochMs\":-1,\"seed\":7},\"steps\":[]"), expected: .invalidScenario)
        reject(valid.replacingOccurrences(of: "\"steps\":[]", with: "\"clock\":{\"startEpochMs\":1,\"seed\":-3},\"steps\":[]"), expected: .invalidScenario)
        reject(valid.replacingOccurrences(of: "\"steps\":[]", with: "\"clock\":{\"startEpochMs\":1,\"seed\":1,\"x\":1},\"steps\":[]"), expected: .invalidScenario)
        reject(valid.replacingOccurrences(of: "\"steps\":[]", with: "\"clock\":null,\"steps\":[]"), expected: .invalidScenario)
        reject(valid.replacingOccurrences(of: "\"steps\":[]", with: "\"fixtures\":{\"fs\":\"../data.json\"}"), expected: .invalidFixturePath)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("switchly-scenario-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("fixture.json")
        try Data("{}".utf8).write(to: fixture)
        let data = try PreviewFixtureFile.read(relativePath: "fixture.json", scenarioDirectory: directory, maximumBytes: 2)
        precondition(data == Data("{}".utf8))
        func rejectPath(_ path: String, max: Int, expected: PreviewScenario.Failure) {
            do {
                _ = try PreviewFixtureFile.read(relativePath: path, scenarioDirectory: directory, maximumBytes: max)
                fatalError("unexpectedly accepted fixture")
            } catch let error as PreviewScenario.Failure {
                precondition(error == expected, "unexpected error: \(error)")
            } catch { fatalError("unexpected error: \(error)") }
        }
        rejectPath("../fixture.json", max: 2, expected: .invalidFixturePath)
        rejectPath("fixture.json", max: 1, expected: .fixtureTooLarge)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: fixture)
        rejectPath("link", max: 2, expected: .invalidFixturePath)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked-dir"), withDestinationURL: directory)
        rejectPath("linked-dir/fixture.json", max: 2, expected: .invalidFixturePath)
        print("场景与 fixture 路径测试通过")
    }
}

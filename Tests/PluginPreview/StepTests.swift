import Foundation

private final class FakeTarget: PluginPreviewStepTarget {
    var log: [String] = []
    var actions: [PluginPreviewStepAction] = [.init(id: "toggle", enabled: true), .init(id: "off", enabled: false),
                                              .init(id: "dup", enabled: true), .init(id: "dup", enabled: true)]
    var text = #"[{"slot":"center","node":{"type":"text","value":"Now Playing"}}]"#
    var failAdvance = false

    func advance(milliseconds: Double) async throws {
        if failAdvance { throw NSError(domain: "x", code: 1) }
        log.append("advance:\(milliseconds)")
    }
    func perform(actionID: String, value: Double?) async throws { log.append("action:\(actionID)") }
    func renderJSON() async throws -> String { text }
    var clickFailure: String?
    func nativeClick(label: String, expectAction: String?, expectDisabled: Bool) async throws {
        if let clickFailure { throw PluginPreviewStepFailure(code: clickFailure) }
        log.append("click:\(label):\(expectAction ?? "-"):\(expectDisabled)")
    }
    func nativeClickAt(point: PluginPreviewPoint, expectAction: String?) async throws {
        if let clickFailure { throw PluginPreviewStepFailure(code: clickFailure) }
        log.append("point:\(point.x):\(point.y)")
    }
    func nativeDrag(from: PluginPreviewPoint, to: PluginPreviewPoint) async throws {
        if let clickFailure { throw PluginPreviewStepFailure(code: clickFailure) }
        log.append("drag:\(from.x):\(to.y)")
    }
    func availableActions() async throws -> [PluginPreviewStepAction] { actions }
}

enum StepTests {
    static func run() async throws {
        let target = FakeTarget()
        let ok = await PluginPreviewStepRunner.run([.advance(milliseconds: 100), .action(id: "toggle", value: nil),
                                                    .expectText(contains: "Playing")], on: target)
        precondition(ok.failedIndex == nil && ok.traces.map(\.status) == ["passed", "passed", "passed"])
        precondition(target.log == ["advance:100.0", "action:toggle"])
        precondition(ok.traces.map(\.source) == ["clock", "business-action", "render-output"])

        for (step, code) in [(PluginPreviewStep.action(id: "missing", value: nil), "action-unavailable"),
                             (.action(id: "off", value: nil), "action-disabled"),
                             (.action(id: "dup", value: nil), "action-ambiguous"),
                             (.expectText(contains: "absent"), "text-not-found")] {
            let t = FakeTarget()
            let outcome = await PluginPreviewStepRunner.run([step, .advance(milliseconds: 1)], on: t)
            precondition(outcome.failedIndex == 0 && outcome.traces[0].detail == code, "expected \(code), got \(String(describing: outcome.traces[0].detail))")
            precondition(outcome.traces[1].status == "skipped" && t.log.isEmpty, "steps after a failure never run")
        }

        let clicker = FakeTarget()
        let clicked = await PluginPreviewStepRunner.run([.nativeClick(label: "Pause", expectAction: "toggle", expectDisabled: false)], on: clicker)
        precondition(clicked.traces[0].source == "native-input" && clicked.traces[0].status == "passed")
        precondition(clicker.log == ["click:Pause:toggle:false"])
        let refused = FakeTarget(); refused.clickFailure = "element-not-found"
        let refusedOutcome = await PluginPreviewStepRunner.run([.nativeClick(label: "X", expectAction: nil, expectDisabled: false)], on: refused)
        precondition(refusedOutcome.traces[0].detail == "element-not-found", "target failure codes pass through verbatim")

        let failing = FakeTarget(); failing.failAdvance = true
        let errored = await PluginPreviewStepRunner.run([.advance(milliseconds: 1)], on: failing)
        precondition(errored.traces[0].detail == "step-error")

        let bad = FakeTarget(); bad.text = "not json"
        let invalid = await PluginPreviewStepRunner.run([.expectText(contains: "x")], on: bad)
        precondition(invalid.traces[0].detail == "invalid-render-output")

        let task = Task { await PluginPreviewStepRunner.run([.advance(milliseconds: 1)], on: FakeTarget()) }
        task.cancel()
        let cancelled = await task.value
        precondition(cancelled.failedIndex == 0 && cancelled.traces[0].detail == "cancelled", "cancelled runs do not execute steps")

        // 解析：合法、未知类型、字段错误、上限。
        func parse(_ json: String) throws -> [PluginPreviewStep] {
            try PluginPreviewStep.parse(JSONSerialization.jsonObject(with: Data(json.utf8)) as! [Any])
        }
        let parsed = try parse(#"[{"type":"advance","ms":5},{"type":"action","id":"a","value":0.5},{"type":"expectText","contains":"x"}]"#)
        precondition(parsed.count == 3)
        func rejects(_ json: String, _ expected: PreviewScenario.Failure) {
            do { _ = try parse(json); fatalError("accepted \(json)") }
            catch let e as PreviewScenario.Failure { precondition(e == expected, "\(json) -> \(e)") }
            catch { fatalError("\(error)") }
        }
        let nativeA = try parse(#"[{"type":"nativeClick","label":"Pause","expectAction":"toggle"}]"#)
        precondition(nativeA == [.nativeClick(label: "Pause", expectAction: "toggle", expectDisabled: false)])
        let nativeB = try parse(#"[{"type":"nativeClick","label":"Pause","expectDisabled":true}]"#)
        precondition(nativeB == [.nativeClick(label: "Pause", expectAction: nil, expectDisabled: true)])
        let pointer = try parse(#"[{"type":"nativeClickAt","point":{"x":150,"y":389},"expectAction":"toggle"},{"type":"nativeDrag","from":{"x":150,"y":100},"to":{"x":190,"y":120}}]"#)
        let pointerTarget = FakeTarget()
        let pointerResult = await PluginPreviewStepRunner.run(pointer, on: pointerTarget)
        precondition(pointerResult.failedIndex == nil && pointerResult.traces.allSatisfy { $0.source == "native-input" })
        precondition(pointerTarget.log == ["point:150.0:389.0", "drag:150.0:120.0"])
        let refusedPointer = FakeTarget(); refusedPointer.clickFailure = "pointer-target-unsupported"
        let refusedPointerResult = await PluginPreviewStepRunner.run(pointer, on: refusedPointer)
        precondition(refusedPointerResult.traces[0].detail == "pointer-target-unsupported" && refusedPointerResult.traces[1].status == "skipped")
        rejects(#"[{"type":"nativeClickAt","point":{"x":true,"y":1}}]"#, .invalidScenario)
        rejects(#"[{"type":"nativeClickAt","point":{"x":-1,"y":1}}]"#, .invalidScenario)
        rejects(#"[{"type":"nativeClickAt","point":{"x":1,"y":1,"z":0}}]"#, .invalidScenario)
        rejects(#"[{"type":"nativeClickAt","point":{"x":1,"y":1},"expectAction":""}]"#, .invalidScenario)
        rejects(#"[{"type":"nativeDrag","from":{"x":1,"y":1}}]"#, .invalidScenario)
        do {
            _ = try PluginPreviewStep.parse([["type": "nativeClickAt", "point": ["x": Double.infinity, "y": 1]]])
            fatalError("accepted infinite coordinate")
        } catch let error as PreviewScenario.Failure { precondition(error == .invalidScenario) }
        rejects(#"[{"type":"nativeClick","label":"A","expectAction":"x","expectDisabled":true}]"#, .invalidScenario)
        rejects(#"[{"type":"nativeClick","label":""}]"#, .invalidScenario)
        rejects(#"[{"type":"nativeClick","label":"A","expectDisabled":1}]"#, .invalidScenario)
        rejects(#"[{"type":"wait"}]"#, .unsupportedSteps)
        rejects(#"[{"ms":1}]"#, .unsupportedSteps)
        rejects(#"[{"type":"advance","ms":-1}]"#, .invalidScenario)
        rejects(#"[{"type":"advance","ms":true}]"#, .invalidScenario)
        rejects(#"[{"type":"advance","ms":1e12}]"#, .invalidScenario)
        rejects(#"[{"type":"advance","ms":1,"x":2}]"#, .invalidScenario)
        rejects(#"[{"type":"action","id":""}]"#, .invalidScenario)
        rejects(#"[{"type":"action","id":"a","value":"1"}]"#, .invalidScenario)
        rejects(#"[{"type":"expectText","contains":""}]"#, .invalidScenario)
        rejects("[" + Array(repeating: #"{"type":"advance","ms":1}"#, count: 65).joined(separator: ",") + "]", .invalidScenario)
    }
}

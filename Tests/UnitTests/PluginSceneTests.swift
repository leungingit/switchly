import SwiftUI
import XCTest
@testable import Switchly

final class PluginSceneTests: XCTestCase {
    private func scene(_ layers: String, extra: String = "") throws -> PluginScene {
        let json = #"{"key":"k","epoch":100,"width":200,"height":100,\#(extra) "layers":[\#(layers)]}"#
        return try JSONDecoder().decode(PluginScene.self, from: Data(json.utf8))
    }

    func testDecodesLayersAndAppliesDefaults() throws {
        let s = try scene(##"{"kind":"rect","w":10,"h":20,"fill":"#FF000080"},{"kind":"text","text":"Hi","fill":"$label"}"##)
        XCTAssertEqual(s.fps, 30)
        XCTAssertEqual(s.layers.count, 2)
        XCTAssertEqual(s.layers[0].scale, 1)
        XCTAssertEqual(s.layers[0].anchor, SceneVec(x: 0.5, y: 0.5))
        guard case .solid(let c)? = s.layers[0].fill else { return XCTFail("solid fill") }
        XCTAssertEqual(c.r, 1, accuracy: 0.001)
        XCTAssertEqual(c.a, 128.0 / 255, accuracy: 0.001)
        guard case .solid(let label)? = s.layers[1].fill else { return XCTFail("token fill") }
        XCTAssertEqual(label.token, .label)
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try scene(#"{"kind":"rect","fill":"red"}"#), "named colours are not hex")
        XCTAssertThrowsError(try scene(#"{"kind":"text"}"#), "text needs its string")
        XCTAssertThrowsError(try scene(#"{"kind":"blob"}"#))
        XCTAssertThrowsError(try scene(#"{"kind":"rect","children":[{"kind":"rect"}]}"#), "only groups nest")
        XCTAssertThrowsError(try scene(#"{"kind":"sprite","sprite":{"asset":"../x.png","cols":1,"rows":1,"t0":0}}"#))
        XCTAssertThrowsError(try scene(#"{"kind":"rect","tracks":[{"prop":"x","keys":[]}]}"#), "a track needs keys")
    }

    func testEnforcesBudgets() {
        let many = Array(repeating: #"{"kind":"rect"}"#, count: PluginScene.maxLayers + 1).joined(separator: ",")
        XCTAssertThrowsError(try scene(many))
        let emitters = Array(repeating: ##"{"kind":"emitter","emitter":{"count":120,"t0":0,"life":1,"color":"#FFFFFF"}}"##, count: 4).joined(separator: ",")
        XCTAssertThrowsError(try scene(emitters), "particle budget")
        let hits = #"{"kind":"group","hit":{"id":"a","label":"A"}},{"kind":"group","hit":{"id":"a","label":"B"}}"#
        XCTAssertThrowsError(try scene(hits), "duplicate hit ids")
        XCTAssertThrowsError(try JSONDecoder().decode(PluginScene.self, from: Data(#"{"key":"k","epoch":0,"width":5000,"height":100,"layers":[]}"#.utf8)))
    }

    func testTracksEaseAndLoop() throws {
        let s = try scene(#"{"kind":"rect","x":5,"tracks":[{"prop":"x","keys":[{"t":1,"v":10},{"t":3,"v":30,"e":"inOut"}]},{"prop":"y","loop":2,"keys":[{"t":0,"v":0},{"t":1,"v":10}]}]}"#)
        let layer = s.layers[0]
        XCTAssertEqual(layer.value(.x, at: 0), 10, "before the first key holds its value")
        XCTAssertEqual(layer.value(.x, at: 2), 20, accuracy: 1e-9, "smoothstep midpoint")
        XCTAssertEqual(layer.value(.x, at: 9), 30, "after the last key holds its value")
        XCTAssertEqual(layer.value(.y, at: 2.5), 5, accuracy: 1e-9, "loops every 2 s")
        XCTAssertEqual(layer.value(.y, at: 2.5, still: true), 0, "Reduce Motion rests the loop at its start")
        XCTAssertNil(s.settledAt, "a looping track never settles")
    }

    func testOscillatorsAddAndDecay() throws {
        let s = try scene(#"{"kind":"rect","y":4,"osc":[{"prop":"y","amp":2,"freq":1,"start":1,"decay":1}]}"#)
        let layer = s.layers[0]
        XCTAssertEqual(layer.value(.y, at: 0.5), 4, "before start")
        XCTAssertEqual(layer.value(.y, at: 1.25), 4 + 2 * exp(-0.25), accuracy: 1e-9)
        XCTAssertEqual(layer.value(.y, at: 1.25, still: true), 4, "oscillators are dropped under Reduce Motion")
        XCTAssertEqual(try XCTUnwrap(s.settledAt), 7, accuracy: 1e-9, "decaying oscillator settles")
    }

    func testSettledTimeCoversEveryEffect() throws {
        let s = try scene(##"{"kind":"emitter","emitter":{"count":4,"t0":1,"t1":2,"life":0.5,"color":"#FFFFFF","topFirst":0.2}},{"kind":"group","shatter":{"at":3,"duration":1},"w":10,"h":10}"##)
        XCTAssertEqual(try XCTUnwrap(s.settledAt), 4.5, accuracy: 1e-9)
        XCTAssertEqual(s.time(now: 103, reduceMotion: false), 3)
        XCTAssertEqual(s.time(now: 103, reduceMotion: true), 4.5, "rest pose is the settled time")
    }

    func testHitRegionsFollowTransformsAndVisibility() throws {
        let s = try scene(#"{"kind":"group","x":100,"y":50,"w":40,"h":60,"scale":2,"from":1,"hit":{"id":"card","label":"Card"},"children":[{"kind":"group","x":10,"y":0,"w":10,"h":10,"hit":{"id":"inner","label":"Inner"}}]}"#)
        XCTAssertEqual(SceneDrawing.hitRegions(in: s, at: 0, still: false), [], "not visible yet")
        let regions = SceneDrawing.hitRegions(in: s, at: 2, still: false)
        XCTAssertEqual(regions.map(\.hit.id), ["card", "inner"])
        XCTAssertEqual(regions[0].rect, CGRect(x: 60, y: -10, width: 80, height: 120))
        XCTAssertEqual(regions[1].rect, CGRect(x: 110, y: 40, width: 20, height: 20), "child offsets scale with the parent")
    }

    func testSceneNodeRoutesHitsAsActions() throws {
        let json = #"[{"slot":"center","node":{"type":"scene","key":"k","epoch":0,"width":100,"height":100,"layers":[{"kind":"group","hit":{"id":"go","label":"Go"}}]}}]"#
        let out = try PluginRenderOutput.decode(json: Data(json.utf8))
        XCTAssertEqual(out.first?.node.actionIDs, ["go"])
    }

    func testSettingSpecKinds() throws {
        func decode(_ json: String) throws -> PluginSettingSpec { try JSONDecoder().decode(PluginSettingSpec.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode(#"{"key":"a","title":{"en":"A"},"default":true}"#).default, true)
        let select = try decode(#"{"key":"c","type":"select","title":{"en":"C"},"default":"rain","options":[{"value":"clear","title":{"en":"Clear"}},{"value":"rain","title":{"en":"Rain"}}]}"#)
        XCTAssertEqual(select.defaultValue, .string("rain"))
        XCTAssertThrowsError(try decode(#"{"key":"c","type":"select","title":{"en":"C"},"default":"fog","options":[{"value":"clear","title":{"en":"Clear"}}]}"#), "default must be an option")
        XCTAssertThrowsError(try decode(#"{"key":"n","type":"number","title":{"en":"N"},"default":99,"min":0,"max":50}"#), "default out of range")
        XCTAssertThrowsError(try decode(#"{"key":"n","type":"number","title":{"en":"N"},"default":true}"#), "wrong default type")
    }

    func testSettingsWithoutPluginValuesStillDecode() throws {
        var settings = AppSettings.default
        settings.pluginValues["p"] = ["temperature": .number(31), "condition": .string("rain")]
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).pluginValues["p"]?["temperature"], .number(31))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "pluginValues")
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: old).pluginValues, [:])
    }
}

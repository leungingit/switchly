//
//  PluginScene3DDescriptorTests.swift
//  SwitchlyTests
//
//  T06: model-side contract tests. These lock the JSON shape the future T07
//  decoder will hand to the component, the declaration validation order, and
//  the independent-view size policy. They deliberately do not touch the
//  formal Dock or preview wiring.
//

import CoreGraphics
import XCTest
@testable import Switchly

final class PluginScene3DDescriptorTests: XCTestCase {
    // MARK: - Decoding

    func testMinimalDescriptorAppliesFrozenDefaults() throws {
        let json = """
        {
          "key": "battery",
          "asset": "models/battery.glb",
          "fallback": { "type": "text", "value": "No 3D view", "style": "body" }
        }
        """
        let descriptor = try JSONDecoder().decode(
            PluginScene3DDescriptor.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(descriptor.fit, .contain)
        XCTAssertEqual(descriptor.camera, PluginScene3DCamera(yaw: 0, pitch: 0))
        XCTAssertEqual(descriptor.rotate, PluginScene3DRotate())
        XCTAssertTrue(descriptor.surfaces.isEmpty)
        XCTAssertTrue(descriptor.hits.isEmpty)
        XCTAssertEqual(descriptor.assetURL(in: URL(fileURLWithPath: "/plugin")).path,
                       "/plugin/models/battery.glb")
    }

    func testFullDescriptorDecodesCameraRotationSurfacesAndHits() throws {
        let json = """
        {
          "key": "ipod",
          "asset": "ipod.glb",
          "fit": "contain",
          "camera": { "yaw": 15, "pitch": -5 },
          "rotate": { "horizontal": false, "vertical": true, "pitchMin": -20, "pitchMax": 30 },
          "surfaces": [
            {
              "node": "screen",
              "size": [240, 160],
              "content": { "type": "text", "value": "Now playing", "style": "title" }
            }
          ],
          "hits": [
            { "node": "wheel", "id": "play", "label": "Play", "value": 0.5 },
            { "node": "menu", "id": "menu", "label": "Menu", "enabled": false }
          ],
          "fallback": { "type": "text", "value": "Fallback", "style": "caption" }
        }
        """
        let descriptor = try JSONDecoder().decode(
            PluginScene3DDescriptor.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(descriptor.camera.yaw, 15)
        XCTAssertEqual(descriptor.camera.pitch, -5)
        XCTAssertFalse(descriptor.rotate.horizontal)
        XCTAssertEqual(descriptor.rotate.resolvedPitchRange, -20...30)
        XCTAssertEqual(descriptor.surfaces.first?.size, PluginScene3DSize(width: 240, height: 160))
        XCTAssertEqual(descriptor.hits.first?.value, 0.5)
        XCTAssertEqual(descriptor.hits.last?.enabled, false)
        XCTAssertNoThrow(try PluginScene3DDeclaration.validate(descriptor))
    }

    func testRotationDefaultsPitchRangeAndEnabled() throws {
        let descriptor = PluginScene3DDescriptor(
            key: "k",
            asset: "a.glb",
            fallback: text("fallback")
        )
        XCTAssertEqual(descriptor.rotate.resolvedPitchRange, -55...55)
        XCTAssertEqual(PluginScene3DHit(node: "n", id: "i", label: "l").enabled, true)
    }

    func testSurfaceSizeRequiresExactlyTwoElements() throws {
        func decodeSize(_ value: String) throws -> PluginScene3DSize {
            try JSONDecoder().decode(PluginScene3DSize.self, from: Data(value.utf8))
        }

        XCTAssertEqual(try decodeSize("[12, 34]"), PluginScene3DSize(width: 12, height: 34))
        XCTAssertThrowsError(try decodeSize("[1, 2, 3]"))
        XCTAssertThrowsError(try decodeSize("[1]"))
    }

    func testDescriptorWithoutFallbackFailsToDecode() throws {
        let json = """
        { "key": "k", "asset": "a.glb" }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(
            PluginScene3DDescriptor.self,
            from: Data(json.utf8)
        ))
    }

    // MARK: - Declaration validation

    func testAssetPathValidationRejectsEscapesAndNonGLB() {
        for asset in ["/abs/a.glb", "../a.glb", "models/../a.glb", "a.gltf", "models//a.glb", ""] {
            let descriptor = PluginScene3DDescriptor(key: "k", asset: asset, fallback: text("f"))
            XCTAssertThrowsError(try PluginScene3DDeclaration.validate(descriptor), asset)
        }
        let valid = PluginScene3DDescriptor(key: "k", asset: "models/a.glb", fallback: text("f"))
        XCTAssertNoThrow(try PluginScene3DDeclaration.validate(valid))
    }

    func testCameraValidationRejectsNonFiniteAndOutOfRange() {
        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    camera: PluginScene3DCamera(yaw: .nan, pitch: 0),
                                    fallback: text("f"))
        ))
        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    camera: PluginScene3DCamera(yaw: 181, pitch: 0),
                                    fallback: text("f"))
        ))
        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    camera: PluginScene3DCamera(yaw: 0, pitch: 90),
                                    fallback: text("f"))
        ))
    }

    func testRotationValidationRequiresPairedFinitePitchRange() {
        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    rotate: PluginScene3DRotate(pitchMin: -10),
                                    fallback: text("f"))
        )) { error in
            XCTAssertEqual(error as? PluginScene3DDeclarationError, .pitchRangeNotPaired)
        }
        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    rotate: PluginScene3DRotate(pitchMin: 20, pitchMax: -20),
                                    fallback: text("f"))
        )) { error in
            XCTAssertEqual(error as? PluginScene3DDeclarationError, .invalidPitchRange)
        }
        XCTAssertNoThrow(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    rotate: PluginScene3DRotate(pitchMin: -20, pitchMax: 20),
                                    fallback: text("f"))
        ))
    }

    func testSurfaceValidationRejectsLimitDuplicatesAndForbiddenContent() {
        let one = PluginScene3DSurface(node: "screen", size: .init(width: 64, height: 64), content: text("a"))
        let two = PluginScene3DSurface(node: "second", size: .init(width: 64, height: 64), content: text("b"))
        let three = PluginScene3DSurface(node: "third", size: .init(width: 64, height: 64), content: text("c"))

        let many = (0..<(PluginScene3DLimits.maxSurfaces + 1)).map {
            PluginScene3DSurface(node: "n\($0)", size: .init(width: 64, height: 64), content: text("a"))
        }
        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb", surfaces: many, fallback: text("f"))
        )) { XCTAssertEqual($0 as? PluginScene3DDeclarationError, .tooManySurfaces) }
        XCTAssertNoThrow(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb", surfaces: [one, two, three], fallback: text("f"))
        ))

        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    surfaces: [one, PluginScene3DSurface(node: "screen", size: .init(width: 64, height: 64), content: text("b"))],
                                    fallback: text("f"))
        )) { XCTAssertEqual($0 as? PluginScene3DDeclarationError, .duplicateSurfaceNode("screen")) }

        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    surfaces: [PluginScene3DSurface(node: "screen",
                                                                    size: .init(width: 0, height: 64),
                                                                    content: text("a"))],
                                    fallback: text("f"))
        )) { XCTAssertEqual($0 as? PluginScene3DDeclarationError, .surfaceSizeOutOfRange("screen")) }

        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    surfaces: [PluginScene3DSurface(node: "screen",
                                                                    size: .init(width: 64, height: 64),
                                                                    content: .button(id: "b", symbol: "play",
                                                                                     label: "Play", size: .m,
                                                                                     variant: .plain,
                                                                                     enabled: true,
                                                                                     selected: false))],
                                    fallback: text("f"))
        )) { XCTAssertEqual($0 as? PluginScene3DDeclarationError, .forbiddenSurfaceContent("screen")) }
    }

    func testHitValidationRejectsDuplicatesNonFiniteAndOverlap() {
        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    hits: [PluginScene3DHit(node: "a", id: "same", label: "A"),
                                           PluginScene3DHit(node: "b", id: "same", label: "B")],
                                    fallback: text("f"))
        )) { XCTAssertEqual($0 as? PluginScene3DDeclarationError, .duplicateActionID("same")) }

        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    hits: [PluginScene3DHit(node: "button", id: "a", label: "A"),
                                           PluginScene3DHit(node: "button", id: "b", label: "B")],
                                    fallback: text("f"))
        )) { XCTAssertEqual($0 as? PluginScene3DDeclarationError, .duplicateHitNode("button")) }

        // 不同 sector 可共用一个节点；重复 sector 或与无 sector 混用都拒绝。
        XCTAssertNoThrow(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    hits: [PluginScene3DHit(node: "ring", id: "a", label: "A", sector: .top),
                                           PluginScene3DHit(node: "ring", id: "b", label: "B", sector: .bottom)],
                                    fallback: text("f"))
        ))
        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    hits: [PluginScene3DHit(node: "ring", id: "a", label: "A", sector: .top),
                                           PluginScene3DHit(node: "ring", id: "b", label: "B", sector: .top)],
                                    fallback: text("f"))
        )) { XCTAssertEqual($0 as? PluginScene3DDeclarationError, .duplicateHitNode("ring")) }
        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    hits: [PluginScene3DHit(node: "ring", id: "a", label: "A", sector: .top),
                                           PluginScene3DHit(node: "ring", id: "b", label: "B")],
                                    fallback: text("f"))
        )) { XCTAssertEqual($0 as? PluginScene3DDeclarationError, .duplicateHitNode("ring")) }

        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    hits: [PluginScene3DHit(node: "a", id: "i", label: "L", value: .infinity)],
                                    fallback: text("f"))
        )) { XCTAssertEqual($0 as? PluginScene3DDeclarationError, .nonFiniteHitValue("i")) }

        // 同一节点既可贴图又可点击（贴图后的按钮）。
        let surface = PluginScene3DSurface(node: "screen", size: .init(width: 64, height: 64), content: text("a"))
        XCTAssertNoThrow(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb",
                                    surfaces: [surface],
                                    hits: [PluginScene3DHit(node: "screen", id: "i", label: "L")],
                                    fallback: text("f"))
        ))
    }

    func testFallbackActionIDsMustBeUnique() {
        let duplicateButtons = PluginUINode.hstack(children: [
            .button(id: "same", symbol: "a", label: "A", size: .s,
                    variant: .plain, enabled: true, selected: false),
            .button(id: "same", symbol: "b", label: "B", size: .s,
                    variant: .plain, enabled: true, selected: false),
        ], spacing: nil, align: nil)
        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(
            PluginScene3DDescriptor(key: "k", asset: "a.glb", fallback: duplicateButtons)
        )) { XCTAssertEqual($0 as? PluginScene3DDeclarationError, .duplicateFallbackActionID("same")) }
    }

    // MARK: - Render output action ID rule

    private func scene3dJSON(hits: [String], fallbackButtons: [String]) -> String {
        let hitJSON = hits.enumerated().map {
            #"{"node":"n\#($0.offset)","id":"\#($0.element)","label":"L"}"#
        }.joined(separator: ",")
        let buttons = fallbackButtons.map {
            #"{"type":"button","id":"\#($0)","symbol":"play","label":"L"}"#
        }.joined(separator: ",")
        return #"{"type":"scene3d","key":"k","asset":"a.glb","hits":[\#(hitJSON)],"#
            + #""fallback":{"type":"hstack","children":[\#(buttons)]}}"#
    }

    private func decodeSlots(_ nodes: [String]) throws -> [PluginSlotContent] {
        let slots = ["center", "bottomBar"]
        let body = nodes.enumerated().map { #"{"slot":"\#(slots[$0.offset])","node":\#($0.element)}"# }
            .joined(separator: ",")
        return try PluginRenderOutput.decode(json: Data("[\(body)]".utf8))
    }

    func testHitMayReuseActionIDFromOwnFallback() throws {
        let node = scene3dJSON(hits: ["love", "toggle"], fallbackButtons: ["love", "toggle", "next"])
        let contents = try decodeSlots([node])
        XCTAssertEqual(contents.first?.node.actionIDs, ["love", "toggle", "next"])
    }

    func testScene3dActionIDsStillConflictWithSiblingNodes() {
        let scene = scene3dJSON(hits: ["love"], fallbackButtons: ["love"])
        let sibling = #"{"type":"button","id":"love","symbol":"play","label":"L"}"#
        XCTAssertThrowsError(try decodeSlots([scene, sibling])) {
            XCTAssertEqual($0 as? PluginRenderOutput.ValidationError, .duplicateActionID("love"))
        }
    }

    func testScene3dRejectsDuplicatesWithinHitsOrWithinFallback() {
        XCTAssertThrowsError(try decodeSlots([scene3dJSON(hits: ["a", "a"], fallbackButtons: [])]))
        XCTAssertThrowsError(try decodeSlots([scene3dJSON(hits: [], fallbackButtons: ["a", "a"])]))
    }

    func testDeclarationNodeBudgetCountsScene3dSurfaceContentAndFallback() {
        // One scene3d root + 63 fallback nodes = the full 64-node budget.
        let fallback = PluginUINode.hstack(
            children: (0..<62).map { text("fallback \($0)") },
            spacing: nil,
            align: nil
        )
        let atLimit = PluginScene3DDescriptor(key: "k", asset: "a.glb", fallback: fallback)
        XCTAssertNoThrow(try PluginScene3DDeclaration.validate(atLimit))

        // A single surface content node pushes the combined declaration over.
        let overLimit = PluginScene3DDescriptor(
            key: "k",
            asset: "a.glb",
            surfaces: [PluginScene3DSurface(node: "screen",
                                            size: .init(width: 64, height: 64),
                                            content: text("surface"))],
            fallback: fallback
        )
        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(overLimit)) {
            XCTAssertEqual($0 as? PluginScene3DDeclarationError, .declarationTooManyNodes)
        }
    }

    func testDeclarationDepthCountsTheScene3dRoot() {
        // scene3d root + 7 fallback levels = the depth-8 budget.
        let atLimit = PluginScene3DDescriptor(key: "k", asset: "a.glb", fallback: chain(depth: 7))
        XCTAssertNoThrow(try PluginScene3DDeclaration.validate(atLimit))

        let overLimit = PluginScene3DDescriptor(key: "k", asset: "a.glb", fallback: chain(depth: 8))
        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(overLimit)) {
            XCTAssertEqual($0 as? PluginScene3DDeclarationError, .declarationTooDeep)
        }

        let deepSurface = PluginScene3DDescriptor(
            key: "k",
            asset: "a.glb",
            surfaces: [PluginScene3DSurface(node: "screen",
                                            size: .init(width: 64, height: 64),
                                            content: chain(depth: 8))],
            fallback: text("f")
        )
        XCTAssertThrowsError(try PluginScene3DDeclaration.validate(deepSurface)) {
            XCTAssertEqual($0 as? PluginScene3DDeclarationError, .declarationTooDeep)
        }
    }

    // MARK: - Size policy

    func testViewportRequiresTheFrozenMinimum() {
        XCTAssertFalse(PluginScene3DViewport.canHost3D(in: CGSize(width: 219, height: 380)))
        XCTAssertFalse(PluginScene3DViewport.canHost3D(in: CGSize(width: 220, height: 379)))
        XCTAssertFalse(PluginScene3DViewport.canHost3D(in: CGSize(width: 132, height: 132)))
        XCTAssertFalse(PluginScene3DViewport.canHost3D(in: CGSize(width: CGFloat.infinity, height: 420)))
        XCTAssertTrue(PluginScene3DViewport.canHost3D(in: PluginScene3DViewport.minimumSize))
    }

    func testViewportCapsAtIdealButNeverUpscales() {
        XCTAssertEqual(PluginScene3DViewport.size(fitting: CGSize(width: 220, height: 380)),
                       CGSize(width: 220, height: 380))
        XCTAssertEqual(PluginScene3DViewport.size(fitting: CGSize(width: 500, height: 600)),
                       PluginScene3DViewport.idealSize)
        XCTAssertEqual(PluginScene3DViewport.size(fitting: CGSize(width: 280, height: 600)),
                       CGSize(width: 280, height: 480))
        XCTAssertNil(PluginScene3DViewport.size(fitting: CGSize(width: 200, height: 600)))
    }

    // MARK: - Helpers

    private func text(_ value: String) -> PluginUINode {
        .text(value: value, style: .body, lines: nil)
    }

    /// Builds a `vstack` chain of exactly `depth` nodes.
    private func chain(depth: Int) -> PluginUINode {
        precondition(depth >= 1)
        return (1..<depth).reduce(text("leaf")) { child, _ in
            .vstack(children: [child], spacing: nil, align: nil)
        }
    }
}

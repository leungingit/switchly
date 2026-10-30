//
//  PluginUINode.swift
//  Switchly
//
//  Declarative UI tree returned by a plugin's render() (design doc §3.5).
//  Decoding is the schema check: unknown types, enum values or out-of-range
//  numbers fail to decode, so the renderer only ever sees valid trees.
//

import Foundation

enum PluginSlot: String, Codable, CaseIterable {
    case bottomBar
    case center
    case topTrailing
    case titleAccessory
}

enum PluginSpacing: String, Codable { case xs, s, m }
enum PluginAlignment: String, Codable { case leading, center, trailing }
enum PluginMaterial: String, Codable { case glass, plain }
enum PluginControlSize: String, Codable { case s, m, l }
enum PluginButtonVariant: String, Codable { case plain, prominent }
enum PluginTextStyle: String, Codable { case title, body, caption }
enum PluginProgressStyle: String, Codable { case linear, circular }
enum PluginCorner: String, Codable { case s, m }
enum PluginBadgeTone: String, Codable { case neutral, accent, warning }

enum PluginImageSource: Equatable, Codable {
    case symbol(String)
    case pluginAsset(String)
    case artwork

    private enum CodingKeys: String, CodingKey { case symbol, pluginAsset, artwork }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let symbol = try c.decodeIfPresent(String.self, forKey: .symbol) {
            self = .symbol(symbol)
        } else if let asset = try c.decodeIfPresent(String.self, forKey: .pluginAsset) {
            guard !asset.hasPrefix("/"), !asset.split(separator: "/").contains("..") else {
                throw DecodingError.dataCorruptedError(forKey: .pluginAsset, in: c, debugDescription: "Asset escapes plugin")
            }
            self = .pluginAsset(asset)
        } else if try c.decodeIfPresent(Bool.self, forKey: .artwork) == true {
            self = .artwork
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown image source"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbol(let s): try c.encode(s, forKey: .symbol)
        case .pluginAsset(let a): try c.encode(a, forKey: .pluginAsset)
        case .artwork: try c.encode(true, forKey: .artwork)
        }
    }
}

indirect enum PluginUINode: Equatable, Decodable {
    case hstack(children: [PluginUINode], spacing: PluginSpacing?, align: PluginAlignment?)
    case vstack(children: [PluginUINode], spacing: PluginSpacing?, align: PluginAlignment?)
    case zstack(children: [PluginUINode])
    case spacer
    case surface(children: [PluginUINode], material: PluginMaterial)
    case button(id: String, symbol: String, label: String, size: PluginControlSize,
                variant: PluginButtonVariant, enabled: Bool, selected: Bool)
    case toggle(id: String, symbolOn: String, symbolOff: String, isOn: Bool, label: String)
    case slider(id: String, value: Double, label: String, step: Double?)
    case text(value: String, style: PluginTextStyle, lines: Int?)
    /// `rate` is the per-second increment the host interpolates locally (§3.5.4).
    case progress(value: Double, style: PluginProgressStyle, rate: Double?)
    case image(source: PluginImageSource, size: PluginControlSize, corner: PluginCorner?)
    case badge(value: String, tone: PluginBadgeTone)
    case marquee(value: String)
    /// Inset display frame (an LCD-style "screen") around its children.
    case screen(children: [PluginUINode])
    /// Click-wheel dial. Exactly five children placed top, leading, trailing,
    /// bottom and centre; use `spacer` for an empty position.
    case wheel(children: [PluginUINode])
    /// Host-played animation (design doc §8). Its hits route to onAction.
    case scene(PluginScene)

    private enum CodingKeys: String, CodingKey {
        case type, children, spacing, align, material, id, symbol, label, size, variant, enabled, selected
        case symbolOn, symbolOff, isOn, value, step, style, lines, rate, source, corner, tone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        func children() throws -> [PluginUINode] { try c.decodeIfPresent([PluginUINode].self, forKey: .children) ?? [] }
        func unit(_ key: CodingKeys) throws -> Double {
            let v = try c.decode(Double.self, forKey: key)
            guard v.isFinite else { throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Not finite") }
            return min(max(v, 0), 1)
        }
        func nonEmpty(_ key: CodingKeys) throws -> String {
            let v = try c.decode(String.self, forKey: key)
            guard !v.isEmpty else { throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Empty") }
            return v
        }
        switch type {
        case "hstack":
            self = .hstack(children: try children(), spacing: try c.decodeIfPresent(PluginSpacing.self, forKey: .spacing),
                           align: try c.decodeIfPresent(PluginAlignment.self, forKey: .align))
        case "vstack":
            self = .vstack(children: try children(), spacing: try c.decodeIfPresent(PluginSpacing.self, forKey: .spacing),
                           align: try c.decodeIfPresent(PluginAlignment.self, forKey: .align))
        case "zstack":
            self = .zstack(children: try children())
        case "spacer":
            self = .spacer
        case "surface":
            self = .surface(children: try children(),
                            material: try c.decodeIfPresent(PluginMaterial.self, forKey: .material) ?? .glass)
        case "button":
            // Every interactive control needs a label for VoiceOver.
            self = .button(id: try nonEmpty(.id), symbol: try nonEmpty(.symbol), label: try nonEmpty(.label),
                           size: try c.decodeIfPresent(PluginControlSize.self, forKey: .size) ?? .m,
                           variant: try c.decodeIfPresent(PluginButtonVariant.self, forKey: .variant) ?? .plain,
                           enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                           selected: try c.decodeIfPresent(Bool.self, forKey: .selected) ?? false)
        case "toggle":
            self = .toggle(id: try nonEmpty(.id), symbolOn: try nonEmpty(.symbolOn), symbolOff: try nonEmpty(.symbolOff),
                           isOn: try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? false, label: try nonEmpty(.label))
        case "slider":
            let step = try c.decodeIfPresent(Double.self, forKey: .step)
            if let step, !(step > 0 && step <= 1) {
                throw DecodingError.dataCorruptedError(forKey: .step, in: c, debugDescription: "step out of range")
            }
            self = .slider(id: try nonEmpty(.id), value: try unit(.value), label: try nonEmpty(.label), step: step)
        case "text":
            let lines = try c.decodeIfPresent(Int.self, forKey: .lines)
            self = .text(value: try c.decode(String.self, forKey: .value),
                         style: try c.decodeIfPresent(PluginTextStyle.self, forKey: .style) ?? .body,
                         lines: lines.map { min(max($0, 1), 3) })
        case "progress":
            let rate = try c.decodeIfPresent(Double.self, forKey: .rate)
            self = .progress(value: try unit(.value),
                             style: try c.decodeIfPresent(PluginProgressStyle.self, forKey: .style) ?? .linear,
                             rate: rate.flatMap { $0.isFinite ? $0 : nil })
        case "image":
            self = .image(source: try c.decode(PluginImageSource.self, forKey: .source),
                          size: try c.decodeIfPresent(PluginControlSize.self, forKey: .size) ?? .m,
                          corner: try c.decodeIfPresent(PluginCorner.self, forKey: .corner))
        case "badge":
            self = .badge(value: try c.decode(String.self, forKey: .value),
                          tone: try c.decodeIfPresent(PluginBadgeTone.self, forKey: .tone) ?? .neutral)
        case "marquee":
            self = .marquee(value: try c.decode(String.self, forKey: .value))
        case "screen":
            self = .screen(children: try children())
        case "wheel":
            let items = try children()
            guard items.count == 5 else {
                throw DecodingError.dataCorruptedError(forKey: .children, in: c, debugDescription: "wheel needs 5 children")
            }
            self = .wheel(children: items)
        case "scene":
            self = .scene(try PluginScene(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown node type \(type)")
        }
    }

    var children: [PluginUINode] {
        switch self {
        case .hstack(let c, _, _), .vstack(let c, _, _), .zstack(let c), .surface(let c, _), .wheel(let c), .screen(let c): return c
        default: return []
        }
    }

    /// Ids of interactive controls; used to route onAction and reject duplicates.
    var actionIDs: [String] {
        switch self {
        case .button(let id, _, _, _, _, _, _), .toggle(let id, _, _, _, _), .slider(let id, _, _, _): return [id]
        case .scene(let scene): return scene.hits.map(\.id)
        default: return children.flatMap(\.actionIDs)
        }
    }

    var usesArtwork: Bool {
        if case .image(.artwork, _, _) = self { return true }
        return children.contains(where: \.usesArtwork)
    }

    var depth: Int { 1 + (children.map(\.depth).max() ?? 0) }
    var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }
}

struct PluginSlotContent: Equatable, Decodable {
    let slot: PluginSlot
    let node: PluginUINode
}

enum PluginRenderOutput {
    static let maxDepth = 8
    static let maxNodes = 64

    enum ValidationError: Error, Equatable {
        case duplicateSlot(PluginSlot)
        case tooDeep
        case tooManyNodes
        case duplicateActionID(String)
    }

    /// Decodes render() output: `null`, `[]` or an array of `{slot, node}`.
    static func decode(json: Data) throws -> [PluginSlotContent] {
        let contents = try JSONDecoder().decode([PluginSlotContent]?.self, from: json) ?? []
        var seenSlots = Set<PluginSlot>()
        var seenIDs = Set<String>()
        var total = 0
        for content in contents {
            guard seenSlots.insert(content.slot).inserted else { throw ValidationError.duplicateSlot(content.slot) }
            guard content.node.depth <= maxDepth else { throw ValidationError.tooDeep }
            total += content.node.nodeCount
            guard total <= maxNodes else { throw ValidationError.tooManyNodes }
            for id in content.node.actionIDs {
                guard seenIDs.insert(id).inserted else { throw ValidationError.duplicateActionID(id) }
            }
        }
        return contents
    }
}

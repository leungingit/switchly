import Foundation

enum PluginPreviewArtifactBuilder {
    static func actions(pluginID: String, slots: [PluginSlotContent]) -> PluginPreviewArtifactActions {
        PluginPreviewArtifactActions(schemaVersion: 1, actions: slots.flatMap { actions(pluginID: pluginID, node: $0.node) })
    }

    private static func actions(pluginID: String, node: PluginUINode) -> [PluginPreviewArtifactAction] {
        switch node {
        case .button(let id, _, _, _, _, let enabled, _):
            return [PluginPreviewArtifactAction(pluginID: pluginID, actionID: id, value: nil, enabled: enabled)]
        case .toggle(let id, _, _, let isOn, _):
            return [PluginPreviewArtifactAction(pluginID: pluginID, actionID: id, value: .bool(isOn), enabled: true)]
        case .slider(let id, let value, _, _):
            return [PluginPreviewArtifactAction(pluginID: pluginID, actionID: id, value: .number(value), enabled: true)]
        case .scene(let scene):
            return scene.hits.map { PluginPreviewArtifactAction(pluginID: pluginID, actionID: $0.id, value: nil, enabled: true) }
        case .scene3d(let scene):
            return scene.hits.map { PluginPreviewArtifactAction(pluginID: pluginID, actionID: $0.id,
                                                                value: $0.value.map(PluginPreviewArtifactValue.number),
                                                                enabled: $0.enabled) }
        default:
            return node.children.flatMap { actions(pluginID: pluginID, node: $0) }
        }
    }
}

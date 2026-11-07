//
//  Scene3DAccessibilityModel.swift
//  Switchly
//
//  T05: an independent accessibility tree for `scene3d`. VoiceOver must not
//  depend on the rasterised surface texture, so the model is built from the
//  declared text, hits and the view-reset control. Labels are injected by the
//  caller so the host and preview use their own localisation.
//

import Foundation

enum Scene3DAccessibilityModel {
    enum Role: String, Equatable {
        case text
        case button
        case toggle
        case reset
    }

    struct TextSource: Equatable {
        var id: String
        var label: String
        var value: String

        init(id: String, label: String, value: String) {
            self.id = id
            self.label = label
            self.value = value
        }
    }

    struct Element: Equatable {
        var id: String
        var role: Role
        var label: String
        var value: String?
        /// `nil` means the element is informational or currently disabled.
        var actionID: String?
        var isEnabled: Bool
        /// Current state for toggle roles (for example "liked").
        var isSelected: Bool
    }

    static let resetViewElementID = "scene3d.resetView"

    /// Declared order: surface text first, then hit targets, then reset. Text
    /// elements are informational; disabled hits stay discoverable but expose
    /// no action. Duplicate element IDs are dropped to keep one AX node per
    /// semantic item.
    static func elements(texts: [TextSource],
                        hits: [Scene3DHitRouter.Hit],
                        resetViewLabel: String) -> [Element] {
        var seen = Set<String>()
        var elements: [Element] = []

        for text in texts where seen.insert(text.id).inserted {
            elements.append(Element(id: text.id,
                                    role: .text,
                                    label: text.label,
                                    value: text.value,
                                    actionID: nil,
                                    isEnabled: true,
                                    isSelected: false))
        }

        for hit in hits {
            let id = "hit." + hit.actionID
            guard seen.insert(id).inserted else { continue }
            elements.append(Element(id: id,
                                    role: hit.isToggle ? .toggle : .button,
                                    label: hit.label,
                                    value: nil,
                                    actionID: hit.enabled ? hit.actionID : nil,
                                    isEnabled: hit.enabled,
                                    isSelected: hit.selected))
        }

        guard seen.insert(resetViewElementID).inserted else { return elements }
        elements.append(Element(id: resetViewElementID,
                                role: .reset,
                                label: resetViewLabel,
                                value: nil,
                                actionID: resetViewElementID,
                                isEnabled: true,
                                isSelected: false))
        return elements
    }
}

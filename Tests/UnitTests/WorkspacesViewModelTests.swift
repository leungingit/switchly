import AppKit
import Combine
import XCTest
@testable import Switchly

final class WorkspacesViewModelTests: XCTestCase {
    @MainActor
    func testAppearanceNotificationPreservesWorkspaceEditingState() async throws {
        let suiteName = "com.switchly.tests.WorkspacesViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsService = SettingsService(defaults: defaults)
        var savedSettings = AppSettings.default
        savedSettings.workspaces = [Workspace(name: "已保存工作区")]
        try settingsService.saveSettings(savedSettings)

        let viewModel = WorkspacesViewModel(
            settingsService: settingsService,
            shortcutService: WorkspaceTestShortcutService()
        )
        let selectedID = viewModel.selectedWorkspaceID
        viewModel.settings.workspaces[0].name = "正在编辑的工作区"
        viewModel.errorMessage = "保留当前错误状态"

        let updated = expectation(description: "外观设置实时同步")
        let observation = viewModel.$settings
            .first { $0.preferencesGlassOpacity == 0.24 }
            .sink { _ in updated.fulfill() }
        defer { observation.cancel() }

        // 外部保存保留旧工作区，通知只能更新模型中的外观字段。
        savedSettings.preferencesGlassOpacity = 0.24
        savedSettings.crystalMaterial.topSheenOpacity = 0.31
        try settingsService.saveSettings(savedSettings)
        await fulfillment(of: [updated], timeout: 2)

        XCTAssertEqual(viewModel.settings.preferencesGlassOpacity, 0.24)
        XCTAssertEqual(viewModel.settings.crystalMaterial, savedSettings.crystalMaterial)
        XCTAssertEqual(viewModel.settings.theme, savedSettings.theme)
        XCTAssertEqual(viewModel.settings.workspaces[0].name, "正在编辑的工作区")
        XCTAssertEqual(viewModel.selectedWorkspaceID, selectedID)
        XCTAssertEqual(viewModel.errorMessage, "保留当前错误状态")
    }
}

private final class WorkspaceTestShortcutService: ShortcutServiceProtocol {
    func setupGlobalShortcuts() {}
    func registerShortcut(for app: MonitoredApp, key: String) {}
    func unregisterShortcut(for app: MonitoredApp) {}
    func updateGlobalShortcut(_ key: String?) {}
    func unregisterAllShortcuts() {}
}

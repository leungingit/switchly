//
//  StatusBarViewModel.swift
//  Switchly
//
//  ViewModel for status bar item
//

import Foundation
import Combine
import AppKit

class StatusBarViewModel: ObservableObject {
    @Published var isPreferencesOpen: Bool = false
    @Published var isPreviewOpen: Bool = false
    
    private let settingsService: SettingsServiceProtocol
    private var cancellables = Set<AnyCancellable>()
    
    init(settingsService: SettingsServiceProtocol = SettingsService.shared) {
        self.settingsService = settingsService
        setupObservers()
    }
    
    func openPreferences() {
        isPreferencesOpen = true
    }
    
    func closePreferences() {
        isPreferencesOpen = false
    }
    
    func togglePreview() {
        NotificationCenter.default.post(name: .togglePreview, object: nil)
    }
    
    func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func setupObservers() {
        NotificationCenter.default.publisher(for: .togglePreview)
            .sink { [weak self] _ in
                self?.isPreviewOpen.toggle()
            }
            .store(in: &cancellables)
    }
}

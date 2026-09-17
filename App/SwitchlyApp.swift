//
//  SwitchlyApp.swift
//  Switchly
//
//  Main application entry point
//

import SwiftUI
import AppKit

@main
struct SwitchlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // Route the standard "Settings…" menu item (and Cmd+,) to the
            // custom glass preferences window instead of the empty SwiftUI
            // Settings scene, which renders as a plain white window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openPreferences, object: nil)
                }
            }
        }
    }
}

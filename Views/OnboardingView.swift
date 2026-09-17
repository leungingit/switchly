//
//  OnboardingView.swift
//  Switchly
//
//  First launch permission onboarding window
//

import SwiftUI
import AppKit
import CoreGraphics

// MARK: - OnboardingWindow

class OnboardingWindow {
    private static var window: NSWindow?
    private static let completedKey = "com.switchly.onboardingCompleted"

    static func shouldShow() -> Bool {
        !UserDefaults.standard.bool(forKey: completedKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
        AppLogger.info("Onboarding marked as completed")
    }

    static func show() {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.center()
        w.title = ""
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: OnboardingView {
            OnboardingWindow.close()
        })

        window = w
        Motion.fadeInWindow(w)
        NSApp.activate(ignoringOtherApps: true)
        AppLogger.info("Onboarding window shown")
    }

    static func close() {
        markCompleted()
        window?.close()
        window = nil
        AppLogger.info("Onboarding window closed")
    }
}

// MARK: - OnboardingView

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var isAccessibilityGranted = false
    @State private var isScreenCaptureGranted = false
    @State private var language = SettingsService.shared.loadSettings().language

    private var allGranted: Bool {
        isAccessibilityGranted && isScreenCaptureGranted
    }

    private var grantedCount: Int {
        (isAccessibilityGranted ? 1 : 0) + (isScreenCaptureGranted ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                }

                Text(t("Welcome to Switchly"))
                    .font(.title.weight(.bold))

                Text(t("Switchly needs two permissions to work properly."))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Permission cards
            VStack(spacing: 12) {
                permissionCard(
                    icon: "hand.raised.fill",
                    title: t("Accessibility"),
                    subtitle: t("Used to focus, switch and manage application windows."),
                    isGranted: isAccessibilityGranted,
                    action: {
                        AccessibilityService.shared.requestPermission()
                        AccessibilityService.shared.openAccessibilityPreferences()
                        refreshAfterDelay()
                    }
                )

                permissionCard(
                    icon: "video.fill",
                    title: t("Screen Recording"),
                    subtitle: t("Used to capture window thumbnails for preview."),
                    isGranted: isScreenCaptureGranted,
                    action: {
                        _ = CGRequestScreenCaptureAccess()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                        refreshAfterDelay()
                    }
                )
            }

            Spacer()

            // Footer
            VStack(spacing: 10) {
                if !allGranted {
                    HStack(spacing: 8) {
                        Text(t("Grant permissions above to continue"))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if grantedCount > 0 {
                            ProgressView(value: Double(grantedCount), total: 2)
                                .progressViewStyle(.linear)
                                .frame(width: 56)
                                .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.stateDuration)), value: grantedCount)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(t("Refresh Status")) {
                        refreshStatus()
                    }

                    Button(t("Get Started")) {
                        onComplete()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allGranted)
                }
            }
        }
        .padding(32)
        .frame(width: 480, height: 420)
        .onAppear {
            refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    private func permissionCard(
        icon: String,
        title: String,
        subtitle: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.semibold))

                    PermissionStatusBadge(isGranted: isGranted)

                    Text(isGranted ? t("Granted") : t("Not Granted"))
                        .font(.caption.weight(.medium))
                        .foregroundColor(isGranted ? .green : .orange)
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(t("Open Settings"), action: action)
                .disabled(isGranted)
        }
        .padding(14)
        .liquidGlass(
            isActive: true,
            opacity: 0.08,
            cornerRadius: DesignTokens.Radius.card,
            tintColor: Color(nsColor: .controlBackgroundColor),
            interactive: false,
            fallbackColor: Color(nsColor: .controlBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .stroke(isGranted ? Color.green.opacity(0.3) : Color(nsColor: .separatorColor), lineWidth: DesignTokens.hairline)
        )
        // Border + status text cross-fade when the permission flips.
        .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.stateDuration)), value: isGranted)
    }

    private func refreshStatus() {
        withAnimation(MotionTokens.animated(.easeOut(duration: MotionTokens.stateDuration))) {
            isAccessibilityGranted = AccessibilityService.shared.checkPermissionStatus()
            isScreenCaptureGranted = CGPreflightScreenCaptureAccess()
        }
    }

    private func refreshAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            refreshStatus()
        }
    }

    private func t(_ key: String) -> String {
        language.localizedString(key)
    }
}

// MARK: - Permission status badge

/// Status badge for a permission card: a checkmark that draws itself when
/// the permission flips to granted (path trim animation), or a warning
/// triangle while it is still missing.
private struct PermissionStatusBadge: View {
    let isGranted: Bool

    @State private var checkTrim: CGFloat = 0

    var body: some View {
        ZStack {
            if isGranted {
                Circle()
                    .stroke(Color.green, lineWidth: 1.5)
                    .frame(width: 16, height: 16)

                CheckmarkShape()
                    .trim(from: 0, to: checkTrim)
                    .stroke(
                        Color.green,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
            }
        }
        .onAppear {
            checkTrim = isGranted ? 1 : 0
        }
        .onChange(of: isGranted) { granted in
            guard granted, !MotionTokens.reduceMotion else {
                checkTrim = granted ? 1 : 0
                return
            }
            checkTrim = 0
            withAnimation(MotionTokens.animated(.easeOut(duration: MotionTokens.stateDuration))) {
                checkTrim = 1
            }
        }
    }
}

/// Checkmark path sized to a 16×16 box.
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.22, y: rect.height * 0.53))
        path.addLine(to: CGPoint(x: rect.width * 0.42, y: rect.height * 0.72))
        path.addLine(to: CGPoint(x: rect.width * 0.80, y: rect.height * 0.28))
        return path
    }
}

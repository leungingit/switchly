//
//  WindowAttribution.swift
//  Switchly
//
//  Unified answer to "which product does this Dock icon / window belong to?".
//
//  Several apps ship nested app bundles inside their own bundle. WeChat, for
//  example, runs `WeChat.app/Contents/MacOS/WeChatAppEx.app` as a separate
//  .regular process, so macOS gives it its own Dock icon — but the article /
//  mini-program windows it opens are frequently owned by the *host* process or
//  by helper processes deeper in the same bundle tree. Matching windows against
//  an exact bundle URL then finds nothing for the nested icon and the preview
//  wrongly shows "No windows" (the same class of bug NoMachine hit: several
//  processes under one product, each owning its own windows).
//
//  The rule used everywhere is therefore: resolve a bundle URL to its *product
//  root* — the nearest enclosing `.app` directory (itself, when already a
//  top-level app) — and consider a process part of that product when its own
//  bundle or executable URL lives at-or-under the root. Nested helper / mini
//  program processes stay inside their containing app instead of leaking
//  windows or reporting "no windows", with no per-app exceptions.
//

import Foundation
import AppKit

enum WindowAttribution {
    /// Returns the nearest enclosing `.app` bundle for a bundle URL, or the URL
    /// itself when it is not nested inside another app's bundle.
    ///
    /// - `/Applications/WeChat.app` → `/Applications/WeChat.app`
    /// - `/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app`
    ///   → `/Applications/WeChat.app`
    static func productRootURL(for bundleURL: URL?) -> URL? {
        guard let bundleURL else { return nil }
        let standardized = bundleURL.standardizedFileURL

        // Walk up from the bundle's parent until an ancestor that is itself an
        // app bundle (path extension ".app") is found.
        var current = standardized.deletingLastPathComponent()
        while current.path != "/" {
            if current.pathExtension.lowercased() == "app" {
                return current
            }
            current.deleteLastPathComponent()
        }
        return standardized
    }

    /// Whether a process's own bundle (falling back to its executable) lives
    /// at-or-under the given product root.
    static func process(_ app: NSRunningApplication, belongsTo productRoot: URL) -> Bool {
        let rootPath = productRoot.standardizedFileURL.path
        let path = (app.bundleURL ?? app.executableURL)?.standardizedFileURL.path ?? ""
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}

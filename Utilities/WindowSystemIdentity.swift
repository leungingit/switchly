import AppKit
import ApplicationServices

/// 私有接口仅作为可选能力；缺失时保留原有属性读取和当前屏幕降级。
enum WindowSystemIdentity {
    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let axHandle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY | RTLD_LOCAL)
    private static let windowIDFunction: WindowIDFunction? = {
        guard let handle = axHandle, let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowIDFunction.self)
    }()

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var number: CGWindowID = 0
        if let function = windowIDFunction, function(element, &number) == .success, number != 0 {
            return number
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXWindowNumber" as CFString, &value) == .success,
              let value = value as? NSNumber else { return nil }
        return value.uint32Value
    }
}

/// 每次快照读取一次活动桌面；未知归属不猜成当前桌面或其他桌面。
struct WindowSpaceSnapshot {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Displays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias Membership = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
    private let connection: Int32
    private let activeSpaces: Set<UInt64>
    private let membership: Membership?

    init() {
        guard let handle = Self.handle,
              let connectionSymbol = dlsym(handle, "SLSMainConnectionID"),
              let displaysSymbol = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let membershipSymbol = dlsym(handle, "SLSCopySpacesForWindows") else {
            connection = 0; activeSpaces = []; membership = nil
            return
        }
        connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
        membership = unsafeBitCast(membershipSymbol, to: Membership.self)
        let displays = unsafeBitCast(displaysSymbol, to: Displays.self)(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
        activeSpaces = Set(displays.compactMap {
            (($0["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
        })
    }

    func isOnCurrentSpace(_ id: CGWindowID) -> Bool? {
        guard !activeSpaces.isEmpty, let membership,
              let spaces = membership(connection, 7, [id] as CFArray)?.takeRetainedValue() as? [NSNumber],
              !spaces.isEmpty else { return nil }
        return spaces.contains { activeSpaces.contains($0.uint64Value) }
    }
}

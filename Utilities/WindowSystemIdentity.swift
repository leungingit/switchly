import AppKit
import ApplicationServices
import Carbon

/// 私有接口仅作为可选能力；缺失时保留原有属性读取和当前屏幕降级。
enum WindowSystemIdentity {
    private typealias ProcessLookup = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias FrontWindow = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private static let skyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
    private static let userInitiatedFront: UInt32 = 0x200

    private typealias PostEvent = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias RemoteElement = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let remoteTokenMagic: Int32 = 0x636f636f
    private static let remoteElementScanLimit: UInt64 = 1000

    /// 只按精确窗口 ID 请求系统前置并设为 key window；调用成功仍需由 AX／CG 验证最终焦点。
    /// 仅前置不会切换到目标所在桌面，需再对该窗口执行 AXRaise。
    static func requestFront(_ window: WindowInfo) -> Bool {
        guard let axHandle, let skyLightHandle,
              let lookupSymbol = dlsym(axHandle, "GetProcessForPID"),
              let frontSymbol = dlsym(skyLightHandle, "_SLPSSetFrontProcessWithOptions"),
              let postSymbol = dlsym(skyLightHandle, "SLPSPostEventRecordTo") else { return false }
        var process = ProcessSerialNumber()
        let lookup = unsafeBitCast(lookupSymbol, to: ProcessLookup.self)
        guard lookup(window.ownerPID, &process) == noErr,
              unsafeBitCast(frontSymbol, to: FrontWindow.self)(&process, window.id, userInitiatedFront) == .success else { return false }
        var record = [UInt8](repeating: 0, count: 0x100)
        record[0x04] = 0xf8
        record[0x3a] = 0x10
        withUnsafeBytes(of: window.id) { for index in 0..<4 { record[0x3c + index] = $0[index] } }
        for index in 0x20..<0x30 { record[index] = 0xff }
        let post = unsafeBitCast(postSymbol, to: PostEvent.self)
        for kind: UInt8 in [0x01, 0x02] {
            record[0x08] = kind
            _ = post(&process, &record)
        }
        return true
    }

    private struct RemoteKey: Hashable {
        let pid: pid_t
        let windowID: CGWindowID
    }
    private static let remoteCacheLimit = 64
    private static let remoteCacheLock = NSLock()
    private static var remoteCache: [RemoteKey: AXUIElement] = [:]

    /// 聚焦失败后丢弃缓存，下次重新枚举。
    static func forgetRemoteAXWindow(pid: pid_t, windowID: CGWindowID) {
        remoteCacheLock.lock()
        remoteCache[RemoteKey(pid: pid, windowID: windowID)] = nil
        remoteCacheLock.unlock()
    }

    /// 其他桌面的窗口不在 kAXWindows 中；按远程令牌枚举应用的 AX 元素，只返回窗口 ID 精确相等者。
    /// 命中缓存时仍校验元素当前指向同一窗口 ID，窗口关闭或 PID 复用后自动失效。
    static func remoteAXWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        let key = RemoteKey(pid: pid, windowID: windowID)
        remoteCacheLock.lock()
        let cached = remoteCache[key]
        remoteCacheLock.unlock()
        if let cached {
            if self.windowID(cached) == windowID { return cached }
            forgetRemoteAXWindow(pid: pid, windowID: windowID)
        }
        guard let element = scanRemoteAXWindow(pid: pid, windowID: windowID) else { return nil }
        remoteCacheLock.lock()
        if remoteCache.count >= remoteCacheLimit { remoteCache.removeAll() }
        remoteCache[key] = element
        remoteCacheLock.unlock()
        return element
    }

    private static func scanRemoteAXWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        guard let axHandle, let symbol = dlsym(axHandle, "_AXUIElementCreateWithRemoteToken") else { return nil }
        let create = unsafeBitCast(symbol, to: RemoteElement.self)
        for elementID in 0..<remoteElementScanLimit {
            var token = Data(count: 20)
            token.withUnsafeMutableBytes {
                $0.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
                $0.storeBytes(of: remoteTokenMagic, toByteOffset: 8, as: Int32.self)
                $0.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self)
            }
            if let element = create(token as CFData)?.takeRetainedValue(), self.windowID(element) == windowID {
                return element
            }
        }
        return nil
    }

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

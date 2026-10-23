//
//  MultitouchSupportBridge.swift
//  Switchly
//
//  Runtime bridge to the private MultitouchSupport framework.
//
//  The framework is opened with dlopen and every entry point resolved with
//  dlsym, so a missing symbol is an "unavailable" state, never a link-time
//  dependency and never a crash (docs/desktop-grid-design-spec.md §12,
//  docs/desktop-grid-evaluation-2026-10-21.md §11.1/§11.6).
//
//  Touch records are read by byte offset instead of a mirrored Swift struct:
//  the 96-byte layout comes from the verified probe
//  (docs/research/desktop-grid/control-fixture/gesture-probe.m) and a Swift
//  struct's layout is not a C layout contract. Offsets are asserted against
//  the known field order in `MTTouchLayout`.
//

import Foundation
import CoreGraphics
import Darwin

/// One contact frame reduced to what the recogniser needs.
struct TrackpadTouchFrame: Equatable {
    /// Active contacts (making/touching), not the raw record count.
    let fingers: Int
    /// Centroid of the active contacts in normalised 0…1 surface coordinates
    /// with y up, or `.zero` when no contact is active.
    let normalizedCentroid: CGPoint
    /// Device timestamp in seconds. Only differences are meaningful.
    let timestamp: TimeInterval
    /// Identity of the reporting device, so one recogniser can ignore frames
    /// from a second device (the probe enumerated an extra non-built-in one).
    let deviceKey: UInt
}

/// One multitouch device as reported by `MTDeviceCreateList`.
struct MultitouchDevice: Equatable {
    let index: Int
    /// Identity of the device pointer, matching `TrackpadTouchFrame.deviceKey`
    /// so a frame can be mapped back to its physical surface size.
    let key: UInt
    let deviceID: UInt64
    let isBuiltIn: Bool
    let familyID: Int
    let surfaceSizeMM: CGSize
    let isRunning: Bool
}

/// Byte offsets inside the 96-byte `MTTouch` record. See the probe's
/// `_Static_assert(sizeof(MTTouch) == 96)`; the order below is the probe's
/// declaration order.
enum MTTouchLayout {
    static let recordSize = 96
    static let state = 20          // int32, 3 = making, 4 = touching
    static let normalizedX = 32    // float, 0…1
    static let normalizedY = 36    // float, 0…1, y up
}

/// Thin, testable wrapper around the private framework.
///
/// Only one listener may be active at a time: the C callback carries no user
/// info, so the bridge keeps a single handler behind a lock. The service is
/// the only owner and always stops before another starts.
final class MultitouchSupportBridge {
    typealias DeviceRef = UnsafeMutableRawPointer

    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterCallback = @convention(c) (DeviceRef?, MTRawCallback?) -> Int32
    private typealias UnregisterCallback = @convention(c) (DeviceRef?, MTRawCallback?) -> Void
    private typealias DeviceStart = @convention(c) (DeviceRef?, Int32) -> Int32
    private typealias DeviceStop = @convention(c) (DeviceRef?) -> Void
    private typealias GetDeviceID = @convention(c) (DeviceRef?, UnsafeMutablePointer<UInt64>?) -> Int32
    private typealias IsBuiltIn = @convention(c) (DeviceRef?) -> Bool
    private typealias IsRunning = @convention(c) (DeviceRef?) -> Bool
    private typealias GetFamilyID = @convention(c) (DeviceRef?, UnsafeMutablePointer<Int32>?) -> Int32
    private typealias GetSurfaceDimensions = @convention(c) (DeviceRef?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32

    private var handle: UnsafeMutableRawPointer?
    private var createList: CreateList?
    private var registerCallback: RegisterCallback?
    private var unregisterCallback: UnregisterCallback?
    private var deviceStart: DeviceStart?
    private var deviceStop: DeviceStop?
    private var getDeviceID: GetDeviceID?
    private var isBuiltIn: IsBuiltIn?
    private var isRunning: IsRunning?
    private var getFamilyID: GetFamilyID?
    private var getSurfaceDimensions: GetSurfaceDimensions?

    /// Devices stay alive for the lifetime of the list; they are not released
    /// individually (the probe found that double-releases).
    private var deviceList: CFArray?

    let isAvailable: Bool

    init(frameworkPath: String = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport") {
        handle = dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL)
        guard let handle else {
            isAvailable = false
            AppLogger.warning("Trackpad gestures unavailable. reason=dlopen_failed")
            return
        }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        createList = symbol("MTDeviceCreateList", as: CreateList.self)
        registerCallback = symbol("MTRegisterContactFrameCallback", as: RegisterCallback.self)
        unregisterCallback = symbol("MTUnregisterContactFrameCallback", as: UnregisterCallback.self)
        deviceStart = symbol("MTDeviceStart", as: DeviceStart.self)
        deviceStop = symbol("MTDeviceStop", as: DeviceStop.self)
        getDeviceID = symbol("MTDeviceGetDeviceID", as: GetDeviceID.self)
        isBuiltIn = symbol("MTDeviceIsBuiltIn", as: IsBuiltIn.self)
        isRunning = symbol("MTDeviceIsRunning", as: IsRunning.self)
        getFamilyID = symbol("MTDeviceGetFamilyID", as: GetFamilyID.self)
        getSurfaceDimensions = symbol("MTDeviceGetSensorSurfaceDimensions", as: GetSurfaceDimensions.self)

        // Start/stop/register alone are not enough: without the surface size
        // the millimetre threshold would be guessed.
        isAvailable = createList != nil
            && registerCallback != nil
            && unregisterCallback != nil
            && deviceStart != nil
            && deviceStop != nil
            && getSurfaceDimensions != nil

        if !isAvailable {
            AppLogger.warning("Trackpad gestures unavailable. reason=missing_symbol")
        }
    }

    deinit {
        stopAll()
        if let handle {
            dlclose(handle)
        }
    }

    // MARK: - Devices

    func devices() -> [MultitouchDevice] {
        guard isAvailable, let createList else { return [] }
        let list = createList()?.takeRetainedValue()
        deviceList = list
        guard let list else { return [] }

        return (0..<CFArrayGetCount(list)).compactMap { index in
            guard let raw = CFArrayGetValueAtIndex(list, index) else { return nil }
            let device = UnsafeMutableRawPointer(mutating: raw)
            return info(for: device, index: index)
        }
    }

    private func info(for device: DeviceRef, index: Int) -> MultitouchDevice {
        var deviceID: UInt64 = 0
        var familyID: Int32 = -1
        var width: Int32 = 0
        var height: Int32 = 0
        _ = getDeviceID?(device, &deviceID)
        _ = getFamilyID?(device, &familyID)
        _ = getSurfaceDimensions?(device, &width, &height)

        return MultitouchDevice(
            index: index,
            key: UInt(bitPattern: device),
            deviceID: deviceID,
            isBuiltIn: isBuiltIn?(device) ?? false,
            familyID: Int(familyID),
            surfaceSizeMM: CGSize(width: Double(width) / 100, height: Double(height) / 100),
            isRunning: isRunning?(device) ?? false
        )
    }

    // MARK: - Start / stop

    /// Registers `handler` and starts every enumerated device.
    ///
    /// - Returns: the devices that actually started. Empty means the caller
    ///   should degrade to the menu / ⌃1–9 path.
    @discardableResult
    func start(handler: @escaping (TrackpadTouchFrame) -> Void) -> [MultitouchDevice] {
        guard isAvailable, let registerCallback, let deviceStart else { return [] }

        Self.shared.set(handler)

        let all = devices()
        guard !all.isEmpty, let list = deviceList else {
            AppLogger.warning("Trackpad gestures unavailable. reason=no_device")
            return []
        }

        var started: [MultitouchDevice] = []
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            let registered = registerCallback(device, Self.frameCallback)
            let result = deviceStart(device, 0)
            guard registered != 0, result == 0 else {
                AppLogger.warning(
                    "Trackpad device did not start. index=\(index), registered=\(registered), startResult=\(result)"
                )
                continue
            }
            if let info = all.first(where: { $0.index == index }) {
                started.append(info)
            }
        }

        if started.isEmpty {
            Self.shared.set(nil)
        }
        return started
    }

    /// Stops and unregisters every device. Safe to call when not running.
    func stopAll() {
        guard let deviceStop, let list = deviceList else {
            Self.shared.set(nil)
            return
        }

        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            deviceStop(device)
            unregisterCallback?(device, Self.frameCallback)
        }

        // Wait for an in-flight callback to finish before the handler goes
        // away; the callback takes the same lock.
        Self.shared.set(nil)
    }

    // MARK: - Callback

    /// C entry point. Reads the frame by byte offset and forwards it.
    private static let frameCallback: MTRawCallback = { device, touches, count, timestamp, _ in
        guard let touches, count > 0 else { return 0 }
        let base = UnsafeRawPointer(touches)

        var active = 0
        var sumX: Float = 0
        var sumY: Float = 0
        for index in 0..<Int(count) {
            let record = base + index * MTTouchLayout.recordSize
            let state = record.load(fromByteOffset: MTTouchLayout.state, as: Int32.self)
            guard state == 3 || state == 4 else { continue }
            active += 1
            sumX += record.load(fromByteOffset: MTTouchLayout.normalizedX, as: Float.self)
            sumY += record.load(fromByteOffset: MTTouchLayout.normalizedY, as: Float.self)
        }

        let centroid = active > 0
            ? CGPoint(x: Double(sumX / Float(active)), y: Double(sumY / Float(active)))
            : .zero
        let frame = TrackpadTouchFrame(
            fingers: active,
            normalizedCentroid: centroid,
            timestamp: timestamp,
            deviceKey: device.map { UInt(bitPattern: $0) } ?? 0
        )
        MultitouchSupportBridge.deliver(frame)
        return 0
    }

    private static let shared = SharedHandler()

    private static func deliver(_ frame: TrackpadTouchFrame) {
        shared.deliver(frame)
    }

    /// Holds the current handler for the C callback, which cannot capture.
    private final class SharedHandler {
        private let lock = NSLock()
        private var handler: ((TrackpadTouchFrame) -> Void)?

        func set(_ handler: ((TrackpadTouchFrame) -> Void)?) {
            lock.lock()
            self.handler = handler
            lock.unlock()
        }

        func deliver(_ frame: TrackpadTouchFrame) {
            lock.lock()
            let handler = self.handler
            lock.unlock()
            handler?(frame)
        }
    }
}

/// C callback signature from the probe:
/// `int (*)(MTDeviceRef, MTTouch *, int, double, int)`.
typealias MTRawCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

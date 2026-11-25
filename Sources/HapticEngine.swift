// Trackpad motor access adapted from NoSpeaker Studio.
import Combine
import Darwin
import Foundation

final class StopFlag {
    private let lock = NSLock()
    private var _set = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return _set }
    func set() { lock.lock(); _set = true; lock.unlock() }
}

#if APP_STORE
final class HapticEngine: ObservableObject {}
#else
final class HapticEngine: ObservableObject {
    // Published state for the UI.
    @Published private(set) var isConnected = false
    @Published private(set) var motorInfo = "Trackpad disconnected"
    @Published private(set) var statusMessage = ""

    // Access to the private framework is serialized by MusicPlayback.
    private let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)

    private func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let mt, let p = dlsym(mt, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
    typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
    typealias ActuatorClose = @convention(c) (CFTypeRef) -> Int32
    typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
    typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32
    private lazy var createList = sym("MTDeviceCreateList", CreateList.self)
    private lazy var getID = sym("MTDeviceGetDeviceID", GetID.self)
    private lazy var isBuiltIn = sym("MTDeviceIsBuiltIn", IsBuiltIn.self)
    private lazy var actuatorCreate = sym("MTActuatorCreateFromDeviceID", ActuatorCreate.self)
    private lazy var actuatorOpen = sym("MTActuatorOpen", ActuatorOpen.self)
    private lazy var actuatorClose = sym("MTActuatorClose", ActuatorClose.self)
    private lazy var actuationCreate = sym("MTActuationCreateFromDictionary", ActuationCreate.self)
    private lazy var actuationPlay = sym("MTActuationActuate", ActuationPlay.self)
    private var motor: CFTypeRef?

    /// Reopens the trackpad motor and publishes the connection result.
    func connect(preferExternal: Bool) {
        if let motor { _ = actuatorClose?(motor) }
        motor = nil
        let result = openMotor(preferExternal: preferExternal)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = result.connected
            self.motorInfo = result.connected ? result.message : "Trackpad disconnected"
            self.statusMessage = result.connected ? "" : result.message
        }
    }

    private func openMotor(preferExternal: Bool) -> (connected: Bool, message: String) {
        guard let createList, let getID, let actuatorCreate, let actuatorOpen,
              actuationCreate != nil, actuationPlay != nil else {
            return (false, "Trackpad haptics are unavailable on this version of macOS.")
        }
        guard let list = createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else {
            return (false, "No trackpad was found. Connect a Magic Trackpad 2 or newer and try again.")
        }
        var ids: [(id: UInt64, builtIn: Bool)] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            if getID(dev, &id) == 0 { ids.append((id, isBuiltIn?(dev) ?? false)) }
        }
        let candidates: [(id: UInt64, builtIn: Bool)]
        if preferExternal {
            candidates = ids.filter { !$0.builtIn }
        } else {
            candidates = ids.sorted { $0.builtIn && !$1.builtIn }
        }
        for d in candidates {
            if let ref = actuatorCreate(d.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 {
                motor = ref
                return (true, d.builtIn ? "Built-in trackpad" : "Magic Trackpad")
            }
        }
        if preferExternal {
            return (false, "Switch on your Magic Trackpad, connect it to this Mac, and try again.")
        }
        return (false, "No compatible Force Touch trackpad could be opened.")
    }

    func play(_ tones: [(hz: Double, amp: Double)], ms: Double, level: Float) {
        guard let motor, !tones.isEmpty, let create = actuationCreate else { return }
        let sum = tones.reduce(0) { $0 + $1.amp }
        guard sum > 0 else { return }
        let shape: [String: Any] = [
            "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": ms],
            "Tones": tones.map {
                ["Type": "Sine", "Amplitude": $0.amp / sum, "DurationMS": ms,
                 "DelayMS": 0.0, "FrequencykHz": $0.hz / 1000]
            }
        ]
        guard let act = create(shape as CFDictionary, 0) else { return }
        let pointer = Unmanaged.passUnretained(motor).toOpaque()
        _ = actuationPlay?(act, pointer, 0, level, 0)
        Unmanaged<AnyObject>.fromOpaque(act).release()
    }
}
#endif

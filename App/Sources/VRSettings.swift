//
//  VRSettings.swift
//
//  Comfort and handedness knobs the render thread and input sources read
//  without a round trip through the engine. Lock-guarded so the window
//  (main actor) can flip them while the render thread samples them.
//
//  Handedness is one switch consulted everywhere a hand has a role: the
//  dominant hand aims and works the wheel pointer / fire; the off hand
//  moves and anchors the wheel. Default right-dominant.
//

import Foundation

final class VRSettings: @unchecked Sendable {

    static let shared = VRSettings()

    private let lock = NSLock()
    private var _rightHanded = true
    /// Eye-height trim in metres, applied on top of the recenter baseline.
    /// Calibrated live from the Comfort menu because the right value is a
    /// matter of feel per player and posture -- floor detection proved
    /// unreliable, so this is the honest knob. Vertical head motion still
    /// tracks naturally on top of it (stand up and you rise).
    private var _heightOffset: Float = 0

    var rightHanded: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _rightHanded }
        set { lock.lock(); _rightHanded = newValue; lock.unlock() }
    }

    var heightOffset: Float {
        get { lock.lock(); defer { lock.unlock() }; return _heightOffset }
        set { lock.lock(); _heightOffset = newValue; lock.unlock() }
    }

    /// True when `chirality` is the hand that aims / fires / points the
    /// wheel. The off hand moves and anchors the wheel.
    func isDominant(left: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _rightHanded ? !left : left
    }
}

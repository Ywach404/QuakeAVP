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
    private var _seated = false
    /// Metres added to the eye height in seated mode, so a seated player
    /// views the world from roughly standing height.
    private var _seatedLift: Float = 0.45

    var rightHanded: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _rightHanded }
        set { lock.lock(); _rightHanded = newValue; lock.unlock() }
    }

    var seated: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _seated }
        set { lock.lock(); _seated = newValue; lock.unlock() }
    }

    /// Vertical lift in metres, 0 when standing.
    var seatedLift: Float {
        lock.lock(); defer { lock.unlock() }
        return _seated ? _seatedLift : 0
    }

    /// True when `chirality` is the hand that aims / fires / points the
    /// wheel. The off hand moves and anchors the wheel.
    func isDominant(left: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _rightHanded ? !left : left
    }
}

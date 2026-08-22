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
    private var _heightOffset: Float = 0.4

    var rightHanded: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _rightHanded }
        set { lock.lock(); _rightHanded = newValue; lock.unlock() }
    }

    var heightOffset: Float {
        get { lock.lock(); defer { lock.unlock() }; return _heightOffset }
        set { lock.lock(); _heightOffset = newValue; lock.unlock() }
    }

    /// Swap which physical Sense controller is treated as left vs right.
    /// Chirality auto-detection is a vendor-name/connection-order guess that
    /// can land backwards; this is the honest override. Read live at slice
    /// build so toggling corrects the hands without reconnecting.
    /// Persisted: set it once and it survives relaunches, so a corrected hand
    /// assignment doesn't reset every session.
    private var _swapSenseHands = UserDefaults.standard.bool(forKey: "qavp.swapSenseHands")
    var swapSenseHands: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _swapSenseHands }
        set {
            lock.lock(); _swapSenseHands = newValue; lock.unlock()
            UserDefaults.standard.set(newValue, forKey: "qavp.swapSenseHands")
        }
    }

    /// Weapon menu as a fixed gaze-selected panel (controllers) instead of the
    /// wrist ring. The engine owns the full-menu selection/commit; this flag
    /// just tells WheelState to stand down so it doesn't also fire.
    private var _fullMenu = false
    var fullMenu: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fullMenu }
        set { lock.lock(); _fullMenu = newValue; lock.unlock() }
    }

    /// True when `chirality` is the hand that aims / fires / points the
    /// wheel. The off hand moves and anchors the wheel.
    func isDominant(left: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _rightHanded ? !left : left
    }
}

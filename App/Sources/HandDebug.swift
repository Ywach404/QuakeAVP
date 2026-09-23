//
//  HandDebug.swift
//
//  A GREEN WIREFRAME overlay of the tracked hands -- thin bones between
//  joints and a small sphere node at each joint -- so you can SEE, in the
//  headset, whether a pinch is registering instead of guessing why movement
//  "didn't pick up". HandInput publishes the bones and nodes here in
//  corrected-tracking space; the render thread maps them into the world and
//  draws them with the wheel-guide (triangle) pipeline.
//
//  A finger brightens from dim to hot green when its pinch/gesture is active,
//  and the whole hand goes hot while the wheel palm is held. When a finger
//  you are pinching stays dim, the gesture is not being detected.
//

import Foundation

final class HandDebug: @unchecked Sendable {

    static let shared = HandDebug()

    private let lock = NSLock()
    /// 7 floats per vertex (xyz in corrected tracking space + rgba), line
    /// list. Both hands concatenated.
    private var verts: [Float] = []
    private var _enabled = false

    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; if !newValue { verts = [] }; lock.unlock() }
    }

    /// Figure overlays, independent of the wireframe so they can be captured on
    /// top of the stylised oval hand: the aim-ray decomposition and the motion
    /// strobe. HandInput folds their geometry into the same published buffer.
    private var _aimRays = false
    var aimRays: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _aimRays }
        set { lock.lock(); _aimRays = newValue; lock.unlock() }
    }
    private var _strobe = false
    var strobe: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _strobe }
        set { lock.lock(); _strobe = newValue; lock.unlock() }
    }
    /// Turn-trigger meter: shows, for the active turn style, how close a snap is
    /// (plus the stick deadzone / clutch engage state).
    private var _turnDebug = false
    var turnDebug: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _turnDebug }
        set { lock.lock(); _turnDebug = newValue; lock.unlock() }
    }
    /// Fire-threshold meter: the active fire mode's live signal vs its (live-
    /// tunable) trigger threshold and fire zone, so a slider edit is visible.
    private var _fireDebug = false
    var fireDebug: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fireDebug }
        set { lock.lock(); _fireDebug = newValue; lock.unlock() }
    }

    func publish(_ v: [Float]) {
        lock.lock(); verts = v; lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return verts
    }
}

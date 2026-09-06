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

    func publish(_ v: [Float]) {
        lock.lock(); verts = v; lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return verts
    }
}

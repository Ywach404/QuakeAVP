//
//  HandDebug.swift
//
//  A wireframe overlay of the tracked hands, coloured by which gesture is
//  currently firing -- so you can SEE, in the headset, whether a pinch is
//  registering instead of guessing why movement "didn't pick up". HandInput
//  publishes the finger bones here in corrected-tracking space with a colour
//  per finger; the render thread maps them into the world and draws them
//  with the wheel-guide line pipeline.
//
//  Bone colours: a finger lights up when its pinch/gesture is active --
//  green for the movement (thumb+middle) and jump (thumb+ring) pinches,
//  blue for crouch (thumb+pinky), red for fire (index), cyan for the whole
//  hand while the wheel palm is held; dim white otherwise. When a bone you
//  are pinching stays dim, the gesture is not being detected.
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

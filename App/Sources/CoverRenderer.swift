// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  CoverRenderer.swift
//
//  A save's cover: one offscreen frame of the WORLD, drawn from where the
//  player was looking before they reached for the window, written as a JPEG
//  beside the save.
//
//  A RE-RENDER, NOT A CAPTURE, and the obvious alternative is impossible
//  rather than merely worse. A drawable's colour texture is valid only inside
//  the frame that queried it; afterwards the app holds no reference and the
//  compositor recycles it, so there is no "last frame" to keep. Even in-frame
//  it would not copy usefully: foveation warps the pixels, the layered path
//  is one array texture with two amplified slices, the textures are
//  compositor-owned, and THE RULE forbids fallible work inside the submission
//  window. Re-rendering costs one pass and is exact.
//
//  Exact because the world is FROZEN. Opening the window pauses the
//  simulation, so re-drawing the packet from a remembered pose reproduces the
//  pre-panel view rather than approximating it.
//
//  Culling is not a problem: the immersive consumer runs omnidirectional
//  (QC_RendererSetCullingFov 360), PVS-only with no frustum, so the packet
//  holds the whole visible level no matter where the head is pointing now.
//
//  THREADING. `withConsumer` is an NSLock and is not thread-affine, so this
//  runs on a background thread -- never the CompositorServices render thread,
//  which THE RULE owns, and never the main actor. `waitUntilCompleted` is
//  outside the lock.
//

import Foundation
import Metal
import QuartzCore
import UIKit
import simd

final class CoverRenderer: @unchecked Sendable {

    static let shared = CoverRenderer()

    /// Cover size. Small on purpose: it is shown at about 150pt in a deck of
    /// them, and every save carries one forever.
    static let width = 480
    static let height = 320
    /// How far before the summon to take the view from. The prayer sign
    /// dwells 0.6 s with the palms up, so anything less than that is a
    /// picture of the player's own hands.
    static let lookBack: TimeInterval = 0.8

    private let lock = NSLock()
    private var renderer: ExportRenderer?
    /// Built once and kept. Three textures and a pipeline set per save would
    /// be wasteful, and the size never changes.
    private func makeRenderer(core: RendererCore) -> ExportRenderer? {
        lock.lock(); defer { lock.unlock() }
        if let renderer { return renderer }
        renderer = ExportRenderer(core: core, width: Self.width, height: Self.height,
                                  fovXDegrees: 90)
        return renderer
    }

    /// Draw the cover for `name` and write it beside the save.
    ///
    /// Never throws into the save path and never reports failure: a save with
    /// no cover is a complete save that shows a plain card, which is exactly
    /// what every save written before this existed does. A save that failed
    /// because its picture failed would be a far worse trade.
    func write(coverFor name: String, into directory: URL) {
        // Every exit here is deliberately silent to the SAVE -- a cover can
        // never fail a save -- but silent to the log as well made "no cover
        // appeared" impossible to diagnose. Each guard says which one it was.
        func stop(_ why: String) { HandDebug.shared.log("[cover] \(name): \(why)") }

        // No pose means the immersive space was never opened this session,
        // so there is nothing to draw and nothing is wrong.
        guard let pose = HeadPoseRing.shared.coverPose() else {
            let d = HeadPoseRing.shared.debugState
            stop("no head pose -- held \(d.held), latched "
                 + (d.latched.map { String(format: "%.3f", $0) } ?? "never"))
            return
        }

        // No core means no renderer has ever come up, which is the same
        // "nothing to draw" case as no pose.
        guard let core = RendererCoordinator.shared.core else {
            stop("no renderer core")
            return
        }
        guard let renderer = makeRenderer(core: core) else {
            stop("ExportRenderer init failed")
            return
        }
        guard let queue = core.device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer()
        else {
            stop("no Metal command queue")
            return
        }

        // Somewhere to blit the private render target into, so the CPU can
        // read it. ExportRenderer's own colour texture is .private.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Self.width, height: Self.height,
            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let readback = core.device.makeTexture(descriptor: desc) else {
            stop("readback texture allocation failed")
            return
        }

        var drew = false
        var acquired = true
        let got: Void? = core.withConsumer(.immersive) {
            guard let frame = QC_RendererAcquireFrame() else { acquired = false; return }
            defer { QC_RendererReleaseFrame() }
            renderer.accumulate(frame: frame.pointee, camera: .pose(pose), weight: 1,
                                commandBuffer: cb, worldOnly: true)
            // Empty HUD: the 2D overlay is the player's kit too, and the
            // world-only flag above does not reach it.
            renderer.resolve(into: readback, hud: [], atlasTexnum: 0, commandBuffer: cb)
            drew = true
        }
        if got == nil { stop("the immersive consumer is not current (is the space open?)"); return }
        if !acquired { stop("no frame packet to draw"); return }
        guard drew else { stop("nothing drawn"); return }

        cb.commit()
        cb.waitUntilCompleted()          // outside the consumer lock

        guard let jpeg = Self.encodeJPEG(from: readback) else {
            stop("JPEG encode failed")
            return
        }
        // Written to a temporary name and moved into place, so a scan can
        // never see a half-written cover. A zero-byte .jpg reads as absent
        // by design, but a torn one would decode to nothing visible.
        let final = SaveGameHeader.coverURL(forSave:
            directory.appendingPathComponent("\(name).sav"))
        let temp = final.deletingLastPathComponent()
            .appendingPathComponent(".\(name).jpg.tmp")
        do {
            try jpeg.write(to: temp, options: .atomic)
            _ = try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: temp, to: final)
            HandDebug.shared.log("[cover] \(name): wrote \(jpeg.count) bytes -> \(final.lastPathComponent)")
        } catch {
            stop("write failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: temp)
        }
    }

    /// BGRA bytes out of Metal, JPEG in. Written in Swift rather than through
    /// the engine's own Image_WriteJPG: that would mean a new platform shim, a
    /// header declaration and an engine-thread hop to write a file from bytes
    /// already in hand here.
    private static func encodeJPEG(from texture: MTLTexture) -> Data? {
        let bytesPerRow = texture.width * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(raw) as CFData) else { return nil }
        // bgra8Unorm is little-endian 32-bit with alpha first -- noAlpha
        // because the pass clears to opaque and a cover has nothing to blend
        // against.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: texture.width, height: texture.height,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: bytesPerRow,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: info, provider: provider,
                               decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.7)
    }
}

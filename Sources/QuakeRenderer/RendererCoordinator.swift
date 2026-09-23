//
//  RendererCoordinator.swift
//
//  Owns the shared RendererCore and arbitrates which output consumes the
//  engine's frame packets. The QC_Renderer* handoff allows exactly one
//  consumer; opening the immersive space hands the stream from the window's
//  MTKView thread to the compositor render thread, and dismissing it hands
//  the stream back. Both handovers go through RendererCore.activate, so a
//  late draw callback on the losing side takes the consumer lock, sees it
//  no longer owns the stream, and returns without touching the C API.
//
//  Textures and the mirrored world geometry live in the core and survive
//  any number of open/dismiss cycles; the engine keeps ticking throughout.
//

import SwiftUI
import CompositorServices

@MainActor
@Observable
final class RendererCoordinator {

    static let shared = RendererCoordinator()

    let core: RendererCore?
    private(set) var isImmersiveActive = false
    private var immersive: ImmersiveRenderer?

    /// The flat window's delegate, shared across SwiftUI view rebuilds.
    private(set) var windowRenderer: WorldRenderer?

    /// Runs on the main actor whenever the immersive space ends -- including a
    /// crown press, which dismisses it system-side with no window left to tap.
    /// The app uses it to respawn the console window so there is always a way
    /// back into the game.
    var onImmersiveEnded: (() -> Void)?

    private init() {
        core = RendererCore()
        if let core {
            windowRenderer = WorldRenderer(
                core: core, colorPixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float)
        }
    }

    /// Entry point for the CompositorLayer renderer closure. Hands the
    /// packet stream to the immersive thread before it starts.
    func startImmersive(_ layerRenderer: LayerRenderer) {
        guard let core else { return }

        isImmersiveActive = true
        core.activate(.immersive)

        var renderer: ImmersiveRenderer!
        renderer = ImmersiveRenderer(layerRenderer: layerRenderer, core: core) {
            // Called on the immersive render thread when the layer is
            // invalidated (space dismissed); the thread exits right after.
            Task { @MainActor [renderer] in
                RendererCoordinator.shared.immersiveDidStop(renderer!)
            }
        }
        immersive = renderer
        renderer.start()
    }

    private func immersiveDidStop(_ renderer: ImmersiveRenderer) {
        // A quick dismiss-reopen can start a new session before the old
        // thread's stop callback lands on the main actor; only the current
        // renderer's stop may hand the stream back to the window.
        guard immersive === renderer else { return }
        immersive = nil
        isImmersiveActive = false
        // Hand the stream back; the window's next draw re-reports its
        // drawable size (the C side dedupes), restoring the refdef.
        core?.activate(.window)
        onImmersiveEnded?()
    }
}

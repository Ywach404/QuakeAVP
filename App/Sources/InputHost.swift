//
//  InputHost.swift
//
//  Owns the input sources for the life of the APP, not the life of a window.
//
//  They used to be @State on ContentView. The console is a WindowGroup, so
//  closing it destroys that view -- and with it the only reference to
//  HandInput and GameControllerInput. The ARKit hand session ended and the
//  controller observers went with it, which meant ALL input died the moment
//  you closed the window. That made the in-game console summon impossible by
//  construction: the gesture exists precisely for the no-window state, which
//  is exactly the state where nothing was left to detect it.
//
//  Activation is therefore driven by RendererCoordinator (which outlives
//  windows) and by controller connect/disconnect, never by a view's onChange.
//

import Foundation

/// When bare hands drive the game. Pure so the rule is testable and stated
/// once, instead of being implied by wherever it happened to be evaluated.
enum InputActivation {
    /// Hands are controllerless play: immersed, with no hardware attached.
    /// Hardware always wins.
    static func handsActive(immersive: Bool, hasController: Bool) -> Bool {
        return immersive && !hasController
    }
}

@MainActor
@Observable
final class InputHost {

    static let shared = InputHost()

    let gamepad = GameControllerInput()
    let hands: HandInput

    private init() {
        // One aggregator gates both, so hands and hardware merge before the
        // engine sees them.
        hands = HandInput(aggregator: gamepad.aggregator)
        // Re-evaluate on both edges that can change the answer, from owners
        // that outlive any window. Hooked up BEFORE start(), which attaches
        // already-connected controllers and would otherwise report into a nil
        // callback.
        gamepad.onControllerChange = { [weak self] in
            self?.refreshActive()
            // The PROFILE has to follow the hardware here too, not only in the
            // console window's .onChange: a controller connected while the
            // window is closed used to leave the hands profile active, so
            // tuning the gun rig with a controller in hand wrote into the
            // hands slots and overwrote them.
            ProfileStore.shared.refreshActiveFromInput()
            ProfileStore.shared.apply()
        }
        RendererCoordinator.shared.onImmersiveChanged = { [weak self] _ in
            self?.refreshActive()
        }
        gamepad.start()
        // The HUD live editor's own grab/move/scale input loop (Task 5):
        // idle-polls cheaply while the editor is closed, so starting it
        // once here (same lifecycle as `gamepad.start()` above) is enough
        // -- the "Edit HUD Layout" entry point only ever needs to flip
        // `HudEditor.shared.active`, never to remember to start this.
        HudEditorInput.shared.start()
        refreshActive()
    }

    func refreshActive() {
        let immersive = RendererCoordinator.shared.isImmersiveActive
        let controller = gamepad.hasPhysicalController
        let active: Bool
        if ProfileStore.shared.manualOverride {
            // A manual profile choice WINS over the hardware heuristic: picking
            // "Hands" forces bare-hand input even with controllers still paired
            // (set them down but still connected), picking "PSVR2" forces the
            // controller off hands. Without this, toggling to controllerless did
            // nothing while the Sense pair was still connected -- the exact
            // "it doesn't take" bug. Still gated on immersive.
            active = immersive && ProfileStore.shared.active == .hands
        } else {
            active = InputActivation.handsActive(immersive: immersive, hasController: controller)
        }
        // Transitions only, so it's a few lines per session. Reports the two
        // inputs to the decision, because "a controller is attached, so hands
        // stood down" and "the immersive space isn't up" look identical from
        // inside the headset: nothing happens either way.
        if active != hands.isRunning {
            print("[summon] hand input \(active ? "ACTIVE" : "inactive")"
                + " (immersive=\(immersive), controller=\(controller))")
        }
        hands.setActive(active)
    }
}

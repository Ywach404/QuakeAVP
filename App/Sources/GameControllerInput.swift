//
//  GameControllerInput.swift
//
//  Feeds GameController state to the engine. Value-changed handlers fire on
//  GameController's own queue — never the engine thread — so each change is
//  flattened into a whole-pad snapshot and pushed through QC_InputSetGamepad,
//  the any-thread half of the input handoff (the engine thread drains it in
//  IN_Commands/IN_Move). Nothing here touches any other QC_* entry point.
//
//  The observable connection state exists for the UI: the app must keep
//  working with no controller attached, and say so rather than sit silent.
//

import GameController

@Observable
@MainActor
final class GameControllerInput {

    /// Display name of the connected controller, nil when none is attached.
    private(set) var controllerName: String?

    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self.attach(controller) }
        })
        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.detach() }
        })

        if let controller = GCController.controllers().first {
            attach(controller)
        }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        controllerName = controller.vendorName ?? "Controller"
        pad.valueChangedHandler = { pad, _ in
            Self.push(pad)
        }
        Self.push(pad)
    }

    private func detach() {
        controllerName = nil
        // Zeroed snapshot so the engine's edge diff releases held buttons.
        var state = qc_gamepad_state_t()
        QC_InputSetGamepad(&state)
    }

    /// Runs on GameController's handler queue.
    private nonisolated static func push(_ pad: GCExtendedGamepad) {
        var buttons: UInt32 = 0
        func set(_ bit: some BinaryInteger, _ pressed: Bool) {
            if pressed { buttons |= UInt32(bit) }
        }
        set(QC_PAD_A, pad.buttonA.isPressed)
        set(QC_PAD_B, pad.buttonB.isPressed)
        set(QC_PAD_X, pad.buttonX.isPressed)
        set(QC_PAD_Y, pad.buttonY.isPressed)
        set(QC_PAD_LSHOULDER, pad.leftShoulder.isPressed)
        set(QC_PAD_RSHOULDER, pad.rightShoulder.isPressed)
        set(QC_PAD_MENU, pad.buttonMenu.isPressed)
        set(QC_PAD_OPTIONS, pad.buttonOptions?.isPressed ?? false)
        set(QC_PAD_LTHUMB, pad.leftThumbstickButton?.isPressed ?? false)
        set(QC_PAD_RTHUMB, pad.rightThumbstickButton?.isPressed ?? false)

        var state = qc_gamepad_state_t(
            lx: pad.leftThumbstick.xAxis.value,
            ly: pad.leftThumbstick.yAxis.value,
            rx: pad.rightThumbstick.xAxis.value,
            ry: pad.rightThumbstick.yAxis.value,
            lt: pad.leftTrigger.value,
            rt: pad.rightTrigger.value,
            buttons: buttons,
            connected: 1)
        QC_InputSetGamepad(&state)
    }
}

//
//  GameControllerInput.swift
//
//  Every physical controller funnels into one engine-facing pad snapshot.
//  Value handlers fire on GameController's own queues — never the engine
//  thread — so each source updates its slice of a lock-guarded aggregate
//  and the merged whole goes through QC_InputSetGamepad, the any-thread
//  half of the input handoff. Nothing here touches other QC_* entry points.
//
//  Two kinds of hardware:
//   - classic extended gamepads: one controller, the M4 mapping.
//   - PSVR2 Sense controllers (visionOS 26 spatial accessories): each hand
//     is its own GCController with productCategory "Spatial Controller" and
//     a per-hand profile. The pair merges into one virtual pad — left hand
//     is movement, right hand is aim/fire — with buttons mapped onto the
//     same K_* bindings the gamepad uses. Their 6DOF poses go through
//     SpatialControllerTracker; their haptics through ControllerOutput.
//
//  The element names on Sense profiles are matched by substring on purpose:
//  the exact keys aren't documented, so on connect the full element list is
//  logged once for field calibration rather than silently dropping input.
//

import GameController

@Observable
@MainActor
final class GameControllerInput {

    /// What the UI shows for the input source.
    private(set) var sourceDescription: String?
    /// True while any physical controller is attached; HandInput yields.
    private(set) var hasPhysicalController = false
    /// The spatial (Sense) controllers currently attached, for the tracker.
    private(set) var spatialControllers: [GCController] = []

    /// Shared with HandInput so hands and hardware merge through one gate.
    let aggregator = PadAggregator()
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
        ) { note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self.detach(controller) }
        })

        for controller in GCController.controllers() {
            attach(controller)
        }
    }

    private func isSpatial(_ controller: GCController) -> Bool {
        controller.productCategory == GCProductCategorySpatialController
    }

    private func attach(_ controller: GCController) {
        if isSpatial(controller) {
            // Chirality: GameController doesn't expose it directly; the
            // vendor name does ("...Left"/"...Right"). ARKit's Accessory
            // is the authority, but slice routing only needs the guess.
            let name = controller.vendorName ?? ""
            let left = name.localizedCaseInsensitiveContains("left")
                || (!name.localizedCaseInsensitiveContains("right")
                    && !spatialControllers.contains(where: { c in
                        (c.vendorName ?? "").localizedCaseInsensitiveContains("left")
                    }) && spatialControllers.isEmpty)
            spatialControllers.append(controller)
            SenseMapper.install(on: controller, left: left, into: aggregator)
            SenseMapper.logElements(of: controller)
        } else if let pad = controller.extendedGamepad {
            pad.valueChangedHandler = { [aggregator] pad, _ in
                aggregator.update(.classic, Self.classicSlice(pad))
            }
            aggregator.update(.classic, Self.classicSlice(pad))
        } else {
            return
        }

        ControllerOutput.shared.attach(controllers: physicalControllers())
        refreshStatus()
    }

    private func detach(_ controller: GCController) {
        if isSpatial(controller) {
            spatialControllers.removeAll { $0 === controller }
            aggregator.remove(SenseMapper.slice(forLeft:
                (controller.vendorName ?? "").localizedCaseInsensitiveContains("left")))
        } else {
            aggregator.remove(.classic)
        }
        ControllerOutput.shared.attach(controllers: physicalControllers())
        refreshStatus()
    }

    private func physicalControllers() -> [GCController] {
        GCController.controllers()
    }

    private func refreshStatus() {
        let spatial = spatialControllers.count
        if spatial >= 2 {
            sourceDescription = "PSVR2 Sense pair"
        } else if spatial == 1 {
            sourceDescription = "PSVR2 Sense (one hand — pair the other)"
        } else if let name = GCController.controllers()
            .first(where: { $0.extendedGamepad != nil })?.vendorName {
            sourceDescription = name
        } else {
            sourceDescription = nil
        }
        hasPhysicalController = !GCController.controllers().isEmpty
        SpatialControllerTracker.shared.setControllers(spatialControllers)
    }

    /// Runs on GameController's handler queue.
    private nonisolated static func classicSlice(_ pad: GCExtendedGamepad) -> PadAggregator.Slice {
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
        return .init(
            lx: pad.leftThumbstick.xAxis.value, ly: pad.leftThumbstick.yAxis.value,
            rx: pad.rightThumbstick.xAxis.value, ry: pad.rightThumbstick.yAxis.value,
            lt: pad.leftTrigger.value, rt: pad.rightTrigger.value,
            buttons: buttons)
    }
}

/// Merges per-source slices into the one snapshot the engine drains.
/// Any-thread; the merge and push hold one lock.
final class PadAggregator: @unchecked Sendable {

    enum Source: Hashable { case classic, senseLeft, senseRight, hands }

    struct Slice {
        var lx: Float = 0, ly: Float = 0, rx: Float = 0, ry: Float = 0
        var lt: Float = 0, rt: Float = 0
        var buttons: UInt32 = 0
    }

    private let lock = NSLock()
    private var slices: [Source: Slice] = [:]
    private var lastRT: Float = 0

    func update(_ source: Source, _ slice: Slice) {
        lock.lock()
        slices[source] = slice
        push()
        lock.unlock()
    }

    func remove(_ source: Source) {
        lock.lock()
        slices.removeValue(forKey: source)
        push()
        lock.unlock()
    }

    private func push() {
        var merged = Slice()
        for slice in slices.values {
            merged.lx = clamp(merged.lx + slice.lx)
            merged.ly = clamp(merged.ly + slice.ly)
            merged.rx = clamp(merged.rx + slice.rx)
            merged.ry = clamp(merged.ry + slice.ry)
            merged.lt = max(merged.lt, slice.lt)
            merged.rt = max(merged.rt, slice.rt)
            merged.buttons |= slice.buttons
        }
        // Fire echo for haptics: the engine's own trigger threshold.
        if lastRT < 0.35, merged.rt >= 0.35 {
            ControllerOutput.shared.noteFire()
        }
        lastRT = merged.rt

        var state = qc_gamepad_state_t(
            lx: merged.lx, ly: merged.ly, rx: merged.rx, ry: merged.ry,
            lt: merged.lt, rt: merged.rt,
            buttons: merged.buttons,
            connected: slices.isEmpty ? 0 : 1)
        QC_InputSetGamepad(&state)
    }

    private func clamp(_ v: Float) -> Float { min(max(v, -1), 1) }
}

/// Maps one PSVR2 Sense controller's per-hand profile onto its slice of the
/// virtual pad. Left hand: movement stick, run trigger, weapon-cycle face
/// buttons, create = recenter. Right hand: aim stick, fire trigger,
/// jump/use face buttons, options = menu.
private enum SenseMapper {

    static func slice(forLeft left: Bool) -> PadAggregator.Source {
        left ? .senseLeft : .senseRight
    }

    static func install(on controller: GCController, left: Bool,
                        into aggregator: PadAggregator) {
        let profile = controller.physicalInputProfile
        let source = slice(forLeft: left)
        profile.valueDidChangeHandler = { profile, _ in
            aggregator.update(source, build(profile, left: left))
        }
        aggregator.update(source, build(profile, left: left))
    }

    private static func build(_ profile: GCPhysicalInputProfile,
                              left: Bool) -> PadAggregator.Slice {
        var slice = PadAggregator.Slice()

        if let stick = dpad(profile, containing: "Thumbstick") {
            if left {
                slice.lx = stick.xAxis.value
                slice.ly = stick.yAxis.value
            } else {
                slice.rx = stick.xAxis.value
                slice.ry = stick.yAxis.value
            }
        }
        if let trigger = button(profile, containing: "Trigger") {
            if left { slice.lt = trigger.value } else { slice.rt = trigger.value }
        }

        func set(_ bit: some BinaryInteger, _ names: [String]) {
            for name in names where button(profile, containing: name)?.isPressed == true {
                slice.buttons |= UInt32(bit)
                return
            }
        }
        if left {
            // Square / triangle cycle weapons via the X/Y bindings.
            set(QC_PAD_X, ["Button X", "Square", "Button A"])
            set(QC_PAD_Y, ["Button Y", "Triangle", "Button B"])
            set(QC_PAD_LSHOULDER, ["Grip", "Shoulder"])
            set(QC_PAD_LTHUMB, ["Thumbstick Button", "Thumbstick , Button"])
            set(QC_PAD_OPTIONS, ["Create", "Share", "Options", "Menu"])
        } else {
            // Cross jumps, circle uses, via the A/B bindings.
            set(QC_PAD_A, ["Button A", "Cross"])
            set(QC_PAD_B, ["Button B", "Circle"])
            set(QC_PAD_RSHOULDER, ["Grip", "Shoulder"])
            set(QC_PAD_RTHUMB, ["Thumbstick Button", "Thumbstick , Button"])
            set(QC_PAD_MENU, ["Options", "Menu"])
        }
        return slice
    }

    private static func button(_ profile: GCPhysicalInputProfile,
                               containing fragment: String) -> GCControllerButtonInput? {
        if let exact = profile.buttons[fragment] { return exact }
        for (name, input) in profile.buttons
        where name.localizedCaseInsensitiveContains(fragment) {
            return input
        }
        return nil
    }

    private static func dpad(_ profile: GCPhysicalInputProfile,
                             containing fragment: String) -> GCControllerDirectionPad? {
        for (name, input) in profile.dpads
        where name.localizedCaseInsensitiveContains(fragment) {
            return input
        }
        return nil
    }

    /// One-time dump so a mismatched mapping is diagnosable from the log
    /// instead of presenting as dead buttons.
    static func logElements(of controller: GCController) {
        let profile = controller.physicalInputProfile
        let buttons = profile.buttons.keys.sorted().joined(separator: ", ")
        let dpads = profile.dpads.keys.sorted().joined(separator: ", ")
        print("[input] spatial controller '\(controller.vendorName ?? "?")' buttons: [\(buttons)] dpads: [\(dpads)]")
    }
}

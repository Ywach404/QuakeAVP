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
//  logged once for field calibration rather than silently dropping input --
//  to Xcode's console AND the in-headset one (SenseMapper.logElements), since
//  a mismatched mapping is exactly the kind of thing that only shows up on
//  device, away from a Mac.
//

import Foundation
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

    /// Fired after hasPhysicalController is recomputed. InputHost uses it to
    /// re-decide whether hands drive the game -- a controller connecting has to
    /// take over even with no window open to notice it.
    var onControllerChange: (() -> Void)?
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
            // Handedness from the controller's NAME first -- the AVP labels
            // the pair Left/Right, but which string carries the label is
            // undocumented, so check them all and LOG them so we can see it.
            let names = [controller.vendorName ?? "",
                         controller.productCategory,
                         String(describing: controller)]
            print("[input] spatial controller names: \(names)")
            var nameLeft: Bool?
            for s in names {
                // PSVR2 Sense names the pair "... Sense Controller (L)" / "(R)"
                // -- match the parenthesised side, and the words as a bonus.
                if s.localizedCaseInsensitiveContains("(l)")
                    || s.localizedCaseInsensitiveContains("left") { nameLeft = true; break }
                if s.localizedCaseInsensitiveContains("(r)")
                    || s.localizedCaseInsensitiveContains("right") { nameLeft = false; break }
            }
            // Fallback only if the name is sideless: connection order.
            let guessLeft = nameLeft ?? spatialControllers.isEmpty
            print("[input] -> \(guessLeft ? "LEFT" : "RIGHT") hand (fromName=\(nameLeft != nil))")
            spatialControllers.append(controller)
            SenseMapper.install(on: controller, nameLeft: nameLeft,
                                guessLeft: guessLeft, into: aggregator)
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
            SenseMapper.forgetMenuLatch(controller)
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
        onControllerChange?()
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
        // The dpad, for menu navigation only -- in_null.c reads these four
        // while key_dest is not key_game and nowhere else, so they reach no
        // gameplay binding. Published because a dpad is how a gamepad player
        // expects to walk a menu; the left stick does the same job through
        // the same emulation, for the Sense pair (no dpad) and for anyone
        // who reaches for the stick.
        set(QC_PAD_DPAD_UP, pad.dpad.up.isPressed)
        set(QC_PAD_DPAD_DOWN, pad.dpad.down.isPressed)
        set(QC_PAD_DPAD_LEFT, pad.dpad.left.isPressed)
        set(QC_PAD_DPAD_RIGHT, pad.dpad.right.isPressed)
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

    /// Drop every source on the floor without disturbing any of them. Set while
    /// the console has the game stopped: each input source keeps updating its
    /// own slice, so releasing this resumes from the live pose rather than a
    /// stale one, and no source needs to know the console exists. The weapon
    /// wheel zeroes its own slice the same way, one layer down.
    private var _suppressed = false
    var suppressed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _suppressed }
        set {
            lock.lock()
            let changed = _suppressed != newValue
            _suppressed = newValue
            if changed { push() }      // land the zeroed (or restored) pad now
            lock.unlock()
        }
    }

    private func push() {
        if _suppressed {
            var zero = qc_gamepad_state_t()
            zero.connected = slices.isEmpty ? 0 : 1
            QC_InputSetGamepad(&zero)
            return
        }
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
        InputTelemetry.shared.record(rt: merged.rt, lt: merged.lt)

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
/// virtual pad. Left hand: movement stick, walk trigger, L1 = weapon wheel,
/// face buttons cycle weapons, L3 = slow-mo toggle, Create/Share = recenter.
/// Right hand: aim stick, fire trigger, Cross + R1 = jump, Circle = use,
/// R3 = recenter. Options/Menu, on EITHER controller, summons the window.
private enum SenseMapper {

    /// Options/Menu, latched for an edge, PER CONTROLLER. `build` runs on
    /// GameController's own handler queue and is called again for every
    /// value change on the profile, so without a latch the window would be
    /// re-summoned on every stick wobble while the button was held.
    ///
    /// Per controller and not one shared Bool: both halves of the pair call
    /// this, and a single flag would be reset by whichever controller
    /// reported "up" and then re-fire on the next value change from the one
    /// still holding the button down.
    ///
    /// `nonisolated(unsafe)` behind a lock, like `WheelState`'s hold: the
    /// handler queue is not the main actor, and all that crosses is a Bool
    /// per device. The grip (wheel) and L3 (slow-mo) take the same route a
    /// few lines below -- an app-side consumer, not a pad bit.
    private static let menuLock = NSLock()
    nonisolated(unsafe) private static var menuWasDown: [ObjectIdentifier: Bool] = [:]

    /// True exactly once per press, for this controller. The window summon is
    /// an app-side action, so it must not go through QC_PAD_MENU: in_null.c
    /// turns that bit into K_ESCAPE for the engine menu, and the engine menu
    /// is a console-only vestige now. That mapping STAYS for classic
    /// gamepads, which have no other way in and whose Menu button is not
    /// this button.
    private static func menuPressEdge(_ down: Bool, _ controller: GCController) -> Bool {
        let key = ObjectIdentifier(controller)
        menuLock.lock(); defer { menuLock.unlock() }
        let edge = down && !(menuWasDown[key] ?? false)
        menuWasDown[key] = down
        return edge
    }

    /// Forget a detached controller's latch, so a reconnect starts clean and
    /// the table cannot grow across a session of pairings.
    static func forgetMenuLatch(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        menuLock.lock(); defer { menuLock.unlock() }
        menuWasDown[key] = nil
    }

    /// Options/Menu on whichever controller has it. HAND-AGNOSTIC on purpose:
    /// a menu button is not a left-hand or right-hand action, and routing it
    /// through the left/right branches meant that turning on "Swap controller
    /// hands" silently removed the only Sense way into the product's menu --
    /// the physical right controller took the left branch, where Options fell
    /// into the recenter list, and the physical left one has no Options
    /// element at all. Create/Share keep going to recenter, which is what
    /// they have always done.
    private static func routeMenuButton(_ profile: GCPhysicalInputProfile,
                                        controller: GCController) {
        let down = ["Options", "Menu"].contains {
            button(profile, containing: $0)?.isPressed == true
        }
        guard menuPressEdge(down, controller) else { return }
        // Logged like the prayer path (HandInput) and the wrist MENU key: a
        // nil closure means no window has ever appeared to register one, and
        // that is precisely the state in which a silent no-op cannot be
        // diagnosed -- these are the only hardware routes into any menu now.
        HandDebug.shared.log("[summon] Sense Options -> opening console"
            + (HandInput.summonConsole == nil ? " (NO HANDLER REGISTERED)" : ""))
        if let summon = HandInput.summonConsole { Task { @MainActor in summon() } }
    }

    static func slice(forLeft left: Bool) -> PadAggregator.Source {
        left ? .senseLeft : .senseRight
    }

    static func install(on controller: GCController, nameLeft: Bool?,
                        guessLeft: Bool, into aggregator: PadAggregator) {
        let profile = controller.physicalInputProfile
        let source = slice(forLeft: nameLeft ?? guessLeft)
        profile.valueDidChangeHandler = { profile, _ in
            aggregator.update(source, build(profile, controller: controller,
                                            nameLeft: nameLeft, guessLeft: guessLeft))
        }
        aggregator.update(source, build(profile, controller: controller,
                                        nameLeft: nameLeft, guessLeft: guessLeft))
    }

    private static func build(_ profile: GCPhysicalInputProfile,
                              controller: GCController,
                              nameLeft: Bool?,
                              guessLeft: Bool) -> PadAggregator.Slice {
        var slice = PadAggregator.Slice()

        // Handedness, most-authoritative first: the NAME the AVP gave it, then
        // live position (left-most = left), then connection order. The user's
        // swap override always wins on top.
        let rawLeft = nameLeft ?? SpatialControllerTracker.shared.isLeft(controller) ?? guessLeft
        let left = VRSettings.shared.swapSenseHands ? !rawLeft : rawLeft

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
        // Before the hand split, because the menu button belongs to neither
        // hand -- see routeMenuButton.
        routeMenuButton(profile, controller: controller)
        if left {
            // L1 (grip) is the weapon wheel: hold to open, release to commit
            // the highlighted weapon. It never reaches the engine as a key.
            let grip = button(profile, containing: "Grip")
                ?? button(profile, containing: "Shoulder")
            WheelState.shared.setHold(grip?.isPressed == true, source: .sense)
            // L3 (stick click) toggles slow-motion -- separate from the wheel,
            // routed straight to the engine so it never reaches a key.
            let l3 = button(profile, containing: "Thumbstick Button")
                ?? button(profile, containing: "Thumbstick , Button")
            QC_InputSetSlowmo(l3?.isPressed == true ? 1 : 0)
            // Weapon cycle lives on the face buttons now (grip is the wheel).
            set(QC_PAD_LSHOULDER, ["Button X", "Square"])          // prev weapon
            set(QC_PAD_Y, ["Button Y", "Triangle", "Button B"])    // next weapon
            // Recenter. "Options"/"Menu" are NOT in this list any more: they
            // go to routeMenuButton above, on either hand.
            set(QC_PAD_OPTIONS, ["Create", "Share"])
        } else {
            // Cross AND R1 (grip) jump; circle uses.
            set(QC_PAD_A, ["Button A", "Cross", "Grip", "Shoulder"])
            set(QC_PAD_B, ["Button B", "Circle"])
            set(QC_PAD_RTHUMB, ["Thumbstick Button", "Thumbstick , Button"])
            // QC_PAD_MENU is deliberately not set here any more: Options goes
            // to routeMenuButton above, which summons the window instead of
            // the K_ESCAPE in_null.c would turn this bit into.
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
    /// instead of presenting as dead buttons. Also mirrored into the in-app
    /// console (QuakeEngineViewModel.note), the same direct-append path
    /// AudioSink's onLog and HandDebug.log use to surface app-side diagnostics
    /// in the headset -- not the `send("echo ...")` route, because
    /// `GameControllerInput`/`InputHost` attach controllers independently of
    /// `engine.boot()` and `send()` silently no-ops (no retry) while the
    /// engine isn't `.running`; `note()` appends regardless. `@MainActor`
    /// because `note()` is main-actor-isolated and this enum isn't -- the one
    /// call site (`attach`) is already on the main actor, so this is just
    /// naming that. Quotes are stripped for display tidiness only: `note()`
    /// never goes through Cbuf, so there's no parse hazard to guard against,
    /// just undocumented vendor strings that could otherwise look broken in
    /// the console.
    @MainActor
    static func logElements(of controller: GCController) {
        let profile = controller.physicalInputProfile
        let buttons = profile.buttons.keys.sorted().joined(separator: ", ")
        let dpads = profile.dpads.keys.sorted().joined(separator: ", ")
        let line = "[input] spatial controller '\(controller.vendorName ?? "?")' buttons: [\(buttons)] dpads: [\(dpads)]"
        print(line)
        QuakeEngineViewModel.shared.note(line.replacingOccurrences(of: "\"", with: "'"))
    }
}

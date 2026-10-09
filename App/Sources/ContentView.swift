//
//  ContentView.swift
//
//  The Metal world view over the M0 console. The console stays: with no HUD
//  or in-game console text yet, the command bar is still the only input, and
//  the log is still where the engine talks back.
//

import SwiftUI
import UIKit
import os

/// Which section the persistent control panel shows. Replaces the old Comfort
/// and Weapon pop-out popovers, which auto-dismissed and hid your values.
private enum PanelTab: Hashable { case comfort, weapon, admin, capture, debug }

struct ContentView: View {
    /// Not owned here either — see QuakeEngineViewModel. A window close must
    /// not take the engine with it, and a window open must not start a second.
    private var engine: QuakeEngineViewModel { .shared }
    /// Input is NOT owned here. Closing this window used to release HandInput
    /// and GameControllerInput and kill all input; InputHost owns them for the
    /// life of the app. See InputHost.
    private var input: InputHost { .shared }
    private var gamepad: GameControllerInput { InputHost.shared.gamepad }
    private var hands: HandInput { InputHost.shared.hands }
    @State private var commandText = ""
    @State private var autoOpened = false
    @State private var showScope = false
    @State private var showComfort = false
    @State private var heightOffset: Float = 0.4
    @State private var rightHanded = true
    /// vr_hud: 0 off, 1 wrist (default), 2 float. Mirrors the cvar's own
    /// default since there is no live cvar read-back; matches r_null.c.
    @State private var hudPanelMode: Int = 1
    @State private var lookRelative = true
    @State private var smoothTurn = false
    @State private var wheelSlowmo = true
    @State private var swapSenseHands = false
    @State private var fullMenu = false
    @State private var teleportEnabled = true
    @State private var teleportMarker = true
    @State private var teleportSound = true
    @State private var teleportFx = true
    @State private var telefrag = true
    @State private var offHandModelOnly = false
    @State private var laser = false
    @State private var reticle = false
    @State private var reticleStyle: Int = 0
    @State private var reticleColor: Int = 3
    @State private var laserColor: Int = 0
    @State private var wheelClipUI: Float = 0.79
    @State private var offHandPitchUI: Float = 0
    @State private var offHandYawUI: Float = 0
    @State private var offHandRollUI: Float = 0
    @State private var turnFlick: Float = 0.85
    @State private var turnHoldEnabled = true
    @State private var turnHoldSpeedUI: Float = 90
    @State private var turnHoldDzUI: Float = 18
    // Sound mixer (Debug tab). Defaults match Quake's volume/bgmvolume defaults;
    // the engine's archived values win in-game until a slider is touched.
    @State private var sfxVolume: Float = 0.7
    @State private var musicVolume: Float = 1.0
    @State private var audioMuted = false
    @State private var hudFwdUI: Float = 0
    @State private var hudUpUI: Float = 0.14
    @State private var hudSideUI: Float = 0
    @State private var hudPitchUI: Float = 0
    @State private var hudRollUI: Float = 0
    @State private var hudYawUI: Float = 0
    @State private var gyroLast: CGPoint?
    @State private var gyroRollMode = false
    @State private var hudFaceUI: Float = 0.8
    @State private var hudScaleUI: Float = 1
    @State private var fireMode: FireMode = .pinch
    @State private var summonGesture: SummonGesture = .prayer
    @State private var wheelSelectHand: WheelSelectHand = .offHand
    @State private var aimSmoothUI: Float = 0.4
    @State private var pinchCloseUI: Float = 1.5   // cm
    @State private var curlSensUI: Float = 0.72
    @State private var hammerDropUI: Float = 45
    @State private var showWeapon = false
    @State private var activeTab: PanelTab = .comfort
    @State private var roster = EnemyRoster()
    @State private var killAI = false
    @State private var infightAttacker: Int32 = 0
    @State private var infightTarget: Int32 = 0
    @State private var infightBothWays = true
    private var debug: DebugStore { .shared }
    private var pause: GamePause { .shared }
    @State private var weaponFocus = WeaponFocus.shared
    @State private var exporter = DemoExporter()
    @State private var capture = CaptureState()
    @State private var captureName = ""
    @State private var exportDemo = ""
    @State private var exportPreset = ExportPreset()
    @State private var selectedEpisode = 0

    /// Map episodes, one horizontal strip each. Mission packs / custom packs can
    /// be appended here later and appear in the same episode picker.
    private static let episodes: [(name: String, ids: [String])] = [
        ("Episode 1 · Dimension of the Doomed", (1...8).map { "e1m\($0)" }),
        ("Episode 2 · The Realm of Black Magic", (1...7).map { "e2m\($0)" }),
        ("Episode 3 · The Netherworld", (1...7).map { "e3m\($0)" }),
        ("Episode 4 · The Elder World", (1...8).map { "e4m\($0)" }),
        ("Deathmatch", (1...6).map { "dm\($0)" }),
    ]
    @State private var confirmResetGun = false
    @State private var confirmResetProfile = false
    @State private var weaponBack: Float = 0
    @State private var weaponUp: Float = 0
    @State private var weaponSide: Float = 0
    @State private var aimPitch: Float = 8      // matches InputProfile.aimPitch
    @State private var aimYaw: Float = 0
    @State private var wheelPitchUI: Float = 0
    @State private var wheelYawUI: Float = 0
    @State private var wheelRollUI: Float = 0
    @State private var wheelRadiusUI: Float = 1
    @State private var wheelFwdUI: Float = 0
    @State private var wheelUpUI: Float = 0
    @State private var wheelSideUI: Float = 0
    @State private var sightingIn = false
    @State private var sightStatus = "Needs the immersive space"
    @State private var weaponPlacementCustom = false
    @State private var weaponClip: Float = 1
    @State private var weaponClipBack: Float = 0.79
    @State private var laserForward: Float = 0
    @State private var laserUp: Float = 0
    @State private var laserSide: Float = 0
    @State private var laserPitch: Float = 0
    @State private var laserYaw: Float = 0
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow

    private var coordinator: RendererCoordinator { .shared }

    /// Reticle/laser palette labels; indices match QR_VrColor in qr_bridge.c.
    static let vrColorNames = ["Red", "Green", "Cyan", "Amber",
                               "White", "Magenta", "Yellow", "Blue",
                               "Quake beige"]

    /// Which input mode's rig you're editing. These values are stored per mode
    /// (hands vs PSVR2), and the active one auto-follows controller presence, so
    /// this badge is the only thing telling you which rig a slider will change.
    @ViewBuilder
    private var editingModeBadge: some View {
        let hands = ProfileStore.shared.active == .hands
        let limbs = DebugStore.shared.showLimbs
        HStack(spacing: 6) {
            Image(systemName: hands ? "hand.raised.fill" : "gamecontroller.fill")
            Text("Editing: \(hands ? "Hands" : "PSVR2") · \(limbs ? "real arms shown" : "no real arms")")
                .fontWeight(.semibold)
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill((hands ? Color.green : Color.blue).opacity(limbs ? 0.30 : 0.16)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 16) {
                controlPanel
                VStack(alignment: .leading, spacing: 16) {
                    renderSurface
                    if engine.status == .running, showScope {
                        TriggerScope()
                            .frame(height: 120)
                    }
                    // While the windowed world view is up the console
                    // shrinks to a log strip; in immersive (no preview —
                    // the world is all around) and in every other state it
                    // gets the room instead.
                    console
                        .frame(maxHeight: engine.status == .running && !coordinator.isImmersiveActive
                               ? 96 : .infinity)
                    commandBar
                }
                // The phase fader hugs the panel's far-right edge.
                if engine.status == .running {
                    phaseControls
                }
            }
            // The level launcher runs the full width of the dash.
            levelBar
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 560)
        .background(dashMaterial(28))
        .tint(Self.noctuaBurgundy)
        .onAppear {
            engine.boot()
            _ = input          // ensure the app-lifetime input host exists
            // The wheel commits through the one console route.
            let engine = self.engine
            WheelState.shared.sendCommand = { command in
                Task { @MainActor in engine.send(command) }
            }
            WeaponTrim.shared.sendCommand = { command in
                Task { @MainActor in engine.send(command) }
            }
            // Audio's step trace into the in-headset console, so the device
            // audio test is readable in the headset with no Mac attached.
            AudioSink.shared.onLog = { line in
                Task { @MainActor in engine.note(line) }
            }
            // Persisted per-input profiles: pick Hands/PSVR2 by what's attached,
            // push its feel to VRSettings now (the rig cvars land once the engine
            // is running, below), and load its values into the sliders.
            ProfileStore.shared.sendCommand = { command in
                Task { @MainActor in engine.send(command) }
            }
            ProfileStore.shared.refreshActiveFromInput()
            ProfileStore.shared.apply()
            syncFromProfile()
            // Restore the persisted debug overlays; the store's didSets only
            // fire on user edits, not on its initial load from defaults.
            DebugStore.shared.apply()
            GamePause.shared.isExporting = { exporter.state != .idle }
            // The window being up IS the reason to pause, and at launch it is
            // up before anything else. Pending until a map exists, so the first
            // level starts stopped rather than running under a console you are
            // still reading. Harmless on a summon reopen, which pauses anyway.
            GamePause.shared.set(true)
            // Console respawn, two triggers, both duplicate-guarded: the
            // immersive space ending (crown goes home; coming back should find
            // a window) and the in-game summon sign (summon the window WITHOUT
            // leaving the game -- mixed immersion lets it coexist with the
            // world). The captured OpenWindowAction stays valid after this
            // window closes.
            let openWindow = self.openWindow
            let respawn: @MainActor () -> Void = {
                // No presence guard: the console is a unique Window scene, so
                // this either reopens it or brings it forward. Logged once per
                // summon because this is the last link that cannot be unit
                // tested -- whether an OpenWindowAction captured here still
                // works after this view is gone.
                print("[summon] opening the console window")
                openWindow(id: QuakeAVPApp.consoleWindowID)
                // You summoned the console mid-game: stop the world so a
                // shambler isn't eating you while you read a slider. Resume is
                // the button in the window header -- see GamePause for why it
                // cannot be automatic.
                GamePause.shared.set(true)
            }
            RendererCoordinator.shared.onImmersiveEnded = respawn
            HandInput.summonConsole = respawn
        }
        // Hands drive the game only while immersed with no hardware
        // attached; a controller connecting mid-session takes over.
        .onChange(of: coordinator.isImmersiveActive) { _, active in
            sightStatus = active ? "Ready" : "Needs the immersive space"
            // The scope earns its room while immersed (no preview pane);
            // windowed, it stays behind its toggle.
            if active { showScope = true }
        }
        .onChange(of: gamepad.hasPhysicalController) { _, _ in
            // Activation itself is InputHost's job (it must happen with no
            // window open too); the window only mirrors it into the sliders.
            // Auto-switch the active profile when a controller connects/leaves
            // (unless the user pinned one), then reflect it in the sliders.
            ProfileStore.shared.refreshActiveFromInput()
            ProfileStore.shared.apply()
            syncFromProfile()
        }
        .onChange(of: exporter.state) { _, state in
            // Mirrored into the console so a simulator log capture shows it.
            print("export: \(state)")
        }
        .onChange(of: engine.status) { _, status in
            // Force the phase melt OFF when the engine comes up. It's a
            // head-centred sphere that dissolves nearby surfaces to
            // passthrough; a stale/nonzero `phase` (from a prior config or a
            // stray slider) leaves it melting the stairs you stand on. The UI
            // starts at 0%, so match it.
            if status == .running {
                engine.send("phase 0")
                phaseLevel = 0
                // Engine's up: push the active profile's weapon/laser rig cvars
                // and the persisted debug cvars, which the console refuses
                // before this point.
                ProfileStore.shared.applyRig()
                // The per-weapon placement table goes over its own any-thread
                // setter rather than the console, so it does not depend on
                // applyRig's sendCommand having been wired. Published here
                // regardless, so a table restored from defaults is live even
                // if nothing touches a slider this session.
                WeaponTrim.shared.applyEngine()
                DebugStore.shared.applyEngine { engine.send($0) }
                // Boot-time export for the simulator acceptance test:
                // QAVP_EXPORT_DEMO=demo1 [QAVP_EXPORT_PRESET=1080p60,gun]
                // [QAVP_EXPORT_CANCEL_AFTER=seconds]. Run with
                // QAVP_AUTO_IMMERSIVE=off; the exporter refuses otherwise.
                if let demo = ProcessInfo.processInfo.environment["QAVP_EXPORT_DEMO"] {
                    let env = ProcessInfo.processInfo.environment
                    let preset = ExportPreset.parse(env["QAVP_EXPORT_PRESET"] ?? "1080p60,gun")
                    let cancelAfter = env["QAVP_EXPORT_CANCEL_AFTER"].flatMap(Double.init)
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))   // let the pak and console settle
                        startExport(demo: demo, preset: preset)
                        if let cancelAfter {
                            try? await Task.sleep(for: .seconds(cancelAfter))
                            exporter.cancel()
                        }
                    }
                }
            }
            // Open the immersive space as soon as the engine is up -- the flat
            // window is only a mono debug view, so play should begin in the
            // headset without a manual tap. QAVP_AUTO_IMMERSIVE=cycle also
            // dismisses and reopens once (the lifecycle test: no leak, no
            // crash, engine keeps ticking); =off opts out.
            let mode = ProcessInfo.processInfo.environment["QAVP_AUTO_IMMERSIVE"]
            guard status == .running, !autoOpened, mode != "off"
            else { return }
            autoOpened = true
            Task {
                await openImmersiveSpace(id: QuakeAVPApp.immersiveSpaceID)
                guard mode == "cycle" else { return }
                try? await Task.sleep(for: .seconds(12))
                await dismissImmersiveSpace()
                try? await Task.sleep(for: .seconds(6))
                await openImmersiveSpace(id: QuakeAVPApp.immersiveSpaceID)
            }
        }
    }

    @ViewBuilder
    private var renderSurface: some View {
        // No placeholder while immersive: the world is all around, so the
        // window's room goes to the console and controls instead.
        if engine.status == .running, !coordinator.isImmersiveActive {
            QuakeRenderView(paused: false)
                .clipShape(.rect(cornerRadius: 12))
                .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quake")
                    .font(.largeTitle.weight(.semibold))
                Text("QuakeSpasm \(engine.engineVersion) · Metal world renderer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(inputStatus.text, systemImage: inputStatus.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // A toggle, not just a way out. Resume is the ONLY way back from a
            // pause -- visionOS never tells us the window closed, so nothing
            // auto-resumes -- but having resumed with the window still open
            // (the debugging case) you need a way to stop the world again
            // without closing and re-summoning.
            if engine.status == .running {
                Button {
                    pause.set(!pause.isPaused)
                } label: {
                    Label(pause.isPaused ? "Resume" : "Pause",
                          systemImage: pause.isPaused ? "play.fill" : "pause.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
            }
            if engine.status == .running {
                Button {
                    showScope.toggle()
                } label: {
                    Label("Scope", systemImage: "waveform.path.ecg")
                }
            }
            phaseButton
            immersiveButton
            statusBadge
        }
    }

    /// Comfort controls in a POPOVER, not a Menu -- a Menu silently drops
    /// Sliders (only buttons/toggles/pickers render), which is why the
    /// height slider never appeared. A popover renders a real slider.
    /// Noctua palette over a thin translucent material: the fan-blade beige as
    /// the dash surface, the retail burgundy as the control accent, the frame
    /// brown for depth. Tint stays translucent so the room shows through.
    private static let noctuaBeige = Color(red: 0.86, green: 0.78, blue: 0.62)
    private static let noctuaBurgundy = Color(red: 0.56, green: 0.26, blue: 0.23)
    private static let noctuaBrown = Color(red: 0.31, green: 0.24, blue: 0.20)
    private func dashMaterial(_ radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.thinMaterial)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Self.noctuaBeige.opacity(0.42)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Self.noctuaBrown.opacity(0.35), lineWidth: 1))
    }

    /// The persistent tabbed control panel that replaces the old popovers:
    /// always on screen, so a value stays visible and editable instead of
    /// vanishing when you look away.
    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Panel", selection: $activeTab) {
                Text("Comfort").tag(PanelTab.comfort)
                Text("Weapon").tag(PanelTab.weapon)
                Text("Admin").tag(PanelTab.admin)
                Text("Capture").tag(PanelTab.capture)
                Text("Debug").tag(PanelTab.debug)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                Group {
                    switch activeTab {
                    case .comfort: comfortContent
                    case .weapon: weaponContent
                    case .admin: adminContent
                    case .capture: captureContent
                    case .debug: debugContent
                    }
                }
                .padding(.trailing, 6)
            }
        }
        .padding(16)
        .frame(width: 430)
        .background(dashMaterial(14))
    }

    private var comfortContent: some View {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input profile (auto-follows what's attached)")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Input profile", selection: Binding(
                        get: { ProfileStore.shared.active },
                        set: { ProfileStore.shared.manualOverride = true
                               ProfileStore.shared.active = $0
                               ProfileStore.shared.apply(); syncFromProfile()
                               // Re-evaluate INPUT activation too, so choosing
                               // "Hands" actually switches to bare hands even
                               // with the Sense pair still connected.
                               InputHost.shared.refreshActive() })) {
                        Text("Hands").tag(InputMode.hands)
                        Text("PSVR2").tag(InputMode.psvr2)
                    }
                    .pickerStyle(.segmented)
                    Button("Reset this profile", role: .destructive) {
                        confirmResetProfile = true
                    }
                    .font(.caption)
                    // Strictly worse to mis-tap than "Reset gun": it drops the
                    // whole input profile, aim trim and Sight in included.
                    .confirmationDialog(
                        "Reset the \(ProfileStore.shared.active == .hands ? "Hands" : "PSVR2") profile?",
                        isPresented: $confirmResetProfile,
                        titleVisibility: .visible
                    ) {
                        Button("Reset", role: .destructive) {
                            ProfileStore.shared.resetCurrent()
                            syncFromProfile()
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("Returns every feel and rig value for this input "
                             + "profile to its default, including the aim trim "
                             + "from Sight in. Per-weapon placement and trim "
                             + "are kept.")
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Eye height  \(heightOffset >= 0 ? "+" : "")\(Int(heightOffset * 100)) cm")
                        .font(.headline)
                    Text("Raise until the floor sits at your real floor.")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(heightOffset) },
                        set: { heightOffset = Float($0); VRSettings.shared.heightOffset = Float($0)
                               ProfileStore.shared.current.heightOffset = Float($0) }),
                        in: -0.6...0.9)
                    HStack {
                        Button("Reset") {
                            heightOffset = 0.4; VRSettings.shared.heightOffset = 0.4
                            ProfileStore.shared.current.heightOffset = 0.4
                        }
                        Spacer()
                        Button("Recenter") { engine.send("vr_recenter") }
                    }
                }
                Divider()
                Picker("Dominant hand", selection: Binding(
                    get: { rightHanded },
                    set: { rightHanded = $0; VRSettings.shared.rightHanded = $0 })) {
                    Text("Right-handed").tag(true)
                    Text("Left-handed").tag(false)
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Status bar (vr_hud)").font(.caption).foregroundStyle(.secondary)
                    Picker("Status bar", selection: Binding(
                        get: { hudPanelMode },
                        set: { hudPanelMode = $0; engine.send("vr_hud \($0)") })) {
                        Text("Off").tag(0)
                        Text("Wrist").tag(1)
                        Text("Floating").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Wrist rides the off hand (falls back to floating if it isn't tracked); "
                         + "Floating holds ~1.5 m ahead, head-stabilized.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Weapon wheel select (hands only)").font(.caption).foregroundStyle(.secondary)
                    Picker("Wheel select hand", selection: Binding(
                        get: { wheelSelectHand },
                        set: { wheelSelectHand = $0; VRSettings.shared.wheelSelectHand = $0
                               ProfileStore.shared.current.wheelSelectHand = $0.rawValue })) {
                        Text("Same hand").tag(WheelSelectHand.offHand)
                        Text("Other hand").tag(WheelSelectHand.dominant)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(wheelSelectHand == .dominant
                         ? "Off hand holds the wheel open; reach with the gun hand to pick. The gun follows your reaching hand while the wheel is up."
                         : "The hand that opens the wheel also picks.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Toggle("Move where I look", isOn: Binding(
                    get: { lookRelative },
                    set: { lookRelative = $0; engine.send("vr_moverelative \($0 ? 1 : 0)") }))
                Toggle("Swap controller hands", isOn: Binding(
                    get: { swapSenseHands },
                    set: { swapSenseHands = $0; VRSettings.shared.swapSenseHands = $0 }))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Off-hand model angle (PSVR controllers)").font(.caption).foregroundStyle(.secondary)
                    Text("Rotate the rigid off-hand into a handshake. Dial these on device.")
                        .font(.caption2).foregroundStyle(.secondary)
                    offHandSlider("Pitch°", $offHandPitchUI, set: { VRSettings.shared.offHandPitch = $0 },
                                  persist: \.offHandPitch)
                    offHandSlider("Yaw°", $offHandYawUI, set: { VRSettings.shared.offHandYaw = $0 },
                                  persist: \.offHandYaw)
                    offHandSlider("Roll°", $offHandRollUI, set: { VRSettings.shared.offHandRoll = $0 },
                                  persist: \.offHandRoll)
                    Button("Reset off-hand angle") {
                        offHandPitchUI = 0; offHandYawUI = 0; offHandRollUI = 0
                        VRSettings.shared.offHandPitch = 0
                        VRSettings.shared.offHandYaw = 0
                        VRSettings.shared.offHandRoll = 0
                        var p = ProfileStore.shared.current
                        p.offHandPitch = 0; p.offHandYaw = 0; p.offHandRoll = 0
                        ProfileStore.shared.current = p
                    }
                    .font(.caption)
                }
                Toggle("Full weapon menu (look to pick)", isOn: Binding(
                    get: { fullMenu },
                    set: { fullMenu = $0
                           VRSettings.shared.fullMenu = $0
                           engine.send("vr_fullmenu \($0 ? 1 : 0)") }))
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Teleport locomotion", isOn: Binding(
                        get: { teleportEnabled },
                        set: { teleportEnabled = $0; engine.send("vr_teleport \($0 ? 1 : 0)") }))
                    Text("Aim with the gun reticle; tap the off-hand ring finger and release to blink there.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Toggle("Tint reticle when landable", isOn: Binding(
                        get: { teleportMarker },
                        set: { teleportMarker = $0; engine.send("vr_teleportcolor \($0 ? 1 : 0)") }))
                        .font(.caption)
                    Toggle("Teleport sound", isOn: Binding(
                        get: { teleportSound },
                        set: { teleportSound = $0; engine.send("vr_teleportsound \($0 ? 1 : 0)") }))
                        .font(.caption)
                    Toggle("Teleport splash effect", isOn: Binding(
                        get: { teleportFx },
                        set: { teleportFx = $0; engine.send("vr_teleportfx \($0 ? 1 : 0)") }))
                        .font(.caption)
                    Toggle("Telefrag (gib what you land on)", isOn: Binding(
                        get: { telefrag },
                        set: { telefrag = $0; engine.send("vr_telefrag \($0 ? 1 : 0)") }))
                        .font(.caption)
                }
                if !gamepad.hasPhysicalController {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Model off hand only", isOn: Binding(
                            get: { offHandModelOnly },
                            set: { offHandModelOnly = $0; VRSettings.shared.offHandModelOnly = $0 }))
                        Text("Draw the 3D hand on the off hand only; the gun hand stays just the weapon. Controllerless only.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Turning", selection: Binding(
                        get: { smoothTurn },
                        set: { smoothTurn = $0; engine.send("vr_smoothturn \($0 ? 1 : 0)") })) {
                        Text("Snap 45°").tag(false)
                        Text("Smooth").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text(gamepad.hasPhysicalController
                         ? "Controller connected: turning uses the right stick and the Snap/Smooth setting above."
                         : "Bare hands: FLICK the gun hand sideways for a quick turn. On Smooth, with Edge turn on, hold the GUN hand aimed out past the dead zone — left or right — to keep turning that way (Metroid Prime Hunters style); center it to stop. Turn speed and dead zone tune it. Flick ease sets how hard a whip the flick takes.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Flick ease").font(.caption)
                        Slider(value: Binding(
                            get: { Double(turnFlick) },
                            set: { turnFlick = Float($0)
                                   VRSettings.shared.turnFlickSpeed = Float($0)
                                   ProfileStore.shared.current.turnFlickSpeed = Float($0) }),
                               in: 0.2...1.6)
                        Text(String(format: "%.2f", turnFlick))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Toggle("Edge turn (aim to a side to turn)", isOn: Binding(
                        get: { turnHoldEnabled },
                        set: { turnHoldEnabled = $0; engine.send("vr_edgeturn \($0 ? 1 : 0)") }))
                        .font(.caption)
                    HStack {
                        Text("Turn speed").font(.caption)
                        Slider(value: Binding(
                            get: { Double(turnHoldSpeedUI) },
                            set: { turnHoldSpeedUI = Float($0); engine.send("vr_edgeturn_speed \(Int($0))") }),
                               in: 30...180)
                        Text("\(Int(turnHoldSpeedUI))°/s")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Dead zone").font(.caption)
                        Slider(value: Binding(
                            get: { Double(turnHoldDzUI) },
                            set: { turnHoldDzUI = Float($0); engine.send("vr_edgeturn_dz \(Int($0))") }),
                               in: 8...40)
                        Text("\(Int(turnHoldDzUI))°")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                // Fire is pinch in quake-avp. The curl gesture stays in code
                // (HandState.indexCurled, the .curl fire path) for a future
                // limited-control mode, but isn't exposed here.
                VStack(alignment: .leading, spacing: 3) {
                    Text("Console summon").font(.caption).foregroundStyle(.secondary)
                    Picker("Console summon", selection: Binding(
                        get: { summonGesture },
                        set: { summonGesture = $0; VRSettings.shared.summonGesture = $0
                               ProfileStore.shared.current.summonGesture = $0.rawValue })) {
                        Text("Prayer").tag(SummonGesture.prayer)
                        Text("Palm up").tag(SummonGesture.palmUp)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(summonGesture == .prayer
                         ? "Palms together, fingers up, hold 0.6s."
                         : "Aim hand palm-up, hold 1.2s. Competes with visionOS: "
                           + "the palm also raises Home View / Control Center.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Gesture tuning").font(.caption).foregroundStyle(.secondary)
                    tuneRow("Aim smoothing", $aimSmoothUI, 0.1...1.0) {
                        VRSettings.shared.aimSmooth = $0; ProfileStore.shared.current.aimSmooth = $0 }
                    // Shown in cm; stored in metres. Lower = fingers must get
                    // closer before it fires.
                    tuneRow("Pinch cm", $pinchCloseUI, 0.8...3.5, fmt: "%.1f") {
                        VRSettings.shared.pinchClose = $0 / 100
                        ProfileStore.shared.current.pinchClose = $0 / 100 }
                }
                Toggle("Slow-mo while weapon wheel is open", isOn: Binding(
                    get: { wheelSlowmo },
                    set: { wheelSlowmo = $0; engine.send("wheel_timescale \($0 ? "0.2" : "1")") }))
            }
    }

    /// Levels tab: a Half-Life-2-style horizontal carousel per episode. Each
    /// card is a map preview + name; tapping sends `map <id>`. Previews load
    /// from Documents/thumbnails/<id>.png when present, else a placeholder.
    /// Standalone map launcher below the console (not a tab): an episode picker
    /// + the Start hub, over a horizontal carousel of map preview cards.
    private var levelBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // The start map: Quake's in-game hub for difficulty + episode
                // select. Kept as its own button no matter which episode is up.
                Button { engine.send("map start") } label: {
                    Label("Start hub", systemImage: "house")
                }
                .buttonStyle(.bordered).font(.caption)
                Spacer()
                Picker("Episode", selection: $selectedEpisode) {
                    ForEach(Array(Self.episodes.enumerated()), id: \.offset) { i, ep in
                        Text(ep.name).tag(i)
                    }
                }
                .pickerStyle(.menu).font(.caption)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Self.episodes[selectedEpisode].ids, id: \.self) { mapCard($0) }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func mapCard(_ id: String) -> some View {
        Button { engine.send("map \(id)") } label: {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let preview = mapPreview(id) {
                        preview.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(colors: [Self.noctuaBrown, Self.noctuaBrown.opacity(0.55)],
                                       startPoint: .top, endPoint: .bottom)
                            .overlay(Image(systemName: "map")
                                .font(.title3).foregroundStyle(.white.opacity(0.25)))
                    }
                }
                .frame(width: 150, height: 94)
                .clipShape(.rect(cornerRadius: 8))
                Text(id.uppercased())
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: .rect(cornerRadius: 4))
                    .padding(6)
            }
        }
        .buttonStyle(.plain)
    }

    /// A cached map preview from Documents/thumbnails/<id>.(png|jpg), or nil.
    private func mapPreview(_ id: String) -> Image? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbnails")
        for ext in ["png", "jpg", "jpeg"] {
            let path = dir.appendingPathComponent(id).appendingPathExtension(ext).path
            if let img = UIImage(contentsOfFile: path) { return Image(uiImage: img) }
        }
        return nil
    }

    /// Admin tab: single-player cheats/utilities, sent to the console. Disabled
    /// until a level is loaded (the engine is running). The monster roster
    /// behind Kill AI and the infighting pickers is polled only while this
    /// tab is showing.
    private var adminContent: some View {
        let running = engine.status == .running
        return VStack(alignment: .leading, spacing: 10) {
            Text("Single-player only. Needs a level loaded.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Restart level") { engine.send("restart") }
            Button("All weapons + ammo") { engine.send("impulse 9") }
            Button("Full health") { engine.send("give h 100") }
            Divider()
            // Replaces the old one-shot Notarget press: that only stopped
            // monsters *acquiring* you, and shooting one still turned it on
            // you. sv_killai holds the state and re-clears every tick.
            Toggle("Kill AI (enemies never target you)", isOn: Binding(
                get: { killAI },
                set: { killAI = $0; engine.send("sv_killai \($0 ? 1 : 0)") }))
            Text("Toggles (each press flips)").font(.caption).foregroundStyle(.secondary)
            Button("God mode") { engine.send("god") }
            Button("Noclip") { engine.send("noclip") }
            Button("Fly") { engine.send("fly") }
            Divider()
            infightContent
        }
        .buttonStyle(.bordered)
        .disabled(!running)
        .onAppear { roster.startPolling(); killAI = roster.killAI }
        .onDisappear { roster.stopPolling() }
        .onChange(of: roster.killAI) { _, on in killAI = on }
        .onChange(of: roster.monsters) { _, monsters in
            // A pick that died or unloaded with the level goes back to none.
            if infightAttacker != 0, !monsters.contains(where: { $0.id == infightAttacker }) {
                infightAttacker = 0
            }
            if infightTarget != 0, !monsters.contains(where: { $0.id == infightTarget }) {
                infightTarget = 0
            }
        }
    }

    /// Target selection: pick an attacker and a target from the live roster
    /// and send `ai_target`. QuakeC's own retaliation refuses same-type
    /// infighting, so "Both ways" also sends the reverse pair.
    private var infightContent: some View {
        let canSend = infightAttacker != 0 && infightTarget != 0
            && infightAttacker != infightTarget
        return VStack(alignment: .leading, spacing: 8) {
            Text("Infighting").font(.caption.weight(.semibold))
            Text("Choose who attacks whom. Nearest first; a row shows what each monster is hunting now.")
                .font(.caption).foregroundStyle(.secondary)
            if roster.monsters.isEmpty {
                Text(roster.levelLoaded ? "No live monsters." : "Load a level to list monsters.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Attacker", selection: $infightAttacker) {
                    Text("Choose attacker").tag(Int32(0))
                    ForEach(roster.monsters) { m in
                        Text(roster.label(for: m)).tag(m.id)
                    }
                }
                .pickerStyle(.menu)
                Picker("Target", selection: $infightTarget) {
                    Text("Choose target").tag(Int32(0))
                    ForEach(roster.monsters) { m in
                        Text(roster.label(for: m)).tag(m.id)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Both ways (target fights back)", isOn: $infightBothWays)
                Button("Make hostile") {
                    engine.send("ai_target \(infightAttacker) \(infightTarget)")
                    if infightBothWays {
                        engine.send("ai_target \(infightTarget) \(infightAttacker)")
                    }
                }
                .disabled(!canSend)
            }
        }
    }

    /// Capture tab: record a demo + head track, then export it offline as a
    /// video (see DemoExporter). Exporting plays the demo back, which ends
    /// the current game, and needs the immersive space closed because the
    /// compositor thread owns the packet stream while it is open.
    private var captureContent: some View {
        let running = engine.status == .running
        let gameDir = engine.paths?.baseDirectory.appendingPathComponent("id1", isDirectory: true)
        let selected = capture.demos.first { $0.name == exportDemo }
        let hasTrack = selected?.hasTrack ?? false
        return VStack(alignment: .leading, spacing: 12) {
            Text("Record a demo and head track in the headset, then export it here at any size and frame rate. Exporting ends the current game.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Clip name", text: $captureName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(capture.isRecording)
                if capture.isRecording {
                    Button("Stop") {
                        if let gameDir { capture.stopRecording(engine: engine, gameDirectory: gameDir) }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Record") {
                        if let gameDir {
                            capture.startRecording(name: captureName, gameDirectory: gameDir, engine: engine)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!running)
                }
            }
            if capture.isRecording {
                Label("Recording \(capture.currentName)", systemImage: "record.circle")
                    .font(.caption).foregroundStyle(.red)
            }
            Divider()
            Text("Export").font(.caption.weight(.semibold))
            if capture.demos.isEmpty {
                Text("No demos yet. Record one, or drop a .dem into Files › Quake › id1.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Demo", selection: $exportDemo) {
                Text("Choose a demo").tag("")
                ForEach(capture.demos) { d in
                    Text(d.hasTrack ? "\(d.name)  ·  head track" : d.name).tag(d.name)
                }
            }
            .pickerStyle(.menu)
            Picker("Size", selection: $exportPreset.resolution) {
                ForEach(ExportPreset.Resolution.allCases) { Text("\($0.rawValue)p").tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Frame rate", selection: $exportPreset.fps) {
                ForEach([30, 60, 120], id: \.self) { Text("\($0) fps").tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Speed", selection: $exportPreset.slowMo) {
                Text("1×").tag(Float(1)); Text("½×").tag(Float(0.5)); Text("¼×").tag(Float(0.25))
            }
            .pickerStyle(.segmented)
            Picker("Motion blur", selection: $exportPreset.motionBlurSamples) {
                Text("Blur off").tag(1); Text("Blur 4").tag(4); Text("Blur 8").tag(8)
            }
            .pickerStyle(.segmented)
            Picker("Camera", selection: $exportPreset.camera) {
                ForEach(ExportPreset.Camera.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            if !hasTrack, exportPreset.camera.needsTrack {
                Text("This demo has no head track; pick Gun or a third-person camera.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("HUD overlay (health, armor, ammo, weapon, kills)", isOn: $exportPreset.hud)
            Picker("Codec", selection: $exportPreset.codec) {
                ForEach(ExportCodec.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if exporter.isRunning {
                if case .running(let frames, let t) = exporter.state {
                    HStack {
                        ProgressView()
                        Text("\(frames) frames · \(String(format: "%.1f", t)) s of demo")
                            .font(.caption)
                        Spacer()
                        Button("Cancel") { exporter.cancel() }
                    }
                }
            } else {
                Button("Export video") { startExport(demo: exportDemo, preset: exportPreset) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!running || exportDemo.isEmpty || coordinator.isImmersiveActive
                              || (exportPreset.camera.needsTrack && !hasTrack))
            }
            if case .done(let url) = exporter.state {
                Text("Saved: Files › Quake › Exports › \(url.lastPathComponent) (+ .csv of per-frame stats)")
                    .font(.caption)
            }
            if case .failed(let why) = exporter.state {
                Text(why).font(.caption).foregroundStyle(.red)
            }
            if coordinator.isImmersiveActive {
                Text("Exit the immersive space to export.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if let gameDir { capture.refresh(gameDirectory: gameDir) }
            if captureName.isEmpty { captureName = CaptureState.defaultName() }
        }
    }

    /// Debug tab: overlay/meter toggles, the input telemetry log, and the
    /// on-arm HUD placement rig (moved out of the overloaded Comfort section).
    private var debugContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Finger debug wireframe", isOn: Binding(
                get: { debug.fingerDebug }, set: { debug.fingerDebug = $0 }))
            Toggle("Show real hands / controllers", isOn: Binding(
                get: { debug.showLimbs }, set: { debug.showLimbs = $0 }))
            Toggle("Virtual hand model (bare hands)", isOn: Binding(
                get: { debug.virtualHands }, set: { debug.virtualHands = $0 }))
            // Not persisted on purpose -- see DebugStore.inputLog.
            Toggle("Input telemetry log (console)", isOn: Binding(
                get: { debug.inputLog }, set: { debug.inputLog = $0 }))
            Toggle("Enemy AI debug (trails + targets)", isOn: Binding(
                get: { debug.pathDebug },
                set: { debug.pathDebug = $0; engine.send("vr_pathdebug \($0 ? 1 : 0)") }))
            // Not persisted on purpose -- see DebugStore.projDebug.
            Toggle("Projectile spawn offset (console)", isOn: Binding(
                get: { debug.projDebug },
                set: { debug.projDebug = $0; engine.send("vr_projdebug \($0 ? 1 : 0)") }))
            // Sound mixer (the tone self-test and reboot-enable toggle are gone
            // now that audio works). `volume` is the sfx/creature/world level,
            // `bgmvolume` the music level -- both CVAR_ARCHIVE, so the engine
            // persists them in config.cfg. Mute zeroes both and unmute restores
            // the slider values, so it works regardless of the archived levels.
            // (Music has no codec wired yet, so that slider is forward-looking.)
            VStack(alignment: .leading, spacing: 6) {
                Text("Sound").font(.caption.weight(.semibold))
                Toggle("Mute", isOn: Binding(
                    get: { audioMuted },
                    set: { audioMuted = $0
                           if $0 { engine.send("volume 0"); engine.send("bgmvolume 0") }
                           else { engine.send("volume \(sfxVolume)")
                                  engine.send("bgmvolume \(musicVolume)") } }))
                HStack {
                    Text("Effects").font(.caption).frame(width: 60, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(sfxVolume) },
                        set: { sfxVolume = Float($0)
                               if !audioMuted { engine.send("volume \(sfxVolume)") } }), in: 0...1)
                    Text(String(format: "%.0f%%", sfxVolume * 100))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Music").font(.caption).frame(width: 60, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(musicVolume) },
                        set: { musicVolume = Float($0)
                               if !audioMuted { engine.send("bgmvolume \(musicVolume)") } }), in: 0...1)
                    Text(String(format: "%.0f%%", musicVolume * 100))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Toggle("Aim-ray decomposition (figure)", isOn: Binding(
                get: { debug.aimRayDebug }, set: { debug.aimRayDebug = $0 }))
            Toggle("Motion strobe: aim ray (figure)", isOn: Binding(
                get: { debug.strobeDebug }, set: { debug.strobeDebug = $0 }))
            Toggle("Turn trigger meter (stick/clutch/flick)", isOn: Binding(
                get: { debug.turnDebug }, set: { debug.turnDebug = $0 }))
            Toggle("Fire threshold meter (pinch/curl/bang)", isOn: Binding(
                get: { debug.fireDebug }, set: { debug.fireDebug = $0 }))
            // HUD dock placement. Sliders, not typed fields -- typing into a
            // text box in the headset is miserable; dragging is what you want in
            // space. Position in cm, rotation on the gyro below.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("HUD Position").font(.caption.weight(.semibold))
                    Spacer()
                    Button("Reset") { resetHUDPlacement() }.font(.caption)
                }
                transformSlider("Fwd", $hudFwdUI, -0.2...0.6, unit: "cm", display: 100) {
                    VRSettings.shared.hudForward = $0; ProfileStore.shared.current.hudForward = $0 }
                transformSlider("Up", $hudUpUI, -0.3...0.4, unit: "cm", display: 100) {
                    VRSettings.shared.hudUp = $0; ProfileStore.shared.current.hudUp = $0 }
                transformSlider("Side", $hudSideUI, -0.3...0.3, unit: "cm", display: 100) {
                    VRSettings.shared.hudSide = $0; ProfileStore.shared.current.hudSide = $0 }
                Text("HUD Transform").font(.caption.weight(.semibold)).padding(.top, 2)
                HStack(alignment: .center, spacing: 14) {
                    gyroDial(pitch: $hudPitchUI, yaw: $hudYawUI, roll: $hudRollUI) { p, y, r in
                        VRSettings.shared.hudPitch = p; VRSettings.shared.hudYaw = y
                        VRSettings.shared.hudRoll = r
                        ProfileStore.shared.current.hudPitch = p
                        ProfileStore.shared.current.hudYaw = y
                        ProfileStore.shared.current.hudRoll = r
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        transformField("Tilt X", $hudPitchUI, unit: "°") {
                            VRSettings.shared.hudPitch = $0; ProfileStore.shared.current.hudPitch = $0 }
                        transformField("Pan Y", $hudYawUI, unit: "°") {
                            VRSettings.shared.hudYaw = $0; ProfileStore.shared.current.hudYaw = $0 }
                        transformField("Roll Z", $hudRollUI, unit: "°") {
                            VRSettings.shared.hudRoll = $0; ProfileStore.shared.current.hudRoll = $0 }
                    }
                }
                transformField("Face me", $hudFaceUI, unit: "0–1") {
                    VRSettings.shared.hudFaceMe = $0; ProfileStore.shared.current.hudFaceMe = $0 }
                transformField("Scale", $hudScaleUI, unit: "×") {
                    VRSettings.shared.hudScale = $0; ProfileStore.shared.current.hudScale = $0 }
            }
        }
    }

    /// Weapon rig: gun placement and the aiming laser. Every slider pushes its
    /// cvar live and persists into the active profile.
    private var weaponContent: some View {
                VStack(alignment: .leading, spacing: 14) {
                    // These rigs are stored PER INPUT MODE. Without this badge
                    // you could be silently tuning the controller rig while in
                    // hands, or vice versa -- so say which one, loudly.
                    editingModeBadge
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Gun placement").font(.headline)
                        Text("Slide the gun onto your hand — updates live in the headset.")
                            .font(.caption).foregroundStyle(.secondary)
                        // Per HELD weapon, not global: the models' origins sit at
                        // different points on each gun, so one offset makes some
                        // clip through the hand. Untuned guns follow the profile.
                        Text(weaponPlacementCustom
                             ? "Placement: this weapon"
                             : "Placement: profile default — moving a slider makes it this weapon's")
                            .font(.caption2).foregroundStyle(.secondary)
                        placeSlider("Back", $weaponBack, in: -20...30)
                        placeSlider("Up", $weaponUp, in: -15...15)
                        placeSlider("Side", $weaponSide, in: -15...15)
                        // The two aim trims. Pitch carries the WHOLE vertical
                        // correction (not a delta on a hidden 8), hence the
                        // offset range; yaw is per-person and centred on 0.
                        placementSlider("Aim pitch°", $aimPitch, in: -12...28, cvar: "vr_aimpitch", persist: \.aimPitch)
                        placementSlider("Aim yaw°", $aimYaw, in: -20...20, cvar: "vr_aimyaw", persist: \.aimYaw)
                        HStack(spacing: 10) {
                            Button(sightingIn ? "Hold…" : "Sight in") { sightIn() }
                                .disabled(sightingIn || !coordinator.isImmersiveActive)
                            Text(sightStatus)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("Point your arm where your head is facing and tap — both trims are measured for you. The sliders are the manual fallback; pitch = up/down, yaw = left/right.")
                            .font(.caption2).foregroundStyle(.secondary)
                        trimSlider("Trim front", $weaponClip) { WeaponTrim.shared.setFront($0) }
                        trimSlider("Trim rear", $weaponClipBack) { WeaponTrim.shared.setRear($0) }
                        Text("Per-weapon: front = barrel end, rear = arm end. Trimming the rear also re-seats the gun on your hand.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Divider().padding(.vertical, 4)
                        Text("Weapon wheel").font(.caption.weight(.semibold))
                        HStack(alignment: .top, spacing: 14) {
                            gyroDial(pitch: $wheelPitchUI, yaw: $wheelYawUI,
                                     roll: $wheelRollUI) { p, y, r in
                                VRSettings.shared.wheelPitch = p
                                VRSettings.shared.wheelYaw = y
                                VRSettings.shared.wheelRoll = r
                                ProfileStore.shared.current.wheelPitch = p
                                ProfileStore.shared.current.wheelYaw = y
                                ProfileStore.shared.current.wheelRoll = r
                                engine.send("vr_wheelpitch \(p)")
                                engine.send("vr_wheelyaw \(y)")
                                engine.send("vr_wheelroll \(r)")
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Drag inside to tilt the ring, on the rim to spin it.")
                                    .font(.caption2).foregroundStyle(.secondary)
                                placementSlider("Size", $wheelRadiusUI, in: 0.4...2.5,
                                                cvar: "vr_wheelradius", fmt: "%.2f",
                                                persist: \.wheelRadius)
                                placementSlider("Fwd", $wheelFwdUI, in: -40...40,
                                                cvar: "vr_wheelfwd", persist: \.wheelFwd)
                                placementSlider("Up", $wheelUpUI, in: -12...12,
                                                cvar: "vr_wheelup", persist: \.wheelUp)
                                placementSlider("Side", $wheelSideUI, in: -12...12,
                                                cvar: "vr_wheelside", persist: \.wheelSide)
                                placementSlider("Trim", $wheelClipUI, in: 0.4...1.0,
                                                cvar: "vr_wheelclip", fmt: "%.2f",
                                                persist: \.wheelClip)
                                Text("Retracts the loaded round near the grip on slots that fall back to the viewmodel (1 = off). Barrels are untouched.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Button("Reset wheel") {
                            wheelPitchUI = 0; wheelYawUI = 0; wheelRollUI = 0; wheelRadiusUI = 1
                            wheelFwdUI = 0; wheelUpUI = 0; wheelSideUI = 0; wheelClipUI = 0.79
                            VRSettings.shared.wheelPitch = 0
                            VRSettings.shared.wheelYaw = 0
                            VRSettings.shared.wheelRoll = 0
                            for c in ["vr_wheelpitch 0", "vr_wheelyaw 0", "vr_wheelroll 0",
                                      "vr_wheelradius 1", "vr_wheelfwd 0", "vr_wheelup 0",
                                      "vr_wheelside 0", "vr_wheelclip 0.79"] { engine.send(c) }
                            var p = ProfileStore.shared.current
                            p.wheelPitch = 0; p.wheelYaw = 0; p.wheelRoll = 0; p.wheelRadius = 1
                            p.wheelFwd = 0; p.wheelUp = 0; p.wheelSide = 0; p.wheelClip = 0.79
                            ProfileStore.shared.current = p
                        }
                        .font(.caption)
                        Divider().padding(.vertical, 4)
                        // Reads the whole table into the console so the
                        // numbers can leave the device. Device UserDefaults is
                        // the only copy, and a reinstall takes it with it.
                        // Three channels, because the useful one depends on
                        // how the app was launched. os_log reaches both Xcode
                        // and Console.app with no debugger attached (print
                        // needs Xcode to have started the process, which a tap
                        // on the Home View is not), and the clipboard reaches
                        // the Mac through Universal Clipboard.
                        Button("Dump all weapon values") {
                            let lines = WeaponTrim.shared.summary()
                            let log = Logger(subsystem: "com.acervantez.quakeavp",
                                             category: "weapons")
                            for line in lines {
                                engine.note(line)       // readable in the headset
                                // os_log only. stdout is ALSO captured by the
                                // unified log, so a print here showed up in
                                // Console.app a second time and the first dump
                                // came back with every line doubled. Logger
                                // reaches Xcode's console as well, so print
                                // bought nothing.
                                log.notice("\(line, privacy: .public)")
                            }
                            UIPasteboard.general.string = lines.joined(separator: "\n")
                            engine.note("[weapons] copied to clipboard ("
                                        + "\(lines.count) lines)")
                        }
                        .font(.caption)
                        // Confirmed, because it is one tap next to the dump
                        // button and it throws away a tuning pass. It also
                        // clears the aim trim, which is a Sight in result and
                        // not per-weapon at all -- so the prompt says so rather
                        // than letting that go unnoticed.
                        Button("Reset gun", role: .destructive) {
                            confirmResetGun = true
                        }
                        .font(.caption)
                        .confirmationDialog("Reset this weapon's rig?",
                                            isPresented: $confirmResetGun,
                                            titleVisibility: .visible) {
                            Button("Reset", role: .destructive) { resetHeldWeapon() }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("Puts this weapon's placement and trim back to "
                                 + "their shipped values for the current input "
                                 + "mode. Also clears the aim trim to 8\u{00B0} "
                                 + "pitch / 0\u{00B0} yaw, which is your Sight in "
                                 + "calibration and applies to every weapon. "
                                 + "Your other weapons keep what you tuned.")
                        }
                    }
                    Divider()
                    // RETICLE — its own group with its own color.
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Target reticle", isOn: Binding(
                            get: { reticle },
                            set: { reticle = $0; engine.send("vr_reticle \($0 ? 1 : 0)")
                                   ProfileStore.shared.current.reticle = $0 }))
                            .font(.headline)
                        Text("A mark where the shot lands. It lies flat on whatever surface you aim at — like a teleport marker on the floor.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Reticle style", selection: Binding(
                            get: { reticleStyle },
                            set: { reticleStyle = $0; engine.send("vr_reticlestyle \($0)")
                                   ProfileStore.shared.current.reticleStyle = $0 })) {
                            Text("Cross").tag(0)
                            Text("Circle + dot").tag(1)
                            Text("Dot").tag(2)
                            Text("Circle").tag(3)
                        }
                        Picker("Reticle color", selection: Binding(
                            get: { reticleColor },
                            set: { reticleColor = $0; engine.send("vr_reticlecolor \($0)")
                                   ProfileStore.shared.current.reticleColor = $0 })) {
                            ForEach(0..<Self.vrColorNames.count, id: \.self) { idx in
                                Text(Self.vrColorNames[idx]).tag(idx)
                            }
                        }
                    }
                    Divider()
                    // LASER — its own group with its own color.
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Aiming laser", isOn: Binding(
                            get: { laser },
                            set: { laser = $0; engine.send("vr_laser \($0 ? 1 : 0)")
                                   ProfileStore.shared.current.laser = $0 }))
                            .font(.headline)
                        Picker("Laser color", selection: Binding(
                            get: { laserColor },
                            set: { laserColor = $0; engine.send("vr_lasercolor \($0)")
                                   ProfileStore.shared.current.laserColor = $0 })) {
                            ForEach(0..<Self.vrColorNames.count, id: \.self) { idx in
                                Text(Self.vrColorNames[idx]).tag(idx)
                            }
                        }
                        Text("Move the beam's start to the barrel tip. Forward reaches the muzzle.")
                            .font(.caption).foregroundStyle(.secondary)
                        placementSlider("Fwd", $laserForward, in: -10...60, cvar: "vr_laserforward", persist: \.laserForward)
                        placementSlider("Up", $laserUp, in: -15...15, cvar: "vr_laserup", persist: \.laserUp)
                        placementSlider("Side", $laserSide, in: -15...15, cvar: "vr_laserside", persist: \.laserSide)
                        placementSlider("Tilt°", $laserPitch, in: -10...10, cvar: "vr_laserpitch", fmt: "%.1f", persist: \.laserPitch)
                        placementSlider("Pan°", $laserYaw, in: -10...10, cvar: "vr_laseryaw", fmt: "%.1f", persist: \.laserYaw)
                        Button("Reset laser") {
                            laserForward = 0; laserUp = 0; laserSide = 0
                            laserPitch = 0; laserYaw = 0
                            for c in ["vr_laserforward 0", "vr_laserup 0", "vr_laserside 0",
                                      "vr_laserpitch 0", "vr_laseryaw 0"] {
                                engine.send(c)
                            }
                            var p = ProfileStore.shared.current
                            p.laserForward = 0; p.laserUp = 0; p.laserSide = 0
                            p.laserPitch = 0; p.laserYaw = 0
                            ProfileStore.shared.current = p
                        }
                        .font(.caption)
                    }
                }
                // Load the HELD weapon's saved trim so the sliders show and
                // edit whatever gun you're holding.
                .onAppear {
                    weaponClip = WeaponTrim.shared.currentFront
                    weaponClipBack = WeaponTrim.shared.currentRear
                    syncPlacementFromWeapon()
                }
                // And re-read them the instant the held weapon changes while
                // the tab is open -- the whole point of WeaponFocus.
                .onChange(of: weaponFocus.weapon) { _, _ in
                    weaponClip = WeaponTrim.shared.currentFront
                    weaponClipBack = WeaponTrim.shared.currentRear
                    syncPlacementFromWeapon()
                }
    }

    /// What "Reset gun" does once confirmed. Placement and trim return to the
    /// shipped defaults for the held weapon in the current input mode; the aim
    /// trim returns to the 8/0 default, which is global rather than per weapon.
    private func resetHeldWeapon() {
        WeaponTrim.shared.resetCurrentPlacement()
        syncPlacementFromWeapon()
        aimPitch = 8; aimYaw = 0
        for c in ["vr_aimpitch 8", "vr_aimyaw 0"] { engine.send(c) }
        var p = ProfileStore.shared.current
        p.aimPitch = 8; p.aimYaw = 0
        ProfileStore.shared.current = p
        WeaponTrim.shared.resetCurrent()
        weaponClip = WeaponTrim.shared.currentFront
        weaponClipBack = WeaponTrim.shared.currentRear
    }

    /// Mirror the held weapon's effective placement into the sliders.
    private func syncPlacementFromWeapon() {
        let p = WeaponTrim.shared.currentPlacement
        weaponBack = p.back; weaponUp = p.up; weaponSide = p.side
        weaponPlacementCustom = WeaponTrim.shared.currentPlacementIsCustom
    }

    /// A placement slider routed through WeaponTrim: edits the HELD weapon,
    /// persists per (input mode, weapon), and pushes the cvar.
    private func placeSlider(_ label: String, _ value: Binding<Float>,
                             in range: ClosedRange<Double>,
                             fmt: String = "%.0f") -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 40, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { nv in
                    value.wrappedValue = Float(nv)
                    WeaponTrim.shared.setPlacement(.init(back: weaponBack, up: weaponUp,
                                                         side: weaponSide))
                    weaponPlacementCustom = true
                }), in: range)
            Text(String(format: fmt, value.wrappedValue))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// A Trim slider (0.5...1) routed through WeaponTrim, which persists the
    /// value for the held weapon and pushes the cvar.
    private func trimSlider(_ label: String, _ value: Binding<Float>,
                            set: @escaping (Float) -> Void) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 60, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Float($0); set(Float($0)) }),
                in: 0.5...1)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// The gyro dial (inspector-style): drag INSIDE the rings to tumble the
    /// HUD dock -- horizontal drag pans (Pan Y), vertical drag tilts (Tilt X)
    /// -- and drag ON the outer ring band to spin Roll Z by the angle swept
    /// around the centre. The fields beside it show the exact numbers live.
    private func gyroDial(pitch: Binding<Float>, yaw: Binding<Float>,
                          roll: Binding<Float>,
                          apply: @escaping (Float, Float, Float) -> Void) -> some View {
        let size: CGFloat = 96
        let ringBand: CGFloat = 16                 // outer band width = roll grab zone
        let degPerPt: Float = 0.6                  // tumble sensitivity
        // A wireframe globe, the way every inspector draws this: the SPHERE is
        // the silhouette, the vertical meridian narrows as you pan, the
        // horizontal equator flattens as you tilt, and both turn with roll.
        // Each ellipse reads one axis on its own, which is why it is legible at
        // a glance where ticks and a horizon line were not.
        //
        // An ellipse seen `a` degrees off face-on is cos(a) as wide, so the
        // minor axis IS the cosine -- at Tilt X 85 the equator is edge-on and
        // draws as a line, which is exactly what you want it to look like.
        func minor(_ deg: Float) -> CGFloat {
            max(1, CGFloat(abs(cos(deg * .pi / 180))) * (size - 2))
        }
        return ZStack {
            Circle().fill(Self.noctuaBrown.opacity(0.14))
            Circle().strokeBorder(Self.noctuaBrown.opacity(0.85), lineWidth: 1.2)
            Ellipse().stroke(Self.noctuaBrown.opacity(0.6), lineWidth: 1.2)
                .frame(width: minor(yaw.wrappedValue), height: size - 2)
            Ellipse().stroke(Self.noctuaBrown.opacity(0.6), lineWidth: 1.2)
                .frame(width: size - 2, height: minor(pitch.wrappedValue))
        }
        .rotationEffect(.degrees(Double(roll.wrappedValue)))
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                let c = CGPoint(x: size / 2, y: size / 2)
                if gyroLast == nil {
                    let r = hypot(g.startLocation.x - c.x, g.startLocation.y - c.y)
                    gyroRollMode = r > size / 2 - ringBand
                }
                guard let last = gyroLast else { gyroLast = g.location; return }
                let p = g.location
                gyroLast = p
                if gyroRollMode {
                    let a0 = atan2(last.y - c.y, last.x - c.x)
                    let a1 = atan2(p.y - c.y, p.x - c.x)
                    var d = Float(a1 - a0) * 180 / .pi
                    if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                    roll.wrappedValue = max(-180, min(180, roll.wrappedValue + d))
                } else {
                    yaw.wrappedValue = max(-180, min(180,
                        yaw.wrappedValue + Float(p.x - last.x) * degPerPt))
                    pitch.wrappedValue = max(-90, min(90,
                        pitch.wrappedValue + Float(p.y - last.y) * degPerPt))
                }
                apply(pitch.wrappedValue, yaw.wrappedValue, roll.wrappedValue)
            }
            .onEnded { _ in gyroLast = nil })
    }

    /// A typed transform field (inspector-style): right-aligned label, numeric
    /// entry, unit suffix. `display` scales storage to display units (100 shows
    /// metres as cm). Commits on return/focus-out; applies + persists live.
    private func transformField(_ label: String, _ value: Binding<Float>,
                                unit: String, display: Float = 1,
                                apply: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            TextField(label, value: Binding<Double>(
                get: { Double(value.wrappedValue * display) },
                set: { let v = Float($0) / display
                       value.wrappedValue = v; apply(v) }),
                format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .labelsHidden()
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A labelled DRAG slider for a HUD transform value (position/scale), with a
    /// numeric readout. Sliders beat typed fields in the headset. `display`
    /// scales the readout (e.g. metres shown as cm).
    private func transformSlider(_ label: String, _ value: Binding<Float>,
                                 _ range: ClosedRange<Float>, unit: String,
                                 display: Float = 1,
                                 apply: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { let v = Float($0); value.wrappedValue = v; apply(v) }),
                in: Double(range.lowerBound)...Double(range.upperBound))
            Text(String(format: "%.0f%@", value.wrappedValue * display, unit))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    /// Reset the HUD dock to defaults -- position, the gyro rotation, and scale
    /// all at once (the gyro needs a way back, and so does a dragged-off HUD).
    private func resetHUDPlacement() {
        hudFwdUI = 0; hudUpUI = 0.14; hudSideUI = 0
        hudPitchUI = 0; hudYawUI = 0; hudRollUI = 0; hudScaleUI = 1
        let s = VRSettings.shared
        s.hudForward = 0; s.hudUp = 0.14; s.hudSide = 0
        s.hudPitch = 0; s.hudYaw = 0; s.hudRoll = 0; s.hudScale = 1
        var p = ProfileStore.shared.current
        p.hudForward = 0; p.hudUp = 0.14; p.hudSide = 0
        p.hudPitch = 0; p.hudYaw = 0; p.hudRoll = 0; p.hudScale = 1
        ProfileStore.shared.current = p
    }

    /// One row of the gesture-tuning panel: a labelled slider over a custom
    /// range that pushes the value straight to VRSettings, so the hand-input
    /// feel changes live in the headset without a rebuild.
    private func tuneRow(_ label: String, _ value: Binding<Float>,
                         _ range: ClosedRange<Float>, fmt: String = "%.2f",
                         apply: @escaping (Float) -> Void) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 100, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Float($0); apply(Float($0)) }),
                in: Double(range.lowerBound)...Double(range.upperBound))
            Text(String(format: fmt, value.wrappedValue))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// Load the active profile's values into the slider mirrors, so the UI
    /// shows what was persisted (called on launch and on a profile switch).
    private func syncFromProfile() {
        let p = ProfileStore.shared.current
        heightOffset = p.heightOffset
        turnFlick = p.turnFlickSpeed
        fireMode = FireMode(rawValue: p.fireMode) ?? .pinch
        summonGesture = SummonGesture(rawValue: p.summonGesture ?? 0) ?? .prayer
        wheelSelectHand = WheelSelectHand(rawValue: p.wheelSelectHand ?? 0) ?? .offHand
        aimSmoothUI = p.aimSmooth; pinchCloseUI = p.pinchClose * 100
        wheelPitchUI = p.wheelPitch; wheelYawUI = p.wheelYaw
        wheelRollUI = p.wheelRoll; wheelRadiusUI = p.wheelRadius
        wheelFwdUI = p.wheelFwd; wheelUpUI = p.wheelUp; wheelSideUI = p.wheelSide
        wheelClipUI = p.wheelClip
        offHandPitchUI = p.offHandPitch; offHandYawUI = p.offHandYaw; offHandRollUI = p.offHandRoll
        curlSensUI = p.curlSensitivity; hammerDropUI = p.hammerDropDeg
        hudFwdUI = p.hudForward; hudUpUI = p.hudUp; hudSideUI = p.hudSide
        hudPitchUI = p.hudPitch; hudRollUI = p.hudRoll; hudYawUI = p.hudYaw ?? 0
        hudFaceUI = p.hudFaceMe; hudScaleUI = p.hudScale
        weaponBack = p.weaponBack; weaponUp = p.weaponUp; weaponSide = p.weaponSide
        aimPitch = p.aimPitch; aimYaw = p.aimYaw
        laser = p.laser
        reticle = p.reticle
        reticleStyle = p.reticleStyle; reticleColor = p.reticleColor
        laserColor = p.laserColor
        laserForward = p.laserForward; laserUp = p.laserUp; laserSide = p.laserSide
        laserPitch = p.laserPitch; laserYaw = p.laserYaw
    }

    /// One row of the weapon-placement panel: a labelled slider that pushes
    /// its cvar to the engine AND persists into the active profile on every
    /// change, so the gun moves live and the value survives relaunch.
    private func placementSlider(_ label: String, _ value: Binding<Float>,
                                 in range: ClosedRange<Double>, cvar: String,
                                 fmt: String = "%.0f",
                                 persist kp: WritableKeyPath<InputProfile, Float>? = nil) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 40, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Float($0)
                       engine.send("\(cvar) \(Float($0))")
                       if let kp { ProfileStore.shared.current[keyPath: kp] = Float($0) } }),
                in: range)
            Text(String(format: fmt, value.wrappedValue))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// Off-hand model angle slider: feeds VRSettings (read on the render
    /// thread) via `set`, and persists to the active profile. Not a cvar --
    /// the presence model lives entirely Swift-side.
    private func offHandSlider(_ label: String, _ value: Binding<Float>,
                               set: @escaping (Float) -> Void,
                               persist kp: WritableKeyPath<InputProfile, Float>) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 46, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Float($0)
                       set(Float($0))
                       ProfileStore.shared.current[keyPath: kp] = Float($0) }),
                in: -180...180)
            Text(String(format: "%.0f", value.wrappedValue))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    @State private var phaseLevel = 0.0
    @State private var phaseSpeed = 2.0
    /// The default molten orange: the cvar's (1.5, 0.93, 0.27) glow with
    /// the 1.5x intensity factored out for the 0-1 picker.
    private static let defaultPhaseColor = Color(red: 1.0, green: 0.62, blue: 0.18)
    @State private var phaseColor = defaultPhaseColor

    /// Sweep durations for `phase_time`, in seconds. Discrete steps rather
    /// than a second slider: this is a mood setting, not a value anyone
    /// needs to dial in precisely.
    private static let phaseSpeeds: [(label: String, seconds: Double)] = [
        ("Instant", 0.25), ("Fast", 1), ("Default", 2), ("Slow", 4), ("Glacial", 8),
    ]

    @ViewBuilder
    private var phaseButton: some View {
        if engine.status == .running {
            Button {
                phaseLevel = phaseLevel < 0.5 ? 1 : 0
            } label: {
                Label(phaseLevel < 0.5 ? "Phase" : "Rephase",
                      systemImage: phaseLevel < 0.5 ? "circle.dotted" : "circle.dashed")
            }
        }
    }

    /// The dissolve controls, a column beside the console: a vertical
    /// slider scrubbing the `phase` target (the engine eases toward it, so
    /// a partial nudge holds a partial melt), the sweep-speed menu, and the
    /// ember colour well with its reset.
    private var phaseControls: some View {
        VStack(spacing: 12) {
            Text("\(Int((phaseLevel * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            // A rotated Slider is the sanctioned vertical-slider trick: lay
            // it out at its length, rotate, then reserve the rotated
            // footprint. -90 puts minimum at the bottom.
            Slider(value: $phaseLevel, in: 0...1) {
                Text("Phase")
            }
            .frame(width: 200)
            .rotationEffect(.degrees(-90))
            .frame(width: 44, height: 200)
            .onChange(of: phaseLevel) { _, level in
                engine.send(String(format: "phase %.2f", level))
            }
            Menu {
                ForEach(Self.phaseSpeeds, id: \.seconds) { speed in
                    Button {
                        phaseSpeed = speed.seconds
                        engine.send(String(format: "phase_time %g", speed.seconds))
                    } label: {
                        if phaseSpeed == speed.seconds {
                            Label(speed.label, systemImage: "checkmark")
                        } else {
                            Text(speed.label)
                        }
                    }
                }
            } label: {
                Label(Self.phaseSpeeds.first { $0.seconds == phaseSpeed }?.label ?? "\(phaseSpeed)s",
                      systemImage: "timer")
                    .font(.caption)
            }
            .fixedSize()
            HStack(spacing: 10) {
                // Ember rim colour; the 1.5x keeps the glow as hot as the
                // default orange regardless of the picked hue.
                ColorPicker("Phase colour", selection: $phaseColor, supportsOpacity: false)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: phaseColor) { _, color in
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                        engine.send(String(format: "phase_color \"%.3f %.3f %.3f\"",
                                           r * 1.5, g * 1.5, b * 1.5))
                    }
                Button {
                    phaseColor = Self.defaultPhaseColor
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .disabled(phaseColor == Self.defaultPhaseColor)
                .help("Back to the molten orange")
            }
        }
        .frame(width: 96)
    }

    @ViewBuilder
    private var immersiveButton: some View {
        if engine.status == .running {
            Button {
                Task {
                    if coordinator.isImmersiveActive {
                        await dismissImmersiveSpace()
                    } else {
                        await openImmersiveSpace(id: QuakeAVPApp.immersiveSpaceID)
                    }
                }
            } label: {
                Label(coordinator.isImmersiveActive ? "Exit Immersive" : "Enter Immersive",
                      systemImage: "visionpro")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var statusBadge: some View {
        Group {
            switch engine.status {
            case .idle:
                Label("Idle", systemImage: "circle")
            case .missingGameData:
                Label("No game data", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .running:
                Label("Running", systemImage: "play.circle.fill")
                    .foregroundStyle(.green)
            case .stopped:
                Label("Stopped", systemImage: "stop.circle")
                    .foregroundStyle(.secondary)
            case .failed:
                Label("Failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private var console: some View {
        switch engine.status {
        case .missingGameData:
            missingDataHelp
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text(message)
                    .font(.body.monospaced())
                    .foregroundStyle(.red)
                logScroll
            }
        default:
            logScroll
        }
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(engine.consoleLines.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(12)
            }
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
            .onChange(of: engine.consoleLines.count) { _, count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }

    private var missingDataHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Game data not found")
                .font(.headline)
            Text("""
                 Quake's assets are not redistributable, so they aren't bundled. \
                 Copy your `id1` folder — the one containing `pak0.pak` — into this \
                 app's Documents folder using the Files app, then relaunch.
                 """)
                .foregroundStyle(.secondary)
            if let base = engine.paths?.baseDirectory {
                Text(base.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.tertiary)
            }
            Button("Check again") { engine.boot() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var commandBar: some View {
        HStack {
            TextField("console command, e.g. map e1m1", text: $commandText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(submit)
            Button("Send", action: submit)
                .disabled(commandText.isEmpty || engine.status != .running)
        }
    }

    private var inputStatus: (text: String, icon: String) {
        if let name = gamepad.sourceDescription {
            var text = name
            if !gamepad.spatialControllers.isEmpty {
                text += SpatialControllerTracker.shared.isTracking ? " · tracked" : " · pairing"
                if let triggers = ControllerOutput.shared.adaptiveTriggerStatus {
                    text += " · \(triggers)"
                }
            }
            return (text, "gamecontroller")
        }
        if hands.isRunning {
            return ("Hands — pinch left to move, right to fire", "hand.pinch")
        }
        return ("No controller — console input only", "gamecontroller")
    }

    /// "Sight in": hold a short sample so hand tremor averages out, then write
    /// both aim trims. Refuses rather than writing an implausible result — a
    /// bad trim leaves you unable to aim at the button that would undo it.
    private func sightIn() {
        sightingIn = true
        sightStatus = "Hold still, pointing where you look…"
        AimCalibration.shared.begin()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            sightingIn = false
            switch AimCalibration.shared.finish() {
            case let .ok(yaw, pitch, samples):
                aimYaw = yaw; aimPitch = pitch
                engine.send("vr_aimyaw \(yaw)")
                engine.send("vr_aimpitch \(pitch)")
                var p = ProfileStore.shared.current
                p.aimYaw = yaw; p.aimPitch = pitch
                ProfileStore.shared.current = p
                sightStatus = String(format: "Sighted: pitch %.1f°, yaw %.1f°", pitch, yaw)
                print("[sightin] pitch=\(pitch) yaw=\(yaw) over \(samples) samples")
            case let .notEnoughData(samples):
                sightStatus = "No aim seen — is your hand tracked?"
                print("[sightin] refused: only \(samples) paired samples")
            case let .implausible(yaw, pitch):
                sightStatus = "Measured nonsense; trims unchanged"
                print("[sightin] refused: implausible pitch=\(pitch) yaw=\(yaw)"
                    + " -- head and aim are probably not in the same frame")
            }
        }
    }

    /// One place that knows where demos and exports live.
    private func startExport(demo: String, preset: ExportPreset) {
        guard let paths = engine.paths else { return }
        exporter.start(demo: demo, preset: preset,
                       host: engine.engineHost, core: coordinator.core,
                       gameDirectory: paths.baseDirectory.appendingPathComponent("id1", isDirectory: true),
                       exportsDirectory: paths.baseDirectory.appendingPathComponent("Exports", isDirectory: true),
                       immersiveActive: coordinator.isImmersiveActive)
    }

    private func submit() {
        let text = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        engine.send(text)
        commandText = ""
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
}

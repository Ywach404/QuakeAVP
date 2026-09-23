//
//  ContentView.swift
//
//  The Metal world view over the M0 console. The console stays: with no HUD
//  or in-game console text yet, the command bar is still the only input, and
//  the log is still where the engine talks back.
//

import SwiftUI
import UIKit

/// Which section the persistent control panel shows. Replaces the old Comfort
/// and Weapon pop-out popovers, which auto-dismissed and hid your values.
private enum PanelTab: Hashable { case comfort, weapon, admin, debug }

struct ContentView: View {
    @State private var engine = QuakeEngineViewModel()
    @State private var gamepad = GameControllerInput()
    @State private var hands: HandInput?
    @State private var commandText = ""
    @State private var autoOpened = false
    @State private var showScope = false
    @State private var showComfort = false
    @State private var heightOffset: Float = 0.4
    @State private var rightHanded = true
    @State private var lookRelative = true
    @State private var fingerDebug = false
    @State private var smoothTurn = false
    @State private var wheelSlowmo = true
    @State private var swapSenseHands = false
    @State private var fullMenu = false
    @State private var laser = false
    @State private var turnFlick: Float = 0.85
    @State private var showLimbs = true
    @State private var pathDebug = false
    @State private var aimRayDebug = false
    @State private var strobeDebug = false
    @State private var turnDebug = false
    @State private var fireDebug = false
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
    @State private var turnStyle: TurnStyle = .stick
    @State private var aimSmoothUI: Float = 0.4
    @State private var aimBlendUI: Float = 0.35
    @State private var curlSensUI: Float = 0.72
    @State private var hammerDropUI: Float = 45
    @State private var inputLog = false
    @State private var showWeapon = false
    @State private var activeTab: PanelTab = .comfort
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
    @State private var weaponBack: Float = 0
    @State private var weaponUp: Float = 0
    @State private var weaponSide: Float = 0
    @State private var weaponGrip: Float = 0.15
    @State private var aimPitch: Float = 0
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
            gamepad.start()
            hands = HandInput(aggregator: gamepad.aggregator)
            // The wheel commits through the one console route.
            let engine = self.engine
            WheelState.shared.sendCommand = { command in
                Task { @MainActor in engine.send(command) }
            }
            WeaponTrim.shared.sendCommand = { command in
                Task { @MainActor in engine.send(command) }
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
            // Console respawn, two triggers, both duplicate-guarded: the
            // immersive space ending (crown goes home; coming back should find
            // a window) and the in-game aim-hand palm-up dwell (summon the
            // window WITHOUT leaving the game -- mixed immersion lets it
            // coexist with the world). The captured OpenWindowAction stays
            // valid after this window closes.
            ConsolePresence.shared.count += 1
            let openWindow = self.openWindow
            let respawn: @MainActor () -> Void = {
                guard ConsolePresence.shared.count == 0 else { return }
                openWindow(id: QuakeAVPApp.consoleWindowID)
            }
            RendererCoordinator.shared.onImmersiveEnded = respawn
            HandInput.summonConsole = respawn
        }
        .onDisappear { ConsolePresence.shared.count -= 1 }
        // Hands drive the game only while immersed with no hardware
        // attached; a controller connecting mid-session takes over.
        .onChange(of: coordinator.isImmersiveActive) { _, active in
            updateHands()
            // The scope earns its room while immersed (no preview pane);
            // windowed, it stays behind its toggle.
            if active { showScope = true }
        }
        .onChange(of: gamepad.hasPhysicalController) { _, _ in
            updateHands()
            // Auto-switch the active profile when a controller connects/leaves
            // (unless the user pinned one), then reflect it in the sliders.
            ProfileStore.shared.refreshActiveFromInput()
            ProfileStore.shared.apply()
            syncFromProfile()
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
                // Engine's up: push the active profile's weapon/laser rig cvars.
                ProfileStore.shared.applyRig()
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
                               ProfileStore.shared.apply(); syncFromProfile() })) {
                        Text("Hands").tag(InputMode.hands)
                        Text("PSVR2").tag(InputMode.psvr2)
                    }
                    .pickerStyle(.segmented)
                    Button("Reset this profile") {
                        ProfileStore.shared.resetCurrent(); syncFromProfile()
                    }
                    .font(.caption)
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
                Toggle("Move where I look", isOn: Binding(
                    get: { lookRelative },
                    set: { lookRelative = $0; engine.send("vr_moverelative \($0 ? 1 : 0)") }))
                Toggle("Swap controller hands", isOn: Binding(
                    get: { swapSenseHands },
                    set: { swapSenseHands = $0; VRSettings.shared.swapSenseHands = $0 }))
                Toggle("Full weapon menu (look to pick)", isOn: Binding(
                    get: { fullMenu },
                    set: { fullMenu = $0
                           VRSettings.shared.fullMenu = $0
                           engine.send("vr_fullmenu \($0 ? 1 : 0)") }))
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Turning", selection: Binding(
                        get: { smoothTurn },
                        set: { smoothTurn = $0; engine.send("vr_smoothturn \($0 ? 1 : 0)") })) {
                        Text("Snap 45°").tag(false)
                        Text("Smooth").tag(true)
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Turn style").font(.caption).foregroundStyle(.secondary)
                        Picker("Turn style", selection: Binding(
                            get: { turnStyle },
                            set: { turnStyle = $0; VRSettings.shared.turnStyle = $0
                                   ProfileStore.shared.current.turnStyle = $0.rawValue })) {
                            Text("Stick").tag(TurnStyle.stick)
                            Text("Clutch").tag(TurnStyle.clutch)
                            Text("Flick").tag(TurnStyle.flick)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    Text("Stick: hold the off hand out to turn. Clutch: hold the aim-hand middle pinch and drag. Flick: whip the gun hand (gauge on the wireframe).")
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
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fire gesture").font(.caption).foregroundStyle(.secondary)
                    Picker("Fire gesture", selection: Binding(
                        get: { fireMode },
                        set: { fireMode = $0; VRSettings.shared.fireMode = $0
                               ProfileStore.shared.current.fireMode = $0.rawValue })) {
                        Text("Pinch").tag(FireMode.pinch)
                        Text("Curl").tag(FireMode.curl)
                        Text("Bang").tag(FireMode.hammer)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Gesture tuning").font(.caption).foregroundStyle(.secondary)
                    tuneRow("Aim smoothing", $aimSmoothUI, 0.1...1.0) {
                        VRSettings.shared.aimSmooth = $0; ProfileStore.shared.current.aimSmooth = $0 }
                    tuneRow("Aim finger-mix", $aimBlendUI, 0.0...1.0) {
                        VRSettings.shared.aimBlend = $0; ProfileStore.shared.current.aimBlend = $0 }
                    tuneRow("Curl ease", $curlSensUI, 0.6...0.85) {
                        VRSettings.shared.curlSensitivity = $0; ProfileStore.shared.current.curlSensitivity = $0 }
                    tuneRow("Hammer angle", $hammerDropUI, 30...60, fmt: "%.0f°") {
                        VRSettings.shared.hammerDropDeg = $0; ProfileStore.shared.current.hammerDropDeg = $0 }
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
    /// until a level is loaded (the engine is running).
    private var adminContent: some View {
        let running = engine.status == .running
        return VStack(alignment: .leading, spacing: 10) {
            Text("Single-player only. Needs a level loaded.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Restart level") { engine.send("restart") }
            Button("All weapons + ammo") { engine.send("impulse 9") }
            Button("Full health") { engine.send("give h 100") }
            Divider()
            Text("Toggles (each press flips)").font(.caption).foregroundStyle(.secondary)
            Button("God mode") { engine.send("god") }
            Button("Noclip") { engine.send("noclip") }
            Button("Notarget") { engine.send("notarget") }
            Button("Fly") { engine.send("fly") }
        }
        .buttonStyle(.bordered)
        .disabled(!running)
    }

    /// Debug tab: overlay/meter toggles, the input telemetry log, and the
    /// on-arm HUD placement rig (moved out of the overloaded Comfort section).
    private var debugContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Finger debug wireframe", isOn: Binding(
                get: { fingerDebug },
                set: { fingerDebug = $0; HandDebug.shared.enabled = $0 }))
            Toggle("Show real hands / controllers", isOn: Binding(
                get: { showLimbs },
                set: { showLimbs = $0; ImmersionSettings.shared.handsVisible = $0 }))
            Toggle("Input telemetry log (console)", isOn: Binding(
                get: { inputLog },
                set: { inputLog = $0; VRSettings.shared.inputLog = $0 }))
            Toggle("Enemy AI debug (trails + targets)", isOn: Binding(
                get: { pathDebug },
                set: { pathDebug = $0; engine.send("vr_pathdebug \($0 ? 1 : 0)") }))
            Toggle("Aim-ray decomposition (figure)", isOn: Binding(
                get: { aimRayDebug },
                set: { aimRayDebug = $0; HandDebug.shared.aimRays = $0 }))
            Toggle("Motion strobe: aim ray (figure)", isOn: Binding(
                get: { strobeDebug },
                set: { strobeDebug = $0; HandDebug.shared.strobe = $0 }))
            Toggle("Turn trigger meter (stick/clutch/flick)", isOn: Binding(
                get: { turnDebug },
                set: { turnDebug = $0; HandDebug.shared.turnDebug = $0 }))
            Toggle("Fire threshold meter (pinch/curl/bang)", isOn: Binding(
                get: { fireDebug },
                set: { fireDebug = $0; HandDebug.shared.fireDebug = $0 }))
            // HUD dock placement as typed transform fields (exact numbers beat
            // fishing with sliders). Position in cm, rotation in degrees.
            VStack(alignment: .leading, spacing: 8) {
                Text("HUD Position").font(.caption.weight(.semibold))
                transformField("Fwd X", $hudFwdUI, unit: "cm", display: 100) {
                    VRSettings.shared.hudForward = $0; ProfileStore.shared.current.hudForward = $0 }
                transformField("Up Y", $hudUpUI, unit: "cm", display: 100) {
                    VRSettings.shared.hudUp = $0; ProfileStore.shared.current.hudUp = $0 }
                transformField("Side Z", $hudSideUI, unit: "cm", display: 100) {
                    VRSettings.shared.hudSide = $0; ProfileStore.shared.current.hudSide = $0 }
                Text("HUD Transform").font(.caption.weight(.semibold)).padding(.top, 2)
                HStack(alignment: .center, spacing: 14) {
                    gyroDial
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Gun placement").font(.headline)
                        Text("Slide the gun onto your hand — updates live in the headset.")
                            .font(.caption).foregroundStyle(.secondary)
                        placementSlider("Back", $weaponBack, in: -20...30, cvar: "vr_weaponback", persist: \.weaponBack)
                        placementSlider("Up", $weaponUp, in: -15...15, cvar: "vr_weaponup", persist: \.weaponUp)
                        placementSlider("Side", $weaponSide, in: -15...15, cvar: "vr_weaponside", persist: \.weaponSide)
                        placementSlider("Grip", $weaponGrip, in: 0...1, cvar: "vr_weapongrip", fmt: "%.2f", persist: \.weaponGrip)
                        placementSlider("Aim°", $aimPitch, in: -20...20, cvar: "vr_aimpitch", persist: \.aimPitch)
                        trimSlider("Trim front", $weaponClip) { WeaponTrim.shared.setFront($0) }
                        trimSlider("Trim rear", $weaponClipBack) { WeaponTrim.shared.setRear($0) }
                        Text("Per-weapon: front = barrel end, rear = arm end. Trimming the rear also re-seats the gun on your hand.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Reset gun") {
                            weaponBack = 0; weaponUp = 0; weaponSide = 0
                            weaponGrip = 0.15; aimPitch = 0
                            for c in ["vr_weaponback 0", "vr_weaponup 0", "vr_weaponside 0",
                                      "vr_weapongrip 0.15", "vr_aimpitch 0"] { engine.send(c) }
                            var p = ProfileStore.shared.current
                            p.weaponBack = 0; p.weaponUp = 0; p.weaponSide = 0
                            p.weaponGrip = 0.15; p.aimPitch = 0
                            ProfileStore.shared.current = p
                            WeaponTrim.shared.resetCurrent()
                            weaponClip = WeaponTrim.shared.currentFront
                            weaponClipBack = WeaponTrim.shared.currentRear
                        }
                        .font(.caption)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Aiming laser", isOn: Binding(
                            get: { laser },
                            set: { laser = $0; engine.send("vr_laser \($0 ? 1 : 0)")
                                   ProfileStore.shared.current.laser = $0 }))
                            .font(.headline)
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
    private var gyroDial: some View {
        let size: CGFloat = 96
        let ringBand: CGFloat = 16                 // outer band width = roll grab zone
        let degPerPt: Float = 0.6                  // tumble sensitivity
        return ZStack {
            Circle().fill(Self.noctuaBrown.opacity(0.18))
            Circle().strokeBorder(Self.noctuaBrown.opacity(0.75), lineWidth: 1.5)
            Circle().inset(by: ringBand).strokeBorder(Self.noctuaBrown.opacity(0.5), lineWidth: 1)
            // A roll indicator dot on the ring so the spin is readable.
            Circle().fill(Self.noctuaBurgundy).frame(width: 7, height: 7)
                .offset(y: -(size / 2 - ringBand / 2 - 1))
                .rotationEffect(.degrees(Double(hudRollUI)))
        }
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
                    hudRollUI = max(-180, min(180, hudRollUI + d))
                    VRSettings.shared.hudRoll = hudRollUI
                    ProfileStore.shared.current.hudRoll = hudRollUI
                } else {
                    hudYawUI = max(-180, min(180, hudYawUI + Float(p.x - last.x) * degPerPt))
                    hudPitchUI = max(-90, min(90, hudPitchUI + Float(p.y - last.y) * degPerPt))
                    VRSettings.shared.hudYaw = hudYawUI
                    VRSettings.shared.hudPitch = hudPitchUI
                    ProfileStore.shared.current.hudYaw = hudYawUI
                    ProfileStore.shared.current.hudPitch = hudPitchUI
                }
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
        turnStyle = TurnStyle(rawValue: p.turnStyle) ?? .stick
        aimSmoothUI = p.aimSmooth; aimBlendUI = p.aimBlend
        curlSensUI = p.curlSensitivity; hammerDropUI = p.hammerDropDeg
        hudFwdUI = p.hudForward; hudUpUI = p.hudUp; hudSideUI = p.hudSide
        hudPitchUI = p.hudPitch; hudRollUI = p.hudRoll; hudYawUI = p.hudYaw ?? 0
        hudFaceUI = p.hudFaceMe; hudScaleUI = p.hudScale
        weaponBack = p.weaponBack; weaponUp = p.weaponUp; weaponSide = p.weaponSide
        weaponGrip = p.weaponGrip; aimPitch = p.aimPitch
        laser = p.laser
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

    private func updateHands() {
        hands?.setActive(coordinator.isImmersiveActive && !gamepad.hasPhysicalController)
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
        if hands?.isRunning == true {
            return ("Hands — pinch left to move, right to fire", "hand.pinch")
        }
        return ("No controller — console input only", "gamecontroller")
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

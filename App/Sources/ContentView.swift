//
//  ContentView.swift
//
//  The Metal world view over the M0 console. The console stays: with no HUD
//  or in-game console text yet, the command bar is still the only input, and
//  the log is still where the engine talks back.
//

import SwiftUI
import UIKit

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
    @State private var showWeapon = false
    @State private var weaponBack: Float = 0
    @State private var weaponUp: Float = 0
    @State private var weaponSide: Float = 0
    @State private var weaponGrip: Float = 0.15
    @State private var aimPitch: Float = 0
    @State private var weaponClip: Float = 1
    @State private var weaponClipBack: Float = 1
    @State private var laserForward: Float = 0
    @State private var laserUp: Float = 0
    @State private var laserSide: Float = 0
    @State private var laserPitch: Float = 0
    @State private var laserYaw: Float = 0
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    private var coordinator: RendererCoordinator { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 16) {
                if engine.status == .running {
                    phaseControls
                }
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
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 560)
        .onAppear {
            engine.boot()
            gamepad.start()
            hands = HandInput(aggregator: gamepad.aggregator)
            // The wheel commits through the one console route.
            let engine = self.engine
            WheelState.shared.sendCommand = { command in
                Task { @MainActor in engine.send(command) }
            }
        }
        // Hands drive the game only while immersed with no hardware
        // attached; a controller connecting mid-session takes over.
        .onChange(of: coordinator.isImmersiveActive) { _, active in
            updateHands()
            // The scope earns its room while immersed (no preview pane);
            // windowed, it stays behind its toggle.
            if active { showScope = true }
        }
        .onChange(of: gamepad.hasPhysicalController) { _, _ in updateHands() }
        .onChange(of: engine.status) { _, status in
            // Force the phase melt OFF when the engine comes up. It's a
            // head-centred sphere that dissolves nearby surfaces to
            // passthrough; a stale/nonzero `phase` (from a prior config or a
            // stray slider) leaves it melting the stairs you stand on. The UI
            // starts at 0%, so match it.
            if status == .running {
                engine.send("phase 0")
                phaseLevel = 0
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
                comfortMenu
                weaponMenu
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
    private var comfortMenu: some View {
        Button {
            showComfort.toggle()
        } label: {
            Label("Comfort", systemImage: "slider.horizontal.3")
        }
        .popover(isPresented: $showComfort, arrowEdge: .bottom) {
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Eye height  \(heightOffset >= 0 ? "+" : "")\(Int(heightOffset * 100)) cm")
                        .font(.headline)
                    Text("Raise until the floor sits at your real floor.")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(heightOffset) },
                        set: { heightOffset = Float($0); VRSettings.shared.heightOffset = Float($0) }),
                        in: -0.6...0.9)
                    HStack {
                        Button("Reset") {
                            heightOffset = 0.4; VRSettings.shared.heightOffset = 0.4
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
                    Text("Whip the gun hand sideways to turn. Turn on the wireframe to see the flick gauge.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Flick ease").font(.caption)
                        Slider(value: Binding(
                            get: { Double(turnFlick) },
                            set: { turnFlick = Float($0)
                                   VRSettings.shared.turnFlickSpeed = Float($0) }),
                               in: 0.4...1.6)
                        Text(String(format: "%.2f", turnFlick))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Toggle("Slow-mo while weapon wheel is open", isOn: Binding(
                    get: { wheelSlowmo },
                    set: { wheelSlowmo = $0; engine.send("wheel_timescale \($0 ? "0.2" : "1")") }))
                Toggle("Finger debug wireframe", isOn: Binding(
                    get: { fingerDebug },
                    set: { fingerDebug = $0; HandDebug.shared.enabled = $0 }))
                Toggle("Show real hands / controllers", isOn: Binding(
                    get: { showLimbs },
                    set: { showLimbs = $0; ImmersionSettings.shared.handsVisible = $0 }))
            }
            .padding(24)
            .frame(width: 360)
            }
            .frame(maxHeight: 620)
        }
    }

    /// Weapon rig: gun placement and the aiming laser, in their own popover so
    /// the Comfort panel isn't buried. Every slider pushes its cvar live.
    private var weaponMenu: some View {
        Button {
            showWeapon.toggle()
        } label: {
            Label("Weapon", systemImage: "scope")
        }
        .popover(isPresented: $showWeapon, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Gun placement").font(.headline)
                        Text("Slide the gun onto your hand — updates live in the headset.")
                            .font(.caption).foregroundStyle(.secondary)
                        placementSlider("Back", $weaponBack, in: -20...30, cvar: "vr_weaponback")
                        placementSlider("Up", $weaponUp, in: -15...15, cvar: "vr_weaponup")
                        placementSlider("Side", $weaponSide, in: -15...15, cvar: "vr_weaponside")
                        placementSlider("Grip", $weaponGrip, in: 0...1, cvar: "vr_weapongrip", fmt: "%.2f")
                        placementSlider("Aim°", $aimPitch, in: -20...20, cvar: "vr_aimpitch")
                        placementSlider("Trim front", $weaponClip, in: 0.5...1, cvar: "vr_weaponclip", fmt: "%.2f")
                        placementSlider("Trim rear", $weaponClipBack, in: 0.5...1, cvar: "vr_weaponclipback", fmt: "%.2f")
                        Text("Trim < 1 retracts baked-in geometry — front = barrel end, rear = arm end.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Reset gun") {
                            weaponBack = 0; weaponUp = 0; weaponSide = 0
                            weaponGrip = 0.15; aimPitch = 0; weaponClip = 1; weaponClipBack = 1
                            for c in ["vr_weaponback 0", "vr_weaponup 0", "vr_weaponside 0",
                                      "vr_weapongrip 0.15", "vr_aimpitch 0",
                                      "vr_weaponclip 1", "vr_weaponclipback 1"] { engine.send(c) }
                        }
                        .font(.caption)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Aiming laser", isOn: Binding(
                            get: { laser },
                            set: { laser = $0; engine.send("vr_laser \($0 ? 1 : 0)") }))
                            .font(.headline)
                        Text("Move the beam's start to the barrel tip. Forward reaches the muzzle.")
                            .font(.caption).foregroundStyle(.secondary)
                        placementSlider("Fwd", $laserForward, in: -10...60, cvar: "vr_laserforward")
                        placementSlider("Up", $laserUp, in: -15...15, cvar: "vr_laserup")
                        placementSlider("Side", $laserSide, in: -15...15, cvar: "vr_laserside")
                        placementSlider("Tilt°", $laserPitch, in: -10...10, cvar: "vr_laserpitch", fmt: "%.1f")
                        placementSlider("Pan°", $laserYaw, in: -10...10, cvar: "vr_laseryaw", fmt: "%.1f")
                        Button("Reset laser") {
                            laserForward = 0; laserUp = 0; laserSide = 0
                            laserPitch = 0; laserYaw = 0
                            for c in ["vr_laserforward 0", "vr_laserup 0", "vr_laserside 0",
                                      "vr_laserpitch 0", "vr_laseryaw 0"] {
                                engine.send(c)
                            }
                        }
                        .font(.caption)
                    }
                }
                .padding(24)
                .frame(width: 360)
            }
            .frame(maxHeight: 620)
        }
    }

    /// One row of the weapon-placement panel: a labelled slider that pushes
    /// its cvar to the engine on every change, so the gun moves live in the
    /// headset. No console typing, no autocomplete needed.
    private func placementSlider(_ label: String, _ value: Binding<Float>,
                                 in range: ClosedRange<Double>, cvar: String,
                                 fmt: String = "%.0f") -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 40, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Float($0)
                       engine.send("\(cvar) \(Float($0))") }),
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

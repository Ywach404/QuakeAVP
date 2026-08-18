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
    @State private var seated = false
    @State private var rightHanded = true
    @State private var lookRelative = true
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
            // Test harness: QAVP_AUTO_IMMERSIVE=1 opens the space as soon as
            // the engine is up, so simctl/devicectl runs need no UI taps;
            // =cycle additionally dismisses and reopens it once, which is
            // the lifecycle test (no leak, no crash, engine keeps ticking).
            let mode = ProcessInfo.processInfo.environment["QAVP_AUTO_IMMERSIVE"]
            guard status == .running, !autoOpened, mode == "1" || mode == "cycle"
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

    /// Comfort and handedness toggles — seated raises the eye to standing
    /// height, handedness swaps which hand aims vs moves.
    private var comfortMenu: some View {
        Menu {
            Toggle("Seated", isOn: Binding(
                get: { seated },
                set: { seated = $0; VRSettings.shared.seated = $0 }))
            Picker("Dominant hand", selection: Binding(
                get: { rightHanded },
                set: { rightHanded = $0; VRSettings.shared.rightHanded = $0 })) {
                Text("Right-handed").tag(true)
                Text("Left-handed").tag(false)
            }
            Toggle("Move where I look", isOn: Binding(
                get: { lookRelative },
                set: { lookRelative = $0; engine.send("vr_moverelative \($0 ? 1 : 0)") }))
        } label: {
            Label("Comfort", systemImage: "figure.seated.side")
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

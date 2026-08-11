//
//  ContentView.swift
//
//  The Metal world view over the M0 console. The console stays: with no HUD
//  or in-game console text yet, the command bar is still the only input, and
//  the log is still where the engine talks back.
//

import SwiftUI

struct ContentView: View {
    @State private var engine = QuakeEngineViewModel()
    @State private var commandText = ""
    @State private var autoOpened = false
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    private var coordinator: RendererCoordinator { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if engine.status == .running {
                phaseControls
            }
            renderSurface
            // While the world view is up the console shrinks to a log strip
            // (sized so the phase strip fits in the same window height);
            // in every other state it is still the whole interface.
            console
                .frame(maxHeight: engine.status == .running ? 96 : .infinity)
            commandBar
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 560)
        .onAppear { engine.boot() }
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
        if engine.status == .running {
            if coordinator.isImmersiveActive {
                ContentUnavailableView(
                    "Rendering in the immersive space",
                    systemImage: "visionpro",
                    description: Text("The window view resumes when you exit."))
                .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
                .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
            } else {
                QuakeRenderView(paused: false)
                    .clipShape(.rect(cornerRadius: 12))
                    .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
            }
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
            }
            Spacer()
            phaseButton
            immersiveButton
            statusBadge
        }
    }

    @State private var phaseLevel = 0.0
    @State private var phaseSpeed = 2.0

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

    /// Crown-style dissolve control, like the system environments: the dial
    /// scrubs the `phase` target (the engine eases toward it, so a partial
    /// twist is a partial melt) and the menu picks the sweep speed.
    private var phaseControls: some View {
        HStack(spacing: 16) {
            PhaseDial(value: $phaseLevel)
                .onChange(of: phaseLevel) { _, level in
                    engine.send(String(format: "phase %.2f", level))
                }
            VStack(alignment: .leading, spacing: 6) {
                Text("Phase \(Int((phaseLevel * 100).rounded()))%")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
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
                        .font(.callout)
                }
                .fixedSize()
            }
            Spacer()
        }
        .padding(.horizontal, 4)
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

    private func submit() {
        let text = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        engine.send(text)
        commandText = ""
    }
}

/// Pinch-and-twist dial for the phase target. A drag anywhere on the dial
/// maps the pinch position's angle around the centre onto 0...1 over a
/// 270-degree sweep, gap at the bottom — grab the ring and twist.
/// TODO(M4+): this control wants to leave the window — bonded to the
/// hand/arm as spatial UI — and once the space adopts progressive
/// immersion the system immersion amount (the crown) feeds `phase`
/// directly.
private struct PhaseDial: View {
    @Binding var value: Double

    private static let size: CGFloat = 72
    private static let sweep = 270.0

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: Self.sweep / 360)
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(90 + (360 - Self.sweep) / 2))
            Circle()
                .trim(from: 0, to: Self.sweep / 360 * value)
                .stroke(.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(90 + (360 - Self.sweep) / 2))
            Circle()
                .fill(.primary)
                .frame(width: 9, height: 9)
                .offset(y: -Self.size / 2)
                .rotationEffect(.degrees(Self.sweep * (value - 0.5)))
            Image(systemName: "circle.dotted")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    // Degrees clockwise from straight up; the dead zone at
                    // the bottom clamps to the nearer end stop.
                    let dx = drag.location.x - Self.size / 2
                    let dy = drag.location.y - Self.size / 2
                    let degrees = atan2(dx, -dy) * 180 / .pi
                    let clamped = min(max(degrees, -Self.sweep / 2), Self.sweep / 2)
                    value = (clamped + Self.sweep / 2) / Self.sweep
                }
        )
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
}

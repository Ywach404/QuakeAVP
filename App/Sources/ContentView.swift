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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            renderSurface
            // While the world view is up the console shrinks to a log strip;
            // in every other state it is still the whole interface.
            console
                .frame(maxHeight: engine.status == .running ? 160 : .infinity)
            commandBar
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 560)
        .onAppear { engine.boot() }
    }

    @ViewBuilder
    private var renderSurface: some View {
        if engine.status == .running {
            QuakeRenderView()
                .clipShape(.rect(cornerRadius: 12))
                .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
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
            statusBadge
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

#Preview(windowStyle: .automatic) {
    ContentView()
}

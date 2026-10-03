//
//  QuakeEngineViewModel.swift
//
//  Owns the engine for the life of the APP, not the life of a window.
//
//  This used to be @State on ContentView. Closing the console window destroyed
//  the view model while its engine thread kept running (nothing calls
//  shutdown), and reopening built a fresh one at status .idle, which booted a
//  SECOND QuakeEngineHost over the same Quake globals -- which have no locking,
//  and whose Sys_Error calls exit(). The per-instance `thread == nil` guard in
//  QuakeEngineHost cannot catch that, because the new host is a new instance.
//
//  Latent until the prayer-sign summon made reopening the window routine. Same
//  shape as the input-ownership bug; see InputHost.
//

import Foundation
import Observation

@Observable
@MainActor
final class QuakeEngineViewModel {

    /// The one engine. `boot()` is idempotent against this instance's status,
    /// so a reopened window re-attaches instead of starting a second engine --
    /// and the console log survives the window closing.
    static let shared = QuakeEngineViewModel()

    enum Status: Equatable {
        case idle
        case missingGameData
        case running
        case stopped
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var consoleLines: [String] = []
    private(set) var paths: QuakePaths?

    var engineVersion: String { String(cString: QC_VersionString()) }

    /// The console can outrun the UI badly during map load. Keep a window.
    private let maxConsoleLines = 500
    private var partialLine = ""
    private var host: QuakeEngineHost?

    func boot() {
        guard status == .idle || status == .stopped else { return }

        let paths: QuakePaths
        do {
            paths = try QuakePaths.standard()
        } catch {
            status = .failed("Could not prepare directories: \(error.localizedDescription)")
            return
        }
        self.paths = paths

        guard paths.hasGameData else {
            status = .missingGameData
            return
        }

        consoleLines.removeAll()
        partialLine = ""

        let host = QuakeEngineHost(
            onLog: { [weak self] text in self?.append(text) },
            onExit: { [weak self] error in self?.finish(error: error) }
        )
        self.host = host
        status = .running
        host.start(paths: paths)
    }

    func shutdown() {
        host?.stop()
    }

    func send(_ command: String) {
        guard status == .running else { return }
        host?.execute(command.hasSuffix("\n") ? command : command + "\n")
    }

    /// The running engine host, for the exporter's lock-step driving.
    var engineHost: QuakeEngineHost? { host }

    /// Append a line to the console log WITHOUT sending it to the engine, so
    /// diagnostics are readable in the headset instead of only on a Mac that
    /// is in another room while you are wearing the thing being measured.
    func note(_ line: String) {
        consoleLines.append(line)
        if consoleLines.count > maxConsoleLines {
            consoleLines.removeFirst(consoleLines.count - maxConsoleLines)
        }
    }

    // MARK: - Private

    /// Sys_Printf emits arbitrary fragments, not lines. Reassemble.
    private func append(_ text: String) {
        partialLine += text

        while let newline = partialLine.firstIndex(of: "\n") {
            consoleLines.append(String(partialLine[partialLine.startIndex..<newline]))
            partialLine = String(partialLine[partialLine.index(after: newline)...])
        }

        if consoleLines.count > maxConsoleLines {
            consoleLines.removeFirst(consoleLines.count - maxConsoleLines)
        }
    }

    private func finish(error: String?) {
        if !partialLine.isEmpty {
            consoleLines.append(partialLine)
            partialLine = ""
        }
        status = error.map { Status.failed($0) } ?? .stopped
        host = nil
    }
}

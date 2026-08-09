//
//  QuakeEngineViewModel.swift
//

import Foundation
import Observation

@Observable
@MainActor
final class QuakeEngineViewModel {

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

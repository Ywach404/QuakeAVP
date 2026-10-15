// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  CaptureState.swift
//
//  The Capture tab's model: what demos exist (and which have a head track),
//  whether a recording is in flight, and the record/stop commands. The demo
//  itself is the engine's `record`/`stop`; the sidecar is TrackRecorder,
//  started and stopped in the same breath so the two always cover the same
//  span of demo time.
//

import Foundation
import Observation

@Observable
@MainActor
final class CaptureState {

    struct DemoFile: Identifiable, Equatable {
        let name: String
        let hasTrack: Bool
        let modified: Date
        var id: String { name }
    }

    private(set) var demos: [DemoFile] = []
    private(set) var isRecording = false
    private(set) var currentName = ""

    /// Quake refuses `..` and the filesystem dislikes the rest; keep names
    /// to what both accept. Empty after cleaning becomes "clip".
    nonisolated static func sanitise(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let cleaned = String(raw.filter { allowed.contains($0) })
        return cleaned.isEmpty ? "clip" : cleaned
    }

    /// "clip-20260924-0113": sortable, unique to the minute.
    nonisolated static func defaultName(now: Date = .now, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmm"
        return "clip-" + f.string(from: now)
    }

    func refresh(gameDirectory: URL) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: gameDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var list: [DemoFile] = []
        for url in items where url.pathExtension.lowercased() == "dem" {
            let name = url.deletingPathExtension().lastPathComponent
            let track = gameDirectory.appendingPathComponent("\(name).vrtrack")
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            list.append(DemoFile(name: name, hasTrack: fm.fileExists(atPath: track.path), modified: modified))
        }
        list.sort { $0.modified > $1.modified }
        if list != demos { demos = list }
    }

    func startRecording(name: String, gameDirectory: URL, engine: QuakeEngineViewModel) {
        guard !isRecording else { return }
        let clean = Self.sanitise(name)
        currentName = clean
        isRecording = true
        TrackRecorder.shared.start(url: gameDirectory.appendingPathComponent("\(clean).vrtrack"))
        engine.send("record \(clean)")
    }

    func stopRecording(engine: QuakeEngineViewModel, gameDirectory: URL) {
        guard isRecording else { return }
        engine.send("stop")
        TrackRecorder.shared.stop()
        isRecording = false
        // The sidecar lands on a background queue; list again shortly so the
        // badge shows without a manual refresh.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            refresh(gameDirectory: gameDirectory)
        }
    }
}

//
//  QuakeEngineHost.swift
//
//  Owns the C engine's lifetime and its thread.
//
//  Quake's host loop is single-threaded and re-entrant-hostile: Host_Frame
//  touches global state with no locking, and Sys_Error unwinds by calling
//  exit(). So the engine gets one dedicated thread, created here, and every
//  call into QuakeCore happens on it. Nothing else may call QC_*.
//
//  Output flows the other way: the C log callback fires on the engine thread
//  and hops to the main actor to update observable state.
//

import Foundation

/// Where the engine looks for game data, and where it may write.
struct QuakePaths {
    let baseDirectory: URL
    let userDirectory: URL

    /// Game data is not redistributable, so `id1/pak0.pak` is expected in the
    /// app's Documents folder — droppable over the Files app because the
    /// target sets `UIFileSharingEnabled`.
    static func standard() throws -> QuakePaths {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let userDirectory = support.appendingPathComponent("QuakeAVP", isDirectory: true)
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)

        seedBundledGameData(into: documents)

        return QuakePaths(baseDirectory: documents, userDirectory: userDirectory)
    }

    /// DEV ONLY -- strip before release (see project.yml `App/DevGameData`).
    /// The author's own paks are bundled into the dev build; copy any that are
    /// missing from Documents/id1 so the game runs without a manual Files copy.
    /// Only fills gaps -- a real user-supplied pak in Documents always wins and
    /// is never overwritten. A release build simply has no bundled paks, so
    /// this no-ops and the Documents/Files flow is unchanged.
    private static func seedBundledGameData(into baseDirectory: URL) {
        let fm = FileManager.default
        let id1 = baseDirectory.appendingPathComponent("id1", isDirectory: true)
        try? fm.createDirectory(at: id1, withIntermediateDirectories: true)
        for name in ["pak0", "pak1"] {
            guard let src = Bundle.main.url(forResource: name, withExtension: "pak") else {
                print("[seed] no bundled \(name).pak in the app -- skipping")
                continue
            }
            let dst = id1.appendingPathComponent("\(name).pak")
            let bundleSize = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let dstSize = try? dst.resourceValues(forKeys: [.fileSizeKey]).fileSize
            // Copy when absent OR when a stale/partial file is there (size
            // mismatch) -- so a bad pak the user dropped earlier gets replaced
            // with the known-good bundled one. A matching size is left alone.
            if dstSize == bundleSize {
                print("[seed] \(name).pak already present (\(bundleSize) bytes)")
                continue
            }
            try? fm.removeItem(at: dst)
            do {
                try fm.copyItem(at: src, to: dst)
                print("[seed] copied \(name).pak into Documents/id1 (\(bundleSize) bytes)")
            } catch {
                print("[seed] FAILED to copy \(name).pak: \(error)")
            }
        }
    }

    /// True when `id1/pak0.pak` is actually present. Checked before boot so the
    /// UI can explain the problem instead of letting the engine Sys_Error out
    /// (which takes the process with it).
    var hasGameData: Bool {
        let pak = baseDirectory
            .appendingPathComponent("id1", isDirectory: true)
            .appendingPathComponent("pak0.pak")
        return FileManager.default.fileExists(atPath: pak.path)
    }
}

/// Non-isolated box the C callbacks write into. `Unmanaged` pointers are handed
/// to C, so this must be a class and must outlive the engine thread.
final class QuakeEngineHost: @unchecked Sendable {

    /// Called on the main actor for every line the engine logs.
    private let onLog: @MainActor @Sendable (String) -> Void
    /// Called on the main actor if the engine dies. `nil` means clean quit.
    private let onExit: @MainActor @Sendable (String?) -> Void

    private var thread: Thread?
    private let shouldStop = ManagedAtomicFlag()

    /// Frame pacing for M0. At M3 this disappears: CompositorServices'
    /// `LayerRenderer.queryNextFrame()` becomes the clock and the engine ticks
    /// once per drawable instead of on a fixed timer.
    private let targetFrameInterval: Double = 1.0 / 90.0

    init(
        onLog: @escaping @MainActor @Sendable (String) -> Void,
        onExit: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        self.onLog = onLog
        self.onExit = onExit
    }

    func start(paths: QuakePaths) {
        guard thread == nil else { return }

        let thread = Thread { [weak self] in
            self?.run(paths: paths)
        }
        thread.name = "quake.host"
        // Quake's zone allocator is happy in 512 KB, but PR_ExecuteProgram
        // recurses through QuakeC and the default 512 KB secondary-thread
        // stack is uncomfortably tight.
        thread.stackSize = 4 << 20
        thread.qualityOfService = .userInteractive

        self.thread = thread
        thread.start()
    }

    func stop() {
        shouldStop.set()
    }

    /// Park the 90 Hz pacer; frames now run only on `step(dt:)`. The
    /// exporter uses this to lock-step the engine through a demo.
    func beginStepping() { stepGate.begin() }
    func endStepping() { stepGate.end() }

    /// Block until the engine thread has drained queued commands and run one
    /// frame of `dt`. False if the engine is not running. Never call from
    /// the engine thread itself (it would wait on itself).
    @discardableResult
    func step(dt: Double) -> Bool {
        guard thread != nil, !shouldStop.isSet, stepGate.isStepping else { return false }
        stepGate.request(dt: dt)
        return true
    }

    private let stepGate = StepGate()

    func execute(_ command: String) {
        // Cbuf_AddText is not thread-safe; queue for the engine thread, which
        // drains before each frame. NOT perform(onThread:) -- that delivers
        // via the target thread's run loop, and the engine thread never runs
        // one (it sits in the frame loop below), so commands sent that way
        // queue forever and silently do nothing.
        guard thread != nil else { return }
        pendingCommands.append(command)
    }

    private let pendingCommands = CommandQueue()

    // MARK: - Engine thread

    private func run(paths: QuakePaths) {
        let context = Unmanaged.passUnretained(self).toOpaque()

        QC_SetCallbacks(
            { ctx, text in
                guard let ctx, let text else { return }
                let host = Unmanaged<QuakeEngineHost>.fromOpaque(ctx).takeUnretainedValue()
                let line = String(cString: text)
                let sink = host.onLog
                Task { @MainActor in sink(line) }
            },
            { ctx, error in
                guard let ctx else { return }
                let host = Unmanaged<QuakeEngineHost>.fromOpaque(ctx).takeUnretainedValue()
                let message = error.map { String(cString: $0) }
                let sink = host.onExit
                Task { @MainActor in sink(message) }
            },
            context
        )

        paths.baseDirectory.path.withCString { base in
            paths.userDirectory.path.withCString { user in
                QC_SetPaths(base, user)
            }
        }

        var argv: [UnsafePointer<CChar>?] = []
        let basedirFlag = strdup("-basedir")!
        let basedirValue = strdup(paths.baseDirectory.path)!
        argv.append(UnsafePointer(basedirFlag))
        argv.append(UnsafePointer(basedirValue))

        let ok = argv.withUnsafeBufferPointer { buffer in
            QC_Init(Int32(buffer.count), buffer.baseAddress)
        }

        free(basedirFlag)
        free(basedirValue)

        guard ok else {
            let sink = onExit
            Task { @MainActor in sink("QC_Init returned false") }
            return
        }

        // Force dynamic lighting on after config.cfg has loaded. r_dynamic is
        // CVAR_ARCHIVE, so a stray "0" (e.g. left from a debugging session)
        // persists and silently kills muzzle-flash flares and the dynamic
        // lightmap light/dark shading. This port always wants it lit; the
        // user can still toggle it for the current session.
        "r_dynamic 1\n".withCString { QC_ExecuteCommand($0) }

        // Open at a calm mix instead of Quake's full-blast archived defaults
        // (both CVAR_ARCHIVE, kept byte-identical with upstream; forced here
        // after config.cfg loads so the archived values don't win). Sound
        // effects start very quiet (3%) and music moderate (70%); the player
        // can raise either from the sound mixer. Keep these in sync with
        // ContentView.sfxVolume / musicVolume starting values.
        "volume 0.03\n".withCString { QC_ExecuteCommand($0) }
        "bgmvolume 0.7\n".withCString { QC_ExecuteCommand($0) }

        var previous = CFAbsoluteTimeGetCurrent()

        while !shouldStop.isSet {
            if stepGate.isStepping {
                // Lock-step mode: one frame per request, no pacer. A nil
                // take means the mode ended; fall through to real time with
                // a fresh clock so the first paced frame is not a giant dt.
                guard let dt = stepGate.take() else {
                    previous = CFAbsoluteTimeGetCurrent()
                    continue
                }
                for command in pendingCommands.drain() {
                    command.withCString { QC_ExecuteCommand($0) }
                }
                QC_Frame(dt)
                stepGate.done()
                continue
            }

            let now = CFAbsoluteTimeGetCurrent()
            let delta = now - previous
            previous = now

            for command in pendingCommands.drain() {
                command.withCString { QC_ExecuteCommand($0) }
            }
            QC_Frame(delta)

            let spent = CFAbsoluteTimeGetCurrent() - now
            let remaining = targetFrameInterval - spent
            if remaining > 0 {
                Thread.sleep(forTimeInterval: remaining)
            }
        }

        QC_Shutdown()

        let sink = onExit
        Task { @MainActor in sink(nil) }
    }

}

/// Locked FIFO between the UI (append) and the engine thread (drain).
private final class CommandQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []

    func append(_ command: String) {
        lock.lock(); defer { lock.unlock() }
        commands.append(command)
    }

    func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let drained = commands
        commands.removeAll(keepingCapacity: true)
        return drained
    }
}

/// One-at-a-time lock-step requests from the exporter to the engine thread.
/// `request` blocks the caller until the engine thread has run the frame.
private final class StepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingDt: Double?
    private var stepping = false
    private let requested = DispatchSemaphore(value: 0)
    private let completed = DispatchSemaphore(value: 0)

    var isStepping: Bool { lock.lock(); defer { lock.unlock() }; return stepping }

    func begin() { lock.lock(); stepping = true; lock.unlock() }

    func end() {
        lock.lock(); stepping = false; lock.unlock()
        requested.signal()      // wake the engine thread so it sees the mode change
    }

    /// Caller side. Returns once the engine ran the frame.
    func request(dt: Double) {
        lock.lock(); pendingDt = dt; lock.unlock()
        requested.signal()
        completed.wait()
    }

    /// Engine-thread side: wait for a request; nil means "mode ended".
    func take() -> Double? {
        requested.wait()
        lock.lock(); defer { lock.unlock() }
        guard stepping, let dt = pendingDt else { return nil }
        pendingDt = nil
        return dt
    }

    func done() { completed.signal() }
}

/// Minimal one-way flag. One writer (main), one reader (engine thread); a lock
/// is cheaper to reason about here than importing Atomics for a single bool.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

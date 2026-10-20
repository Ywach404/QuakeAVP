// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  FloorSource.swift
//
//  Owns a plane-detection provider in an ARKit session of its own and
//  publishes one number: the height of the real floor in the provider's
//  tracking frame. The immersive renderer anchors the player's feet to it.
//
//  Its own session, not the world-tracking one, on purpose. That session's
//  supervisor retries a failed run forever, and plane detection is the
//  first provider in this app that needs a permission the player can
//  refuse: a refusal inside the same run call would take head tracking
//  down with it. Here a refusal is logged once and the source goes quiet,
//  and the renderer keeps the eye-locked mapping it has always had.
//
//  Lifecycle mirrors DeviceAnchorSource: a provider is single-use, every
//  interruption stops it, and recovery is a new provider on a new session.
//  What differs is the data path. Plane detection has no per-timestamp
//  query; anchors arrive on a stream, so the supervisor also owns a drain
//  task that folds updates into a lock-guarded selection, and the render
//  thread reads the result with a plain locked read.
//
//  A rebuilt provider may carry a new tracking origin, so its planes are
//  not comparable with the old one's. On rebuild the selection starts
//  over: the last published height stays readable until the new provider
//  produces its first qualifying floor, then that one takes over.
//

import ARKit
import Foundation
import QuartzCore
import simd

/// What the anchor actually did this frame, for the window's calibration
/// panel. The floor source says where the real floor is; this says where
/// the GAME floor ended up and how tall you are standing on it. If the two
/// disagree the fault is in the anchor, not the measurement, and that is a
/// distinction no log line on a Mac can make while the headset is on.
enum FloorReadout {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gameFloorAboveReal: Float?
    nonisolated(unsafe) private static var headAboveGameFloor: Float?

    static func publish(gameFloorAboveReal: Float?, headAboveGameFloor: Float?) {
        lock.lock()
        self.gameFloorAboveReal = gameFloorAboveReal
        self.headAboveGameFloor = headAboveGameFloor
        lock.unlock()
    }

    static func read() -> (gameFloorAboveReal: Float?, headAboveGameFloor: Float?) {
        lock.lock(); defer { lock.unlock() }
        return (gameFloorAboveReal, headAboveGameFloor)
    }
}

final class FloorSource: @unchecked Sendable {

    private let lock = NSLock()
    private var session: ARKitSession?
    private var provider: PlaneDetectionProvider?
    private var live = false
    private var supervisor: Task<Void, Never>?

    /// One live floor-classified horizontal plane: its extent frame in the
    /// tracking origin, so the head's distance to it is measured to the
    /// nearest point of the extent, not its centre, and re-measured as the
    /// head moves.
    private struct Plane {
        var y: Float
        var area: Float
        var extentFromOrigin: simd_float4x4
        var halfWidth: Float
        var halfHeight: Float
    }
    /// Live floor planes from the current provider, by anchor id.
    private var planes: [UUID: Plane] = [:]
    /// Live vertical planes from the current provider, by anchor id, with
    /// their normals in the RAW tracking frame. Raw because the recenter
    /// correction they have to be expressed through changes whenever the
    /// player recentres, and a wall anchor can sit untouched for minutes:
    /// a direction baked at detection time would go stale with nothing to
    /// invalidate it. See FloorMath.wallDirections.
    private var walls: [UUID: FloorMath.WallPlane] = [:]
    /// What was last handed to the engine, so the log line fires on a
    /// change rather than twice a second forever.
    private var publishedWalls = 0
    private var wallsPublishedAt = 0.0
    /// The correction the published table was expressed through. A recenter
    /// changes it, and every published direction is wrong by the recenter's
    /// yaw until the table is rebuilt -- so a change republishes at once
    /// rather than waiting out the interval. The window puts Recenter and
    /// "Align now" next to each other, which is all it takes to land inside
    /// a quarter of a second.
    private var wallsCorrection = matrix_identity_float4x4
    /// How often the table is rebuilt and re-published. The correction
    /// changes only on a recenter and the walls change only as the room is
    /// scanned, so this is a staleness bound, not a sample rate -- and
    /// alignment only reads it on a melt, which no player reaches inside a
    /// quarter of a second of recentring.
    private static let wallPublishInterval = 0.25
    /// The height chosen within the current provider's life; nil until its
    /// first qualifying plane.
    private var selected: Float?
    /// What `floorYRaw()` returns: the last height any provider chose. It
    /// outlives a rebuild so the world does not jump while the new provider
    /// finds its feet.
    private var published: Float?
    /// The head's latest position in the raw tracking frame, for the
    /// distance and clearance rules, and where it was when the selection
    /// last ran, so a head that has moved a step re-ranks the planes.
    private var head = SIMD3<Float>(0, 1.6, 0)
    private var headAtSelection = SIMD3<Float>(0, 1.6, 0)
    private static let reselectAfter: Float = 0.5

    private static let retryDelay = Duration.milliseconds(250)
    private static let maxBackoff = 8
    private static let stableGrace = 2.0
    private static let pollInterval = Duration.milliseconds(100)
    private static let pausedGrace = 1.5

    /// One source at a time, like the device anchors: claiming stands the
    /// previous one down first.
    private static let registry = NSLock()
    nonisolated(unsafe) private static weak var current: FloorSource?

    deinit {
        stop()
    }

    /// Ask for world sensing once, from the window, before the player ever
    /// opens the immersive space. The system prompt has to be answerable
    /// when it is raised, and a prompt raised from inside a fully immersive
    /// space is not: the first build of this feature asked implicitly on
    /// the first `run` and simply hung there, looking like a dead feature.
    /// Safe to call repeatedly; once answered the system does not re-ask.
    static func prewarmAuthorization() async {
        guard PlaneDetectionProvider.isSupported else { return }
        let needed = PlaneDetectionProvider.requiredAuthorizations
        let granted = await ARKitSession().requestAuthorization(for: needed)
        for type in needed {
            print("[floor] world sensing \(granted[type].map(String.init(describing:)) ?? "unknown")")
        }
    }

    func start() {
        guard PlaneDetectionProvider.isSupported else {
            print("[floor] plane detection unsupported here -- eye-locked mapping stays")
            return
        }
        print("[floor] starting plane detection")

        Self.registry.lock()
        let previous = Self.current
        Self.current = self
        Self.registry.unlock()
        if previous !== self { previous?.stop() }

        lock.lock()
        guard !live else { lock.unlock(); return }
        live = true
        lock.unlock()

        let task = Task.detached(priority: .utility) { [weak self] () -> Void in
            await self?.supervise()
        }
        lock.lock()
        if live { supervisor = task } else { task.cancel() }
        lock.unlock()
    }

    func stop() {
        Self.registry.lock()
        if Self.current === self { Self.current = nil }
        Self.registry.unlock()

        lock.lock()
        guard live else { lock.unlock(); return }
        live = false
        let dying = session
        let task = supervisor
        session = nil
        provider = nil
        supervisor = nil
        // Dropped here as well as cleared engine-side below, because a
        // drain task cancelled a moment ago can still have an ingest in
        // flight, and a render frame can still call publishWalls -- either
        // would put the stale table straight back.
        walls = [:]
        lock.unlock()

        task?.cancel()
        dying?.stop()
        // The engine keeps whatever it was last told, and a table published
        // under a correction from a session that has ended points somewhere
        // the room no longer is -- a melt from the flat window would turn to
        // it. Nothing to align to is the honest state here.
        QC_SetRoomWalls(nil, 0)
        print("[floor] plane detection stood down")
    }

    /// The measured floor height in the raw tracking frame, or nil when no
    /// provider has found one yet. Any thread.
    func floorYRaw() -> Float? {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    /// Hand the engine the room's wall directions, expressed through the
    /// recenter correction in force right now. Called from the render loop
    /// every frame and rate-limited inside, because the engine's copy is a
    /// whole-table replacement under a lock and the alignment that reads it
    /// fires at most once per melt.
    ///
    /// The correction's ROTATION is what matters here, not its translation:
    /// a direction has no position. It is taken from the caller rather than
    /// from TrackingSpace so the walls are expressed through the same
    /// correction the camera used this frame.
    func publishWalls(correction: simd_float4x4) {
        let now = CACurrentMediaTime()
        lock.lock()
        // Nothing to publish once this source is down; stop() has already
        // told the engine there are no walls and must stay the last word.
        guard live else { lock.unlock(); return }
        let moved = wallsCorrection != correction
        guard moved || now - wallsPublishedAt >= Self.wallPublishInterval else {
            lock.unlock()
            return
        }
        wallsPublishedAt = now
        wallsCorrection = correction
        let detected = Array(walls.values)
        let was = publishedWalls
        lock.unlock()

        let rotation = simd_float3x3(
            SIMD3(correction.columns.0.x, correction.columns.0.y, correction.columns.0.z),
            SIMD3(correction.columns.1.x, correction.columns.1.y, correction.columns.1.z),
            SIMD3(correction.columns.2.x, correction.columns.2.y, correction.columns.2.z))
        let dirs = FloorMath.wallDirections(detected, rotation: rotation,
                                            limit: Int(QC_MAX_WALL_DIRS))

        var table = [qc_wall_dir_t](repeating: qc_wall_dir_t(degrees: 0, weight: 0),
                                    count: max(dirs.count, 1))
        for (i, d) in dirs.enumerated() {
            table[i] = qc_wall_dir_t(degrees: d.degrees, weight: d.weight)
        }
        table.withUnsafeBufferPointer { QC_SetRoomWalls($0.baseAddress, Int32(dirs.count)) }

        guard dirs.count != was else { return }
        lock.lock()
        publishedWalls = dirs.count
        lock.unlock()
        // Counts only. The direction a wall faces and how big it is are a
        // scan of somebody's home, and this log is persisted to a file in
        // the app container that tools/pull-console.sh copies to a Mac. The
        // engine prints the shape on demand behind vr_align_debug, which is
        // where a number that specific belongs.
        print("[walls] \(dirs.count) usable of \(detected.count) vertical plane(s)")
    }

    /// Throw away the chosen floor and pick again from the planes that are
    /// live right now. For a posture change: stand up after playing seated
    /// and the plane under you may be the sofa, not the carpet. The last
    /// height stays published until a new one is chosen, so the world does
    /// not fall back to the eye-locked mapping in between.
    func remeasure() {
        lock.lock()
        selected = nil
        // Re-rank HERE rather than leaving it to the next head report. A
        // settled room produces no anchor updates, and reselectLocked
        // rewrites headAtSelection on every call, so in a room that is
        // still being scanned the moved-head trigger never fires either:
        // between them the button could look dead for as long as the
        // player stood still.
        let count = planes.count
        let message = reselectLocked()
        lock.unlock()
        print("[floor] re-measuring from \(count) live plane(s)")
        if let message { print(message) }
    }

    /// The head's height above the measured floor, in metres, or nil when
    /// nothing has been measured. This is the window's PROOF of the
    /// measurement, and the reason it is a height rather than the floor's
    /// own number: the raw height is in a tracking frame that means
    /// nothing to a player, but everyone knows roughly how tall they are.
    /// Standing, this should read close to your own height. Far off and
    /// plane detection has found a table or a bed, not the carpet.
    static func headAboveFloor() -> Float? {
        registry.lock()
        let source = current
        registry.unlock()
        guard let source else { return nil }
        source.lock.lock(); defer { source.lock.unlock() }
        guard let floor = source.published else { return nil }
        return source.head.y - floor
    }

    /// The raw numbers behind the choice, for the calibration panel. A
    /// derived height can look wrong for two completely different reasons
    /// -- the wrong surface was picked, or the tracking origin is not where
    /// it is assumed to be -- and only the raw values tell them apart.
    /// `lowest` is the lowest plane that qualified, so a pick that is not
    /// the lowest is visible at a glance.
    static func rawReadout() -> (headY: Float, floorY: Float?, lowest: Float?, planes: Int)? {
        registry.lock()
        let source = current
        registry.unlock()
        guard let source else { return nil }
        source.lock.lock(); defer { source.lock.unlock() }
        let lowest = source.planes.values.map(\.y).min()
        return (source.head.y, source.published, lowest, source.planes.count)
    }

    /// The running source, for the window's Re-measure button.
    static func remeasureCurrent() {
        registry.lock()
        let source = current
        registry.unlock()
        if let source {
            source.remeasure()
        } else {
            print("[floor] re-measure asked for with no plane detection running")
        }
    }

    /// The head's raw tracking-frame position, once per frame from the
    /// render thread, so planes can be ranked by distance and clearance.
    func noteHead(_ position: SIMD3<Float>) {
        lock.lock()
        head = position
        let moved = simd_length(position - headAtSelection) > Self.reselectAfter
        let message = moved ? reselectLocked() : nil
        lock.unlock()
        if let message { print(message) }
    }

    private var isLive: Bool {
        lock.lock(); defer { lock.unlock() }
        return live
    }

    /// Run a provider, drain its planes until ARKit stops it, then build a
    /// replacement -- for as long as this source is live. A refused
    /// permission ends the loop: it will not change until a relaunch.
    private func supervise() async {
        var backoff = 0
        var rebuild = false
        while isLive, !Task.isCancelled {
            let session = ARKitSession()
            // Vertical planes as well as horizontal: the floor is one
            // number off the horizontal ones, and room alignment reads the
            // direction the vertical ones face. One provider, because a
            // second one would be a second permission prompt for a
            // permission the player has already given.
            let provider = PlaneDetectionProvider(alignments: [.horizontal, .vertical])

            // Ask for world sensing EXPLICITLY, before running. Letting
            // `run` prompt implicitly parks this task inside the await for
            // as long as the prompt goes unanswered, and the prompt is not
            // answerable if it is raised while the player is already inside
            // the immersive space -- which looked exactly like the feature
            // doing nothing at all: no provider, no error, no log line.
            // Asked for here, the status is known and printed either way.
            let needed = PlaneDetectionProvider.requiredAuthorizations
            let granted = await session.requestAuthorization(for: needed)
            let refused = needed.filter { granted[$0] != .allowed }
            if !refused.isEmpty {
                print("[floor] not authorized (\(refused.map(String.init(describing:)).joined(separator: ", "))) -- eye-locked mapping stays")
                return
            }
            print("[floor] world sensing authorized")

            do {
                try await session.run([provider])
            } catch let error as ARKitSession.Error where error.code == .dataProviderNotAuthorized {
                print("[floor] permission denied -- eye-locked mapping stays")
                return
            } catch {
                print("[floor] plane detection failed to run: \(error)")
                backoff = min(backoff + 1, Self.maxBackoff)
                try? await Task.sleep(for: Self.retryDelay * backoff)
                continue
            }

            if rebuild {
                print("[floor] rebuilt -- waiting for a fresh floor")
            }

            guard adopt(session: session, provider: provider) else {
                session.stop()
                return
            }
            let ranAt = CACurrentMediaTime()
            print("[floor] plane detection running")

            let errors = Task.detached(priority: .utility) { () -> Void in
                for await event in session.events {
                    guard case let .dataProviderStateChanged(_, newState, error) = event,
                          let error else { continue }
                    print("[floor] plane detection \(newState): \(error)")
                }
            }
            let drain = Task.detached(priority: .utility) { [weak self] () -> Void in
                for await update in provider.anchorUpdates {
                    self?.ingest(update)
                }
            }
            let reason = await watch(provider)
            errors.cancel()
            drain.cancel()

            guard isLive, !Task.isCancelled else { break }
            print("[floor] plane detection \(reason) -- rebuilding provider")
            backoff = CACurrentMediaTime() - ranAt >= Self.stableGrace
                ? 0 : min(backoff + 1, Self.maxBackoff)
            rebuild = true
            retire(session)
            try? await Task.sleep(for: Self.retryDelay * max(1, backoff))
        }
    }

    /// Fold one anchor update into the selection. Only horizontal planes
    /// the system calls floor count; everything else is dropped on sight.
    /// The log line is built under the lock and printed outside it: the
    /// render thread takes this lock twice a frame.
    private func ingest(_ update: AnchorUpdate<PlaneAnchor>) {
        let anchor = update.anchor
        lock.lock()
        switch update.event {
        case .removed:
            planes.removeValue(forKey: anchor.id)
            walls.removeValue(forKey: anchor.id)
        case .added, .updated:
            if anchor.alignment == .vertical {
                let extent = anchor.geometry.extent
                // Y of a plane anchor's own frame is its normal; x and z
                // span the plane, which is why extentDistance treats those
                // two as in-plane for the floor.
                let n = anchor.originFromAnchorTransform.columns.1
                walls[anchor.id] = FloorMath.WallPlane(
                    normal: SIMD3(n.x, n.y, n.z),
                    area: extent.width * extent.height)
                planes.removeValue(forKey: anchor.id)
                break
            }
            walls.removeValue(forKey: anchor.id)
            guard anchor.alignment == .horizontal,
                  anchor.surfaceClassification == .floor else {
                planes.removeValue(forKey: anchor.id)
                break
            }
            let extent = anchor.geometry.extent
            let originFromExtent = anchor.originFromAnchorTransform * extent.anchorFromExtentTransform
            planes[anchor.id] = Plane(
                y: originFromExtent.columns.3.y,
                area: extent.width * extent.height,
                extentFromOrigin: originFromExtent.inverse,
                halfWidth: extent.width * 0.5,
                halfHeight: extent.height * 0.5)
        @unknown default:
            break
        }
        let message = reselectLocked()
        lock.unlock()
        if let message { print(message) }
    }

    /// Re-rank the live planes against the current head. Caller holds the
    /// lock. Returns the line to log once the lock is released, if the
    /// chosen height changed.
    private func reselectLocked() -> String? {
        headAtSelection = head
        let candidates = planes.values.map { plane -> FloorMath.FloorCandidate in
            let local = plane.extentFromOrigin * SIMD4(head, 1)
            return FloorMath.FloorCandidate(
                y: plane.y,
                area: plane.area,
                horizontalDistance: FloorMath.extentDistance(
                    headInExtent: SIMD3(local.x, local.y, local.z),
                    halfWidth: plane.halfWidth, halfHeight: plane.halfHeight))
        }
        let before = selected
        selected = FloorMath.select(candidates, current: selected, headY: head.y)
        guard let chosen = selected, chosen != before else { return nil }
        published = chosen
        let area = planes.values.min(by: { abs($0.y - chosen) < abs($1.y - chosen) })?.area ?? 0
        return String(format: "[floor] floor at %.3f m, area %.2f m²", chosen, area)
    }

    private func watch(_ provider: PlaneDetectionProvider) async -> String {
        var last = provider.state
        var pausedSince: Double?
        while isLive, !Task.isCancelled {
            let state = provider.state
            if state != last {
                print("[floor] plane detection \(state)")
                last = state
            }
            switch state {
            case .stopped:
                return "stopped"
            case .paused:
                let now = CACurrentMediaTime()
                guard let since = pausedSince else { pausedSince = now; break }
                if now - since >= Self.pausedGrace { return "paused too long" }
            default:
                pausedSince = nil
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return "stood down"
    }

    private func adopt(session: ARKitSession, provider: PlaneDetectionProvider) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard live else { return false }
        self.session?.stop()
        self.session = session
        self.provider = provider
        // A new provider's planes live in its own frame: start the
        // selection over, keep the last published height until it lands.
        // The walls go with them -- a stale wall in a new frame points
        // somewhere arbitrary, and alignment would act on it.
        planes = [:]
        walls = [:]
        selected = nil
        return true
    }

    private func retire(_ dead: ARKitSession) {
        lock.lock()
        if session === dead {
            session = nil
            provider = nil
        }
        lock.unlock()
        dead.stop()
    }
}

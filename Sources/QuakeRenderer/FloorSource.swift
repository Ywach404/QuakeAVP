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
        lock.unlock()

        task?.cancel()
        dying?.stop()
        print("[floor] plane detection stood down")
    }

    /// The measured floor height in the raw tracking frame, or nil when no
    /// provider has found one yet. Any thread.
    func floorYRaw() -> Float? {
        lock.lock(); defer { lock.unlock() }
        return published
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
            let provider = PlaneDetectionProvider(alignments: [.horizontal])

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
        case .added, .updated:
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
        planes = [:]
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

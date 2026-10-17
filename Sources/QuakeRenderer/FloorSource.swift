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

    /// Live floor-classified horizontal planes from the current provider,
    /// by anchor id, reduced to what the selection reads.
    private var planes: [UUID: FloorMath.FloorCandidate] = [:]
    /// The height chosen within the current provider's life; nil until its
    /// first qualifying plane.
    private var selected: Float?
    /// What `floorYRaw()` returns: the last height any provider chose. It
    /// outlives a rebuild so the world does not jump while the new provider
    /// finds its feet.
    private var published: Float?
    /// The head's latest horizontal position and height in the raw
    /// tracking frame, for the distance and clearance rules.
    private var headXZ = SIMD2<Float>(0, 0)
    private var headY: Float = 1.6

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

    func start() {
        guard PlaneDetectionProvider.isSupported else {
            print("[floor] plane detection unsupported here -- eye-locked mapping stays")
            return
        }

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
        headXZ = SIMD2(position.x, position.z)
        headY = position.y
        lock.unlock()
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
    private func ingest(_ update: AnchorUpdate<PlaneAnchor>) {
        let anchor = update.anchor
        lock.lock(); defer { lock.unlock() }
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
            let world = anchor.originFromAnchorTransform * extent.anchorFromExtentTransform
            let centre = world.columns.3
            planes[anchor.id] = FloorMath.FloorCandidate(
                y: centre.y,
                area: extent.width * extent.height,
                horizontalDistance: simd_length(SIMD2(centre.x, centre.z) - headXZ))
        @unknown default:
            break
        }
        let before = selected
        selected = FloorMath.select(Array(planes.values), current: selected, headY: headY)
        if let chosen = selected, chosen != before {
            published = chosen
            let area = planes.values.min(by: { abs($0.y - chosen) < abs($1.y - chosen) })?.area ?? 0
            print(String(format: "[floor] floor at %.3f m, area %.2f m²", chosen, area))
        }
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

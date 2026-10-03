//
//  GamePause.swift
//
//  Stops the world while you are using the console: freezes the simulation and
//  drops every input source, so summoning the window mid-fight does not leave
//  a shambler eating you while you read a slider.
//
//  Entering is a gesture (the summon sign); LEAVING is deliberately an explicit
//  button. visionOS does not reliably tell an app its window closed --
//  .onDisappear simply does not fire -- which is the same hole that made the
//  old ConsolePresence counter suppress every summon after the first. So there
//  is no signal to auto-resume on, and inventing one would mean guessing.
//
//  Gaze cannot drive this either: visionOS renders hover highlights out of
//  process precisely so apps are never told where you are looking. The buttons
//  light up, and the app hears nothing until you pinch.
//

import Foundation

@MainActor
@Observable
final class GamePause {

    static let shared = GamePause()

    private(set) var isPaused = false

    /// Set by the window. An export drives the engine through its own stepping,
    /// so freezing the sim underneath it would corrupt the output.
    @ObservationIgnored var isExporting: () -> Bool = { false }

    private init() {}

    func set(_ paused: Bool) {
        guard isPaused != paused else { return }
        if paused && isExporting() { return }
        isPaused = paused
        // Sim first, then input: pausing, stop the world before dropping the
        // controls; resuming, this order means input is restored last, so a
        // button still held from before the pause cannot act on a frozen world.
        QC_SetPaused(paused ? 1 : 0)
        InputHost.shared.gamepad.aggregator.suppressed = paused
    }
}

//
//  ConsoleWindowState.swift
//
//  Whether the console/settings window is currently up. Written by the window's
//  SwiftUI lifecycle on the main actor; read on the hand-input thread, which is
//  why it is a lock-protected singleton (the OffHandWrist/GunHand idiom) rather
//  than a @MainActor @Observable the input task cannot touch synchronously.
//
//  visionOS caveat: a `Window`'s onDisappear does not fire when the user closes
//  it, so "open" is driven from ContentView's onAppear plus scenePhase -- open
//  when the window is active, closed when it backgrounds. Best-effort, which is
//  all the turn-suppression it gates needs: turning is swallowed while you are
//  actually looking at and using the console.
//

import Foundation

final class ConsoleWindowState: @unchecked Sendable {
    static let shared = ConsoleWindowState()

    private let lock = NSLock()
    private var _isOpen = false

    var isOpen: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isOpen }
        set { lock.lock(); _isOpen = newValue; lock.unlock() }
    }
}

//
//  ConsoleWindowState.swift
//
//  Whether the console/settings window is currently up. Written by the window's
//  SwiftUI view lifetime on the main actor; read on the hand-input thread,
//  which is why it is a lock-protected singleton (the OffHandWrist/GunHand
//  idiom) rather than a @MainActor @Observable the input task cannot touch
//  synchronously.
//
//  Driven by a `.task` on ContentView, NOT scenePhase: scenePhase reports the
//  window .inactive while the immersive space has focus (so it never read as
//  "open" during play), and observing it re-rendered the whole panel and ate
//  the tab picker's pinches. A `.task`'s cancellation fires reliably when the
//  window is torn down (close), which a Window's onDisappear does not on
//  visionOS -- so view lifetime is the honest "is the console up" signal.
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

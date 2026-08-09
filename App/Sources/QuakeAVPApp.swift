//
//  QuakeAVPApp.swift
//
//  M0 is a plain WindowGroup. The ImmersiveSpace(.full) that hosts the
//  CompositorServices LayerRenderer arrives at M3; this window survives as the
//  launcher and settings surface.
//

import SwiftUI

@main
struct QuakeAVPApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 900, height: 640)
    }
}

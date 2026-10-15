// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  QuakeRenderView.swift
//
//  SwiftUI wrapper for the flat window's Metal world view. MTKView drives
//  WorldRenderer at display rate on its own; the engine publishes frame
//  packets at its own cadence and the newest one wins, so neither side
//  waits on the other.
//
//  While the immersive space is open the view is paused: the compositor
//  thread owns the packet stream (see RendererCoordinator), and drawing a
//  stale frame here would waste the window's display link for nothing.
//

import SwiftUI
import MetalKit

struct QuakeRenderView: UIViewRepresentable {

    var paused: Bool = false

    func makeUIView(context: Context) -> MTKView {
        let coordinator = RendererCoordinator.shared
        let view = MTKView(frame: .zero, device: coordinator.core?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.clearDepth = 1.0
        view.preferredFramesPerSecond = 60
        view.delegate = coordinator.windowRenderer
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.isPaused = paused
    }
}

//
//  QuakeRenderView.swift
//
//  SwiftUI wrapper for the Metal world view. MTKView drives WorldRenderer at
//  display rate on its own; the engine publishes frame packets at its own
//  cadence and the newest one wins, so neither side waits on the other.
//

import SwiftUI
import MetalKit

struct QuakeRenderView: UIViewRepresentable {

    func makeCoordinator() -> WorldRenderer? {
        WorldRenderer(colorPixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.clearDepth = 1.0
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
    }
}

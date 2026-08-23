//
//  QuakeAVPApp.swift
//
//  Two scenes: the flat window (launcher, console, debug view of the same
//  frame packets) and the full immersive space that renders the world in
//  stereo through CompositorServices. RendererCoordinator arbitrates which
//  of the two consumes the engine's packets; the engine thread itself
//  neither knows nor cares which scene is up.
//

import SwiftUI
import CompositorServices

@main
struct QuakeAVPApp: App {

    static let immersiveSpaceID = "quake-immersive"

    static let consoleWindowID = "quake-console"

    var body: some Scene {
        WindowGroup(id: Self.consoleWindowID) {
            ContentView()
                // One fixed size that fits every control and the log; the
                // console is a debug surface, not a resizable document, and
                // a drifting window makes its buttons hard to hit in space.
                .frame(width: 940, height: 720)
        }
        .defaultSize(width: 940, height: 720)
        .windowResizability(.contentSize)

        ImmersiveSpace(id: Self.immersiveSpaceID) {
            CompositorLayer(configuration: QuakeLayerConfiguration()) { layerRenderer in
                RendererCoordinator.shared.startImmersive(layerRenderer)
            }
        }
        // Mixed the whole time: switching styles at runtime tears down and
        // rebuilds the CompositorServices layer. At phase 0 the world draws
        // opaque and covers the room, indistinguishable from .full.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

/// Layer configuration: layered layout when available (single-pass stereo via
/// vertex amplification), foveation enabled untuned, and otherwise the
/// defaults — the renderer reads the resulting configuration back rather
/// than assuming, so a simulator that only offers dedicated still works.
struct QuakeLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float

        // Prefer the sRGB unorm format: the renderer's immersive pipelines
        // linearize their output so the sRGB store re-encodes Quake's
        // authored palette byte-identically (the rgba16Float default would
        // read it as linear and wash it out; a plain-unorm texture view is
        // not an option — the compositor rejects pixelFormatView usage).
        if capabilities.supportedColorFormats(options: []).contains(.bgra8Unorm_srgb) {
            configuration.colorFormat = .bgra8Unorm_srgb
        }

        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions =
            capabilities.supportsFoveation ? .foveationEnabled : []
        if capabilities.supportedLayouts(options: options).contains(.layered) {
            configuration.layout = .layered
        }
        configuration.isFoveationEnabled = capabilities.supportsFoveation
    }
}

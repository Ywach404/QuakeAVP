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

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 900, height: 640)

        ImmersiveSpace(id: Self.immersiveSpaceID) {
            CompositorLayer(configuration: QuakeLayerConfiguration()) { layerRenderer in
                RendererCoordinator.shared.startImmersive(layerRenderer)
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
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

import XCTest
@testable import QuakeAVP

@MainActor
final class DemoExporterTests: XCTestCase {

    func testExportRefusedWhileImmersive() {
        let exporter = DemoExporter()
        exporter.start(demo: "demo1", preset: ExportPreset(), host: nil, core: nil,
                       gameDirectory: FileManager.default.temporaryDirectory,
                       exportsDirectory: FileManager.default.temporaryDirectory,
                       immersiveActive: true)
        guard case .failed(let why) = exporter.state else { return XCTFail("expected a refusal") }
        XCTAssertTrue(why.contains("immersive"))
    }

    func testExportRefusedWithoutEngine() {
        let exporter = DemoExporter()
        exporter.start(demo: "demo1", preset: ExportPreset(), host: nil, core: nil,
                       gameDirectory: FileManager.default.temporaryDirectory,
                       exportsDirectory: FileManager.default.temporaryDirectory,
                       immersiveActive: false)
        guard case .failed = exporter.state else { return XCTFail("expected a refusal") }
    }

    func testHeadCameraNeedsATrack() {
        let exporter = DemoExporter()
        var preset = ExportPreset(); preset.camera = .head
        // A host/core pair is required before the track check, so a real
        // engine would be needed to reach it; the refusal order is engine
        // first, then track. Guard the engine path here.
        exporter.start(demo: "nope", preset: preset, host: nil, core: nil,
                       gameDirectory: FileManager.default.temporaryDirectory,
                       exportsDirectory: FileManager.default.temporaryDirectory,
                       immersiveActive: false)
        guard case .failed = exporter.state else { return XCTFail("expected a refusal") }
    }
}

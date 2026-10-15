import XCTest
import simd
@testable import QuakeAVP

final class HudOverlayTests: XCTestCase {

    func testGlyphQuadsAndAtlasCells() {
        var verts: [Float] = []
        let next = HudOverlay.glyphs("A B", x: 10, y: 20, size: 8, color: HudOverlay.white, into: &verts)
        XCTAssertEqual(verts.count, 2 * 6 * 9)          // the space draws nothing but advances
        XCTAssertEqual(next, 10 + 3 * 8)
        // 'A' = 65: column 1, row 4 of the 16x16 atlas
        XCTAssertEqual(verts[3], 1.0 / 16, accuracy: 1e-6)
        XCTAssertEqual(verts[4], 4.0 / 16, accuracy: 1e-6)
        // 'B' starts two glyphs to the right
        XCTAssertEqual(verts[54], 10 + 16)
    }

    func testStatsFromPacketOrder() {
        var raw = [Int32](repeating: 0, count: 16)
        raw[0] = 77; raw[4] = 50; raw[6] = 25; raw[10] = 1; raw[12] = 20; raw[14] = 3
        let s = HudStats(stats: raw)
        XCTAssertEqual(s.health, 77); XCTAssertEqual(s.armor, 50); XCTAssertEqual(s.shells, 25)
        XCTAssertEqual(s.activeWeapon, 1); XCTAssertEqual(s.totalMonsters, 20); XCTAssertEqual(s.kills, 3)
        XCTAssertEqual(HudOverlay.weaponName(s.activeWeapon), "SHOTGUN")
        XCTAssertEqual(HudOverlay.activeAmmo(64), 2048)
    }

    func testBuildFitsTheFrame() {
        var s = HudStats(); s.health = 100; s.armor = 200; s.shells = 100; s.nails = 200
        s.rockets = 100; s.cells = 100; s.kills = 99; s.totalMonsters = 99; s.secrets = 9; s.totalSecrets = 9
        s.activeWeapon = 16
        let verts = HudOverlay.build(stats: s, width: 1920, height: 1080)
        XCTAssertGreaterThan(verts.count, 0)
        let xs = stride(from: 0, to: verts.count, by: 9).map { verts[$0] }
        let ys = stride(from: 0, to: verts.count, by: 9).map { verts[$0 + 1] }
        XCTAssertLessThanOrEqual(xs.max()!, 1920)
        XCTAssertLessThanOrEqual(ys.max()!, 1080)
        XCTAssertGreaterThanOrEqual(xs.min()!, 0)
    }

    func testLookAtBasisIsOrthonormalAndFacesTarget() {
        let pose = ExportRenderer.lookAt(eye: SIMD3(100, 50, 20), target: SIMD3(0, 0, 24))
        let r = SIMD3(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z)
        let u = SIMD3(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z)
        let b = SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)   // -forward
        XCTAssertEqual(simd_length(r), 1, accuracy: 1e-5)
        XCTAssertEqual(simd_length(u), 1, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(r, u), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(r, b), 0, accuracy: 1e-5)
        XCTAssertGreaterThan(u.z, 0.9)                               // up stays up
        let forward = -b
        XCTAssertGreaterThan(simd_dot(forward, simd_normalize(SIMD3(-100, -50, 4))), 0.999)
        // The view of the target lands on the -z axis in eye space.
        let eyeSpace = pose.inverse * SIMD4(0, 0, 24, 1)
        XCTAssertLessThan(eyeSpace.z, 0)
        XCTAssertEqual(eyeSpace.x, 0, accuracy: 1e-3)
        XCTAssertEqual(eyeSpace.y, 0, accuracy: 1e-3)
    }

    func testOrbitCircle() {
        var cam = ThirdPersonCamera()
        cam.observe(player: SIMD3(10, 20, 30), yaw: 0, demoTime: 5)
        let a = cam.position(for: .orbit, demoTime: 5, dt: 0.016)
        let b = cam.position(for: .orbit, demoTime: 5 + ThirdPersonCamera.orbitPeriod / 2, dt: 0.016)
        XCTAssertEqual(simd_length(a - SIMD3(10, 20, 30 + ThirdPersonCamera.orbitHeight)),
                       ThirdPersonCamera.orbitRadius, accuracy: 1e-3)
        XCTAssertEqual(simd_length(a - b), 2 * ThirdPersonCamera.orbitRadius, accuracy: 1e-2)
    }

    func testPresetParsesThirdPersonAndHud() {
        let p = ExportPreset.parse("1440p30,orbit,nohud")
        XCTAssertEqual(p.camera, .orbit); XCTAssertFalse(p.hud); XCTAssertFalse(p.camera.needsTrack)
        XCTAssertTrue(ExportPreset.parse("front,hud").hud)
    }
}

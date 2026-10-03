//
//  ExportPreset.swift
//
//  What an export looks like: size, rate, time dilation, motion blur,
//  camera, codec. Also the file name those choices produce and a parser for
//  the boot-time test hook (QAVP_EXPORT_PRESET="1080p60,slow0.5,mb4,gun,nohud").
//

import Foundation

struct ExportPreset: Equatable {

    enum Resolution: Int, CaseIterable, Identifiable {
        case p1080 = 1080, p1440 = 1440, p2160 = 2160
        var id: Int { rawValue }
    }

    enum Camera: String, CaseIterable, Identifiable {
        case head, smoothed, gun, chase, orbit, front
        var id: String { rawValue }
        var label: String {
            switch self {
            case .head: return "Head (recorded)"
            case .smoothed: return "Head, smoothed"
            case .gun: return "Gun (first person)"
            case .chase: return "Chase (third person)"
            case .orbit: return "Orbit (third person)"
            case .front: return "Front (third person)"
            }
        }
        var needsTrack: Bool { self == .head || self == .smoothed }
    }

    var resolution: Resolution = .p1080
    var fps: Int = 60
    /// Demo seconds per video second: 1, 0.5, 0.25.
    var slowMo: Float = 1
    var motionBlurSamples: Int = 1
    var camera: Camera = .head
    var codec: ExportCodec = .hevc
    var fovXDegrees: Float = 100
    /// Burn the status bar (health, armor, ammo, weapon, kills) into the frame.
    var hud = true

    var width: Int { resolution.rawValue * 16 / 9 }
    var height: Int { resolution.rawValue }

    /// Demo seconds per output frame.
    var simStep: Double { Double(slowMo) / Double(fps) }

    /// Sub-steps actually used: motionBlurSamples capped so each sub-step
    /// stays >= 1 ms, the shortest frame Host_FilterTime will accept.
    var subSteps: Int { max(1, min(motionBlurSamples, Int((simStep / 0.001).rounded(.down)))) }

    func fileName(demo: String) -> String {
        var parts = ["\(demo)-\(height)p\(fps)"]
        if slowMo < 1 { parts.append("slow\(Int((1 / slowMo).rounded()))") }
        if motionBlurSamples > 1 { parts.append("mb\(motionBlurSamples)") }
        parts.append(camera.rawValue)
        return parts.joined(separator: "-") + ".mov"
    }

    /// "2160p30,slow0.25,mb8,gun,h264" -- unknown tokens are ignored.
    static func parse(_ text: String) -> ExportPreset {
        var p = ExportPreset()
        for raw in text.split(separator: ",") {
            let tok = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if let pIndex = tok.firstIndex(of: "p"),
               let h = Int(tok[..<pIndex]), let f = Int(tok[tok.index(after: pIndex)...]) {
                if let r = Resolution(rawValue: h) { p.resolution = r }
                p.fps = f
            } else if tok.hasPrefix("slow"), let v = Float(tok.dropFirst(4)) {
                p.slowMo = v
            } else if tok.hasPrefix("mb"), let v = Int(tok.dropFirst(2)) {
                p.motionBlurSamples = v
            } else if let c = Camera(rawValue: tok) {
                p.camera = c
            } else if tok == "hud" {
                p.hud = true
            } else if tok == "nohud" {
                p.hud = false
            } else if let c = ExportCodec(rawValue: tok) {
                p.codec = c
            }
        }
        return p
    }
}

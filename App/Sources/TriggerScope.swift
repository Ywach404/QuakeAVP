// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  TriggerScope.swift
//
//  Live scope over the trigger pipeline, for tuning and for capture:
//  both analog triggers over the last four seconds, the engine's actuation
//  and release thresholds, fire marks, kickback pulses, and the adaptive
//  feel zone the active weapon would program into a Sense trigger.
//
//  Chart discipline (dataviz method): three entities, fixed categorical
//  hues validated against the dark surface — R trigger #3987e5, L trigger
//  #d95926, kickback #199e70 — 2 pt lines, >= 8 pt event markers with
//  distinct shapes, recessive grid, thresholds as neutral dashes, all text
//  in text tokens, a legend because there is more than one series.
//

import SwiftUI
import QuartzCore

struct TriggerScope: View {

    private static let window = 4.0
    private static let rtColor = Color(red: 0x39/255.0, green: 0x87/255.0, blue: 0xE5/255.0)
    private static let ltColor = Color(red: 0xD9/255.0, green: 0x59/255.0, blue: 0x26/255.0)
    private static let kickColor = Color(red: 0x19/255.0, green: 0x9E/255.0, blue: 0x70/255.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Trigger actuation")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                legend
                Spacer()
                Button("Demo") { InputTelemetry.shared.runDemo() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    draw(in: context, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .background(Color(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x19/255.0).opacity(0.85),
                        in: .rect(cornerRadius: 10))
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            chip(Self.rtColor, "R trigger")
            chip(Self.ltColor, "L trigger")
            chip(Self.kickColor, "kickback")
        }
    }

    private func chip(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize, now: Double) {
        let (samples, events, weapon) = InputTelemetry.shared.snapshot()
        let clock = CACurrentMediaTime()
        let inset: CGFloat = 8
        let plot = CGRect(x: inset, y: inset,
                          width: size.width - 2 * inset, height: size.height - 2 * inset)

        func x(_ t: Double) -> CGFloat {
            plot.maxX - plot.width * CGFloat((clock - t) / Self.window)
        }
        func y(_ v: Float) -> CGFloat {
            plot.maxY - plot.height * CGFloat(min(max(v, 0), 1))
        }

        // Adaptive feel zone for the held weapon: a neutral band, labeled.
        if let zone = ControllerOutput.feelZone(weapon: weapon) {
            let rect = CGRect(x: plot.minX, y: y(zone.upperBound),
                              width: plot.width,
                              height: y(zone.lowerBound) - y(zone.upperBound))
            context.fill(Path(rect), with: .color(.white.opacity(0.05)))
            context.draw(
                Text("adaptive zone (armed)").font(.system(size: 8)).foregroundStyle(.tertiary),
                at: CGPoint(x: plot.maxX - 4, y: rect.minY + 7), anchor: .trailing)
        }

        // Recessive grid at 0, ½, 1; thresholds as neutral dashes.
        for v: Float in [0, 0.5, 1] {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(v)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(v)))
            context.stroke(line, with: .color(.white.opacity(0.08)), lineWidth: 1)
        }
        for (v, label) in [(Float(0.35), "press"), (Float(0.20), "release")] {
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y(v)))
            line.addLine(to: CGPoint(x: plot.maxX, y: y(v)))
            context.stroke(line, with: .color(.white.opacity(0.25)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            context.draw(Text(label).font(.system(size: 8)).foregroundStyle(.secondary),
                         at: CGPoint(x: plot.minX + 2, y: y(v) - 6), anchor: .leading)
        }

        // The two series, 2 pt.
        func series(_ value: (InputTelemetry.Sample) -> Float, _ color: Color) {
            guard samples.count > 1 else { return }
            var path = Path()
            path.move(to: CGPoint(x: x(samples[0].t), y: y(value(samples[0]))))
            for sample in samples.dropFirst() {
                path.addLine(to: CGPoint(x: x(sample.t), y: y(value(sample))))
            }
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        series({ $0.lt }, Self.ltColor)
        series({ $0.rt }, Self.rtColor)

        // Events: fire = a tick from the top (the R trigger's entity edge),
        // kickback = a circle sized by intensity. Shapes differ so identity
        // is never color alone.
        for event in events {
            let ex = x(event.t)
            guard ex >= plot.minX else { continue }
            switch event.kind {
            case .fire:
                var tick = Path()
                tick.move(to: CGPoint(x: ex, y: plot.minY))
                tick.addLine(to: CGPoint(x: ex, y: plot.minY + 10))
                context.stroke(tick, with: .color(Self.rtColor), lineWidth: 2)
            case .kickback:
                let r = 4 + 4 * CGFloat(event.intensity)
                let circle = Path(ellipseIn: CGRect(x: ex - r, y: plot.midY - r,
                                                    width: 2 * r, height: 2 * r))
                context.stroke(circle, with: .color(Self.kickColor), lineWidth: 2)
            }
        }
    }
}

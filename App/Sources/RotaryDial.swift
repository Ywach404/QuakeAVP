//
//  RotaryDial.swift
//
//  A reusable JOG WHEEL: a small circular knob that converts angular drag
//  motion into value changes. Built for the wrist communicator's placement
//  rows (A., on device: "having a gyro wheel to go with them would really
//  help with adjustments"), but it knows nothing about the communicator --
//  it is a value, a range and a step, like any other SwiftUI control.
//
//  Pure shapes, no images, so it inherits the window's own material look.
//

import SwiftUI

/// A circular jog wheel over a stepped numeric range.
///
/// DELTA-BASED, which is the whole point and the one thing a reader could
/// get wrong: the value does not follow the absolute angle of the touch,
/// it follows how far that touch has TWISTED since it grabbed. You can
/// take hold of the wheel anywhere on it, and the value you were already
/// on does not jump to wherever your finger happened to land -- which is
/// exactly what a dial tuned to half a centimetre on device must not do.
///
/// One full revolution covers the whole range, so a few degrees of twist
/// is one `step`. That is the ratio that makes this better than the slider
/// it replaced: a 4 cm slider had to resolve 0.5 cm out of 20 cm of travel
/// in about 2 mm of thumb movement, where a revolution of a 50 pt knob
/// gives the same step some 4 mm of arc -- and the twist can keep going
/// round as long as it likes, so the control's size no longer limits its
/// precision.
///
/// The pointer shows the value's ABSOLUTE position in the range (one
/// revolution = the range, so there is no ambiguity about which turn you
/// are on), and the ticks are there to make a small rotation visible --
/// a knob with a pointer and no marks reads as still.
struct RotaryDial: View {

    @Binding var value: Float
    let range: ClosedRange<Float>
    /// The quantum the value snaps to. The wheel's motion is continuous;
    /// only what it commits is stepped.
    let step: Float
    /// Called with every committed (snapped, clamped) change, so a caller
    /// can push the value somewhere live -- `VRSettings`, in the
    /// communicator's case, which the render thread samples per frame.
    var onChange: (Float) -> Void = { _ in }

    /// Knob size in points. ~50 pt is the smallest a visionOS eye+pinch
    /// drag lands on reliably while still leaving a settings row compact.
    var diameter: CGFloat = 50

    /// The drag's grab state. `grabValue` and `turned` are what make the
    /// control delta-based: the value is always recomputed as "where I
    /// grabbed, plus how far I have twisted since", never as a function of
    /// the current finger angle alone.
    @State private var grabValue: Float = 0
    @State private var turned: Double = 0      // radians since the grab
    @State private var lastAngle: Double = 0
    @State private var grabbed = false

    private var span: Float { max(range.upperBound - range.lowerBound, .leastNormalMagnitude) }

    /// Fraction of the range the value sits at, 0...1 -- the pointer's
    /// angle, since one revolution is one range.
    private var fraction: Double {
        Double((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .strokeBorder(.secondary.opacity(grabbed ? 0.85 : 0.35),
                              lineWidth: grabbed ? 2 : 1)
            // Twelve marks, the long one at the range's start, so the
            // pointer passing them reads as rotation rather than as a
            // shape that happens to be at an angle.
            ForEach(0 ..< 12, id: \.self) { i in
                Capsule()
                    .fill(.secondary.opacity(i == 0 ? 0.8 : 0.35))
                    .frame(width: 1.5, height: i == 0 ? diameter * 0.16 : diameter * 0.09)
                    .offset(y: -diameter * 0.38)
                    .rotationEffect(.degrees(Double(i) * 30))
            }
            // The pointer: a spoke from the centre out to the marks.
            Capsule()
                .fill(.primary.opacity(grabbed ? 1 : 0.75))
                .frame(width: 2.5, height: diameter * 0.40)
                .offset(y: -diameter * 0.20)
                .rotationEffect(.degrees(fraction * 360))
            Circle()
                .fill(.primary.opacity(0.6))
                .frame(width: diameter * 0.12, height: diameter * 0.12)
        }
        .frame(width: diameter, height: diameter)
        // The whole disc is the grab target, including the material's
        // transparent middle.
        .contentShape(Circle())
        .gesture(
            // minimumDistance 0: a twist can start as a rotation about the
            // grab point with almost no translation of it, and a gesture
            // that waited for 10 pt of travel would eat the first part of
            // every small adjustment.
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let centre = CGPoint(x: diameter / 2, y: diameter / 2)
                    let angle = atan2(Double(drag.location.y - centre.y),
                                      Double(drag.location.x - centre.x))
                    guard grabbed else {
                        grabbed = true
                        grabValue = value
                        turned = 0
                        lastAngle = angle
                        return
                    }
                    // Unwrap across the atan2 branch cut, so a twist
                    // through the 9 o'clock mark is a small delta and not
                    // a full turn backwards.
                    var delta = angle - lastAngle
                    if delta > .pi { delta -= 2 * .pi }
                    if delta < -.pi { delta += 2 * .pi }
                    lastAngle = angle
                    turned += delta

                    let raw = grabValue + Float(turned / (2 * .pi)) * span
                    let snapped = (raw / step).rounded() * step
                    let clamped = min(max(snapped, range.lowerBound), range.upperBound)
                    // RE-ANCHOR at a limit instead of letting `turned` wind
                    // up past it. Without this, twisting on for another
                    // revolution at the end of the range buys a revolution
                    // of dead travel on the way back -- the dial would
                    // appear stuck in the direction you are now turning.
                    if snapped != clamped {
                        grabValue = clamped
                        turned = 0
                    }
                    guard clamped != value else { return }
                    value = clamped
                    onChange(clamped)
                }
                .onEnded { _ in grabbed = false }
        )
        // The gesture is the control; the shapes are decoration.
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(value) },
                                  set: { value = Float($0); onChange(Float($0)) }),
                   in: Double(range.lowerBound) ... Double(range.upperBound),
                   step: Double(step))
        }
    }
}

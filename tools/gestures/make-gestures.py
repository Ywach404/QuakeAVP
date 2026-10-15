#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# Generates docs/media/gestures/*.svg from one shared hand geometry, so every
# control diagram is the same hand at the same weight and a change to the
# silhouette lands in all of them at once. The SVGs are committed artifacts --
# this script exists to keep them consistent, not to be run at build time.
#
# Diagram ids and the order of the files come from manifest.json; the drawing
# for each id lives in DIAGRAMS below. An id in the manifest with a "diagram"
# and no entry here is an error, and vice versa.
#
#   python3 tools/gestures/make-gestures.py            # write the SVGs
#   python3 tools/gestures/make-gestures.py --sheet X  # also write a contact
#                                                      # sheet to directory X
#
# Conventions, so the files read as one set:
#   - stroke-only line art, no fills, round caps and joins
#   - .ln  silhouette, .hi  the active pinch pair, .arw  motion, .gst  context
#   - colours are classes with a prefers-color-scheme block, so the same file
#     reads on a light and a dark page
#   - the hand is drawn ONCE, as the left hand seen from the back (thumb on the
#     right); the right hand is that path mirrored about the hand's own centre
#   - a pinch curls the fingers between the thumb and its target, so the thumb
#     never has to cross a finger it is not touching

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "docs", "media", "gestures")

# --------------------------------------------------------------------------
# Shared hand geometry. Left hand, back of the hand toward the viewer, fingers
# up, thumb on the right. Everything else in this file is placement.
# --------------------------------------------------------------------------

FW = 6.5                      # half-width of a finger tube
HAND_MID = 67.0               # x the mirror reflects about
WRIST = (67.0, 150.0)         # pivot for rotations

FINGERS = {
    "pinky":  {"cx": 43.0, "base": 88.0, "tip": 58.0},
    "ring":   {"cx": 59.0, "base": 82.0, "tip": 40.0},
    "middle": {"cx": 75.0, "base": 80.0, "tip": 33.0},
    "index":  {"cx": 91.0, "base": 84.0, "tip": 41.0},
}
ORDER = ["pinky", "ring", "middle", "index"]   # little finger side -> thumb side
CURL_DROP = 13.0              # how far short of its base a folded finger stops
THUMB_BASE = (102.4, 110.1)   # on the palm's thumb-side edge
THUMB_OPEN = (131.0, 84.0)    # relaxed, splayed away from the palm
CONTACT_R = 6.5


def f(v):
    return ("%.2f" % v).rstrip("0").rstrip(".")


def pt(p):
    return "%s %s" % (f(p[0]), f(p[1]))


def contact_point(name):
    """Where the thumb tip meets this finger's pad: just outside the tube's
    thumb-side edge, a little below the apex -- the two tips touch on the pads,
    not at the very top of the finger."""
    g = FINGERS[name]
    return (g["cx"] + FW + 0.5, g["tip"] + 3.0)


def valley(a, b):
    return min(FINGERS[a]["base"], FINGERS[b]["base"]) - 10.0


def finger_tip_y(name, curled):
    g = FINGERS[name]
    return g["base"] - CURL_DROP if curled else g["tip"]


def finger_tube(name, curled=False):
    """The one finger as its own open path, for re-stroking in the accent
    colour over the silhouette."""
    g = FINGERS[name]
    top = finger_tip_y(name, curled)
    return "M %s L %s A %s %s 0 0 1 %s L %s" % (
        pt((g["cx"] - FW, g["base"])), pt((g["cx"] - FW, top)),
        f(FW), f(FW), pt((g["cx"] + FW, top)), pt((g["cx"] + FW, g["base"])))


def hand_outline(curled=()):
    """Palm and four fingers as one continuous silhouette."""
    d = ["M %s" % pt((36.5, 148.0)),
         "C %s %s %s" % (pt((30.0, 132.0)), pt((29.5, 106.0)), pt((36.5, 88.0)))]
    for i, name in enumerate(ORDER):
        g = FINGERS[name]
        top = finger_tip_y(name, name in curled)
        d.append("L %s" % pt((g["cx"] - FW, top)))
        d.append("A %s %s 0 0 1 %s" % (f(FW), f(FW), pt((g["cx"] + FW, top))))
        if i + 1 < len(ORDER):
            nxt = ORDER[i + 1]
            vy = valley(name, nxt)
            d.append("L %s" % pt((g["cx"] + FW, vy)))
            d.append("Q %s %s" % (pt(((g["cx"] + FW + FINGERS[nxt]["cx"] - FW) / 2, vy + 5)),
                                  pt((FINGERS[nxt]["cx"] - FW, vy))))
        else:
            d.append("L %s" % pt((g["cx"] + FW, g["base"])))
    d.append("C %s %s %s" % (pt((103.0, 98.0)), pt((104.0, 114.0)), pt((100.0, 126.0))))
    d.append("C %s %s %s" % (pt((96.0, 140.0)), pt((82.0, 150.0)), pt((66.0, 150.0))))
    d.append("C %s %s %s" % (pt((50.0, 150.0)), pt((40.0, 152.0)), pt((36.5, 148.0))))
    d.append("Z")
    return " ".join(d)


def bezier(p0, p1, p2, p3, t):
    u = 1 - t
    return (u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
            u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1])


def split_bezier(p0, p1, p2, p3, t):
    """de Casteljau: the first t of the curve, as its own cubic."""
    def lerp(a, b):
        return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
    a, b, c = lerp(p0, p1), lerp(p1, p2), lerp(p2, p3)
    d, e = lerp(a, b), lerp(b, c)
    return p0, a, d, lerp(d, e)


def thumb(target=None):
    """The thumb as its own stroke. With no target it rests splayed; with one
    it reaches to that finger's contact point and STOPS at the edge of the
    contact circle rather than running through it."""
    p0 = THUMB_BASE
    if target is None:
        return "M %s C %s %s %s" % (pt(p0), pt((117.0, 115.0)), pt((130.0, 102.0)), pt(THUMB_OPEN))
    c = contact_point(target)
    p1 = (p0[0] + 13.0, p0[1] - 11.0)
    p2 = (c[0] + (p0[0] - c[0]) * 0.45 + 6.0, c[1] + 10.0)
    # Trim the tail so the stroke ends on the circle, not at its centre.
    t = 1.0
    while t > 0.05:
        q = bezier(p0, p1, p2, c, t)
        if math.hypot(q[0] - c[0], q[1] - c[1]) >= CONTACT_R:
            break
        t -= 0.01
    q0, q1, q2, q3 = split_bezier(p0, p1, p2, c, t)
    return "M %s C %s %s %s" % (pt(q0), pt(q1), pt(q2), pt(q3))


FOREARM = ('<path class="ln" d="M 44 146 L 44 212"/>'
           '<path class="ln" d="M 90 146 L 90 212"/>')


def hand(pinch=None, right=False, transform="", open_thumb=True, extra=""):
    """One complete hand. `pinch` names the finger the thumb is touching."""
    curled = ()
    if pinch:
        curled = tuple(ORDER[ORDER.index(pinch) + 1:])
    body = ['<path class="ln" d="%s"/>' % hand_outline(curled)]
    if pinch:
        body.append('<path class="hi" d="%s"/>' % finger_tube(pinch))
        body.append('<path class="hi" d="%s"/>' % thumb(pinch))
        c = contact_point(pinch)
        body.append('<circle class="hi" cx="%s" cy="%s" r="%s"/>'
                    % (f(c[0]), f(c[1]), f(CONTACT_R)))
    elif open_thumb:
        body.append('<path class="ln" d="%s"/>' % thumb(None))
    if extra:
        body.append(extra)
    tf = []
    if transform:
        tf.append(transform)
    if right:
        tf.append("translate(%s,0) scale(-1,1)" % f(HAND_MID * 2))
    attr = ' transform="%s"' % " ".join(tf) if tf else ""
    return "<g%s>\n    %s\n  </g>" % (attr, "\n    ".join(body))


# --------------------------------------------------------------------------
# Annotation primitives
# --------------------------------------------------------------------------

def arrow(x1, y1, x2, y2, cls="arw", head=8.0, spread=0.42):
    a = math.atan2(y1 - y2, x1 - x2)
    hx1, hy1 = x2 + head * math.cos(a - spread), y2 + head * math.sin(a - spread)
    hx2, hy2 = x2 + head * math.cos(a + spread), y2 + head * math.sin(a + spread)
    return ('<path class="%s" d="M %s L %s M %s L %s L %s"/>'
            % (cls, pt((x1, y1)), pt((x2, y2)), pt((hx1, hy1)), pt((x2, y2)), pt((hx2, hy2))))


def arc_arrow(cx, cy, r, a0, a1, cls="arw", head=8.0):
    """A circular sweep from a0 to a1 degrees, arrowhead at a1."""
    r0, r1 = math.radians(a0), math.radians(a1)
    p0 = (cx + r * math.cos(r0), cy + r * math.sin(r0))
    p1 = (cx + r * math.cos(r1), cy + r * math.sin(r1))
    large = 1 if abs(a1 - a0) > 180 else 0
    sweep = 1 if a1 > a0 else 0
    tangent = r1 + (math.pi / 2 if a1 > a0 else -math.pi / 2)
    back = tangent + math.pi
    h1 = (p1[0] + head * math.cos(back - 0.42), p1[1] + head * math.sin(back - 0.42))
    h2 = (p1[0] + head * math.cos(back + 0.42), p1[1] + head * math.sin(back + 0.42))
    return ('<path class="%s" d="M %s A %s %s 0 %d %d %s M %s L %s L %s"/>'
            % (cls, pt(p0), f(r), f(r), large, sweep, pt(p1), pt(h1), pt(p1), pt(h2)))


def line(x1, y1, x2, y2, cls="gst"):
    return '<path class="%s" d="M %s L %s"/>' % (cls, pt((x1, y1)), pt((x2, y2)))


def ground(y, x1, x2):
    return line(x1, y, x2, y, "gst")


def rrect(x, y, w, h, r=3.0, cls="gst"):
    return ('<rect class="%s" x="%s" y="%s" width="%s" height="%s" rx="%s"/>'
            % (cls, f(x), f(y), f(w), f(h), f(r)))


def ellipse(cx, cy, rx, ry, cls="gst"):
    return ('<ellipse class="%s" cx="%s" cy="%s" rx="%s" ry="%s"/>'
            % (cls, f(cx), f(cy), f(rx), f(ry)))


STYLE = """  <style>
    .ln  { stroke:#2f353d; stroke-width:4;   fill:none; stroke-linecap:round; stroke-linejoin:round; }
    .hi  { stroke:#d6453a; stroke-width:4.5; fill:none; stroke-linecap:round; stroke-linejoin:round; }
    .arw { stroke:#2f353d; stroke-width:3;   fill:none; stroke-linecap:round; stroke-linejoin:round; opacity:.55; }
    .gst { stroke:#2f353d; stroke-width:3;   fill:none; stroke-linecap:round; stroke-linejoin:round;
           stroke-dasharray:5 5; opacity:.6; }
    @media (prefers-color-scheme: dark) {
      .ln { stroke:#dfe6ee; } .arw { stroke:#dfe6ee; } .gst { stroke:#dfe6ee; } .hi { stroke:#ff6a5c; }
    }
  </style>"""


def svg(w, h, body, title):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d"'
            ' role="img" aria-label="%s">\n%s\n  %s\n</svg>\n'
            % (w, h, w, h, title, STYLE, "\n  ".join(body)))


# --------------------------------------------------------------------------
# The diagrams
#
# Layout rule: nothing crosses the hand. Diagrams whose only annotation is a
# direction put the hand on the left and the motion in a panel on the right,
# so the set reads as one family at thumbnail size.
# --------------------------------------------------------------------------

PW, PH = 216, 180          # canvas for the hand + motion-panel family
HAND_DROP = "translate(0,14)"
PANEL_X = 172.0            # centre of the motion panel
GROUND_Y = 168.0


def panel_ground():
    return ground(GROUND_Y, 132, 210)


def d_move_forward(w, h):
    return svg(w, h, [hand(pinch="index", transform=HAND_DROP),
                      panel_ground(), arrow(PANEL_X, GROUND_Y - 8, PANEL_X, 34)],
               "off hand, thumb to index: walk forward")


def d_move_backward(w, h):
    return svg(w, h, [hand(pinch="middle", transform=HAND_DROP),
                      panel_ground(), arrow(PANEL_X, 34, PANEL_X, GROUND_Y - 8)],
               "off hand, thumb to middle finger: walk backward")


def d_crouch(w, h):
    return svg(w, h, [hand(pinch="pinky", transform=HAND_DROP),
                      panel_ground(),
                      arrow(PANEL_X, 70, PANEL_X, 124),
                      line(PANEL_X - 20, 138, PANEL_X + 20, 138, "arw")],
               "off hand, thumb to little finger: crouch")


def d_jump(w, h):
    return svg(w, h, [hand(pinch="ring", right=True, transform=HAND_DROP),
                      panel_ground(),
                      '<path class="gst" d="M %s Q %s %s"/>'
                      % (pt((140, GROUND_Y - 6)), pt((PANEL_X, 44)), pt((204, GROUND_Y - 6))),
                      arrow(144, 154, 163, 84)],
               "gun hand, thumb to ring finger: jump")


def d_fire(w, h):
    muzzle = 148.0
    burst = ['<path class="arw" d="M %s L %s"/>'
             % (pt((PANEL_X + 11 * math.cos(a), muzzle + 11 * math.sin(a))),
                pt((PANEL_X + 22 * math.cos(a), muzzle + 22 * math.sin(a))))
             for a in (math.radians(d) for d in (170, 205, 245, 295, 335, 10))]
    return svg(w, h, [hand(pinch="index", right=True, transform=HAND_DROP),
                      arrow(PANEL_X, muzzle - 14, PANEL_X, 26)] + burst,
               "gun hand, thumb to index: fire")


def d_hud_grab(w, h):
    return svg(w, h, [hand(pinch="index", transform=HAND_DROP),
                      rrect(132, 26, 56, 34, 6, "arw"),
                      rrect(154, 114, 56, 34, 6),
                      arrow(140, 66, 174, 108)],
               "pinch and drag a HUD tile")


# -- the aim family: the hand turned a quarter clockwise, forearm and all ----

def arm(angle, wrist_at, right=True):
    dx, dy = wrist_at[0] - WRIST[0], wrist_at[1] - WRIST[1]
    tf = "translate(%s,%s) rotate(%s %s)" % (f(dx), f(dy), f(angle), pt(WRIST))
    return hand(right=right, transform=tf, extra=FOREARM)


def d_aim(w, h):
    axis = 86.0
    return svg(w, h, [arm(90, (76.0, axis)),
                      line(24, axis, 196, axis, "gst"),
                      arrow(190, axis, w - 10, axis)],
               "aim along the forearm")


def d_turn_body(w, h):
    o = (19.0, 33.0)
    span = ('<path class="gst" d="M %s A 44 44 0 0 1 %s"/>'
            % (pt((o[0] + 44, o[1])),
               pt((o[0] + 44 * math.cos(math.radians(28)),
                   o[1] + 44 * math.sin(math.radians(28))))))
    return svg(w, h, [arm(118, (74.0, 62.0)),
                      line(o[0] + 4, o[1], w - 16, o[1], "gst"), span,
                      arc_arrow(58, 146, 34, 200, 340)],
               "hold the aim off centre and the body turns")


# -- turning on the gun hand ------------------------------------------------

def d_turn_drag(w, h):
    anchor = (36.0, 126.0)
    return svg(w, h, [hand(pinch="middle", right=True, transform="translate(60,0)"),
                      '<circle class="gst" cx="%s" cy="%s" r="9"/>' % (f(anchor[0]), f(anchor[1])),
                      arrow(anchor[0] + 14, anchor[1], anchor[0] + 58, anchor[1]),
                      arc_arrow(52, 176, 34, 202, 338)],
               "gun hand, thumb to middle finger, held out to a side: turn")


def d_turn_flick(w, h):
    trails = ['<path class="gst" d="M %s Q %s %s"/>'
              % (pt((46 - i * 13, 50 + i * 5)), pt((54 - i * 13, 96)), pt((46 - i * 13, 142 - i * 5)))
              for i in range(3)]
    return svg(w, h, trails + [hand(right=True, transform="translate(62,0)"),
                               arrow(16, 168, w - 16, 168)],
               "gun hand, whipped sideways: quick turn")


def d_teleport(w, h):
    pad = (166.0, 150.0)
    return svg(w, h, [hand(pinch="ring"),
                      ellipse(pad[0], pad[1], 30, 11),
                      '<path class="arw" d="M %s Q %s %s"/>'
                      % (pt((112, 116)), pt((154, 96)), pt((pad[0] + 6, pad[1] - 16))),
                      arrow(pad[0] + 5, pad[1] - 24, pad[0] + 2, pad[1] - 11)],
               "off hand, thumb to ring finger, released: teleport")


def d_weapon_wheel(w, h):
    cx, cy, rx, ry = HAND_MID + 12, 150.0, 62.0, 21.0
    creases = ('<path class="arw" d="M %s Q %s %s"/>'
               % (pt((45, 108)), pt((62, 116)), pt((82, 110)))
               + '<path class="arw" d="M %s Q %s %s"/>'
               % (pt((45, 122)), pt((60, 130)), pt((74, 128))))
    ring = ['<path class="gst" d="M %s A %s %s 0 0 1 %s"/>'
            % (pt((cx + rx, cy)), f(rx), f(ry), pt((cx - rx, cy)))]
    for i in range(6):
        a = math.radians(i * 36)
        x, y = cx + rx * math.cos(a), cy + ry * math.sin(a)
        ring.append('<circle class="%s" cx="%s" cy="%s" r="6"/>'
                    % ("hi" if i == 1 else "ln", f(x), f(y)))
    aim_at = (cx + rx * math.cos(math.radians(36)), cy + ry * math.sin(math.radians(36)))
    # The ring opens by turning this wrist over, not by raising a palm -- the
    # shared hand geometry is already drawn back-of-hand-to-viewer (see this
    # file's module docstring), so no flip is needed, just a forearm for the
    # twist arrow to wrap.
    twist = arc_arrow(cx, 214, 34, 202, 338)
    return svg(w, h, ring
               + [hand(right=True, transform="translate(12,0)", extra=creases + FOREARM),
                  arrow(aim_at[0] - 26, aim_at[1] - 22, aim_at[0] - 9, aim_at[1] - 8),
                  twist],
               "off wrist turned over, back of the hand up: the weapon wheel")


def d_summon(w, h):
    seam = 100.0
    left = hand(transform="translate(-4,0)", open_thumb=False)
    rightg = '<g transform="translate(%s,0) scale(-1,1)">%s</g>' % (f(seam * 2 + 4), left)
    return svg(w, h, [left, rightg,
                      '<path class="hi" d="M %s L %s"/>' % (pt((seam, 44)), pt((seam, 128))),
                      arc_arrow(seam, h - 26, 22, 140, 390)],
               "both palms together, fingers up: summon the window")


def d_wristcomm(w, h):
    top, bot = 34.0, 96.0
    arm_g = [line(18, top, 146, top, "ln"), line(18, bot, 146, bot, "ln"),
             '<path class="ln" d="M %s Q %s %s"/>' % (pt((18, top)), pt((6, 65)), pt((18, bot))),
             '<path class="ln" d="M %s Q %s %s"/>' % (pt((146, top)), pt((160, 65)), pt((146, bot))),
             line(134, top + 4, 134, bot - 4, "gst")]
    cells = []
    for r in range(2):
        for c in range(3):
            x, y = 28 + c * 36, 42 + r * 28
            cells.append(rrect(x, y, 30, 22, 4, "hi" if (r == 1 and c == 2) else "arw"))
    finger = ('<path class="hi" d="M %s L %s A %s %s 0 0 1 %s L %s"/>'
              % (pt((108, 172)), pt((108, 100)), f(FW), f(FW), pt((121, 100)), pt((121, 172))))
    knuckle = '<path class="hi" d="M %s Q %s %s"/>' % (pt((96, 168)), pt((114, 178)), pt((133, 166)))
    eye = ['<path class="arw" d="M %s Q %s %s Q %s %s"/>'
           % (pt((166, 24)), pt((188, 8)), pt((210, 24)), pt((188, 40)), pt((166, 24))),
           '<circle class="arw" cx="188" cy="24" r="5"/>',
           line(172, 36, 126, 58, "gst")]
    return svg(w, h, arm_g + cells + [finger, knuckle,
                                      '<circle class="hi" cx="114" cy="96" r="7.5"/>'] + eye,
               "glance at the off wrist, touch a key")


DIAGRAMS = {
    "hands-aim":           (236, 160, d_aim),
    "hands-fire":          (PW, PH, d_fire),
    "hands-move-forward":  (PW, PH, d_move_forward),
    "hands-move-backward": (PW, PH, d_move_backward),
    "hands-crouch":        (PW, PH, d_crouch),
    "hands-jump":          (PW, PH, d_jump),
    "hands-turn-drag":     (220, 194, d_turn_drag),
    "hands-turn-flick":    (220, 182, d_turn_flick),
    "hands-turn-body":     (230, 176, d_turn_body),
    "hands-teleport":      (212, 180, d_teleport),
    "hands-weapon-wheel":  (176, 224, d_weapon_wheel),
    "hands-summon":        (204, 186, d_summon),
    "hands-wristcomm":     (216, 184, d_wristcomm),
    "hands-hud-grab":      (PW, PH, d_hud_grab),
}


def main():
    with open(os.path.join(OUT, "manifest.json")) as fh:
        manifest = json.load(fh)
    wanted = {c["id"]: c for c in manifest["controls"] if c.get("diagram")}
    missing = set(wanted) - set(DIAGRAMS)
    extra = set(DIAGRAMS) - set(wanted)
    if missing or extra:
        sys.exit("manifest/DIAGRAMS mismatch: missing %s, extra %s"
                 % (sorted(missing), sorted(extra)))

    written = []
    for cid, control in wanted.items():
        w, h, fn = DIAGRAMS[cid]
        path = os.path.join(OUT, control["diagram"])
        with open(path, "w") as fh:
            fh.write(fn(w, h))
        written.append((cid, w, h, path))
    print("wrote %d diagrams to %s" % (len(written), OUT))

    if "--sheet" in sys.argv:
        sheet_dir = sys.argv[sys.argv.index("--sheet") + 1]
        cols, cw, ch = 4, 210, 200
        rows = (len(written) + cols - 1) // cols
        body = []
        for i, (cid, w, h, path) in enumerate(written):
            x, y = (i % cols) * cw, (i // cols) * ch
            with open(path) as fh:
                inner = fh.read()
            inner = inner.split(">", 1)[1].rsplit("</svg>", 1)[0]
            body.append('<g transform="translate(%d,%d)">%s</g>' % (x + 5, y + 5, inner))
        out = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d">'
               '<rect width="%d" height="%d" fill="#ffffff"/>%s</svg>\n'
               % (cols * cw, rows * ch, cols * cw, rows * ch, "".join(body)))
        with open(os.path.join(sheet_dir, "sheet.svg"), "w") as fh:
            fh.write(out)
        print("wrote contact sheet to %s/sheet.svg" % sheet_dir)


if __name__ == "__main__":
    main()

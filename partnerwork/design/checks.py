"""The claims the eye cannot check, asserted instead of trusted.

Everything the page argues is here as a test: the hands land where the old
columns put them, an orbit collapses onto the matching axis turn mark for
mark, every cycle closes, no reach enters a body, a bare border carries no arm
ink, and the sign's geometry is even to the tenth of a unit.
"""
import math

from .body import (ARM_REST, BODY_R, CHEV_OUT, HAND_GAP, R, RIM_W, border,
                   hands_of, outline_r, side_of)
from .figure import facings
from .geometry import bearing, continuous, wrap180
from .pose import (MOVES, canonicalise, couple, cycle, orbit, relative, rest,
                   spin_about)
from .route import ROUTE_N, polyline_len, routed, split_at
from .sign import BODY, COS, GAP_X, HEIGHT, OVER, PIP, QUARTERS, SIN, TAN
from .style import CAP


def check_frame():
    """The claims the eye cannot check, and the interesting ones are claims."""
    want = {("lead", "L"): (-20, 28), ("lead", "R"): (20, 28),
            ("follow", "L"): (20, -28), ("follow", "R"): (-20, -28)}
    h = hands_of(rest())
    for (who, sd), (wx, wy) in want.items():
        gx, gy = h[who][sd]
        assert abs(gx - wx) < 0.01 and abs(gy - wy) < 0.01, (who, sd, gx, gy)

    # the collapse: an orbit lands where an axis turn lands.  A follow who walks
    # a quarter round the lead keeping their face to them arrives at the state
    # the lead reaches by turning a quarter on the spot.
    walked = relative(canonicalise(orbit(rest(), "follow", 90, locked=True)))
    turned = relative(spin_about(rest(), "lead", -90))
    assert walked == turned, (walked, turned)

    # both going round each other changes nothing about the picture
    assert relative(canonicalise(couple(rest(), 73))) == relative(rest())

    # and a whole cycle comes back to exactly where it started
    for name, move in MOVES.items():
        poses = cycle(move)
        assert relative(poses[-1]) == relative(rest()), (name, relative(poses[-1]))

    # the boundary is a plain circle, and its two stretches tile it once: what
    # is drawn plus the two hand gaps covers the rim exactly, whatever the
    # winding, and every stretch ends a hand-gap short of the hand it meets
    assert all(abs(outline_r(d) - BODY_R) < 1e-9 for d in range(0, 360, 7))
    for wl, wr in ((0, 0), (45, 0), (0, 90)):
        right, left = ARM_REST + wr, ARM_REST + wl
        edges = [right + HAND_GAP, 360 - left - HAND_GAP,
                 360 - left + HAND_GAP, 360 + right - HAND_GAP]
        assert all(b >= a for a, b in zip(edges, edges[1:])), (wl, wr, edges)
        drawn = sum(b - a for a, b in zip(edges[::2], edges[1::2]))
        assert abs(drawn + 4 * HAND_GAP - 360) < 1e-9, (wl, wr, drawn)
    # extreme winding squeezes the back away entirely; the border skips the
    # reversed stretch rather than drawing it backwards
    squeezed = border(rest({"lead": {"L": 135.0, "R": 0.0}}), "lead")
    assert squeezed.count("<path") == 1, squeezed.count("<path")

    # the centred chevron stays well inside its own rim
    assert CHEV_OUT + RIM_W < BODY_R, CHEV_OUT

    # the rim is quiet, always: no arm colour fills up around a body, because
    # how far the hand has been carried is said by the connection wrapping it
    for wind in ({}, {"lead": {"L": 135.0, "R": 0.0}}):
        rimmed = border(rest(wind), "lead")
        assert "var(--left" not in rimmed and "var(--right" not in rimmed, wind

    # a reach is two shades of one hue meeting at its middle: the lead's end
    # deep, the follow's plain, and the two halves the same length
    pose = canonicalise(spin_about(rest(), "follow", 90))
    ends = hands_of(pose)
    pts, _ = routed(ends["lead"]["L"], ends["follow"]["L"],
                    (pose["lead"], pose["lead_facing"]),
                    (pose["follow"], pose["follow_facing"]))
    near, far = split_at([pts], pts[len(pts) // 2])
    lengths = (polyline_len(near[0]), polyline_len(far[0]))
    assert abs(lengths[0] - lengths[1]) < 0.05, lengths
    assert near[0][0] == pts[0] and far[0][-1] == pts[-1], "halves out of order"
    assert near[0][-1] == far[0][0], "halves do not meet"

    # a body turns the way it turned: the facings an animation is handed never
    # step half a turn, so nothing interpolating them can go the long way round
    assert continuous([170.0, 175.0, -175.0]) == [170.0, 175.0, 185.0]
    biggest = 0.0
    for name, move in MOVES.items():
        poses = cycle(move)
        for who in ("lead", "follow"):
            steps = facings(poses, who)
            for a, b in zip(steps, steps[1:]):
                biggest = max(biggest, abs(b - a))
    assert biggest < 90, biggest

    # where the two ways round are close, the bias sends the reach across the
    # front -- the case the comparison figure draws, so it must really differ,
    # and differ in the front direction
    pose = canonicalise(spin_about(rest(), "follow", 270))
    pts_all = hands_of(pose)
    a, b = pts_all["lead"]["L"], pts_all["follow"]["L"]
    bodies = ((pose["lead"], pose["lead_facing"]),
              (pose["follow"], pose["follow_facing"]))
    biased, _ = routed(a, b, *bodies)
    short, _ = routed(a, b, *bodies, back_bias=0.0)
    assert biased != short, "front bias changes nothing here"

    def follow_offset(q):
        return abs(wrap180(bearing(q[0] - pose["follow"][0],
                                   q[1] - pose["follow"][1])
                           - pose["follow_facing"]))

    assert follow_offset(biased[-3]) < follow_offset(short[-3]), "bias backward"

    # and no reach ever crosses into a body: every hold, every quarter-turn
    # orientation, sampled along the route it would actually be drawn with
    worst = 99.0
    ends_off = 0.0
    for holds in ({"L": "left"}, {"L": "right"}, {"L": "left", "R": "right"}):
        for lead_turn in (0, 90, 180):
            for follow_turn in (0, 90, 180):
                pose = canonicalise(spin_about(spin_about(
                    rest(), "lead", lead_turn), "follow", follow_turn))
                pts_all = hands_of(pose)
                for sd, where in holds.items():
                    own = side_of(where)
                    a, b = pts_all["lead"][sd], pts_all["follow"][own]
                    pts, _ = routed(a, b,
                                    (pose["lead"], pose["lead_facing"]),
                                    (pose["follow"], pose["follow_facing"]))
                    assert len(pts) == ROUTE_N, len(pts)
                    if math.dist(a, b) > 2 * (R + CAP) + 3:
                        ends_off = max(ends_off,
                                       abs(math.dist(pts[0], a) - (R + CAP)),
                                       abs(math.dist(pts[-1], b) - (R + CAP)))
                    for q in pts:
                        for who in ("lead", "follow"):
                            c, f = pose[who], pose[f"{who}_facing"]
                            worst = min(worst, math.dist(q, c) - outline_r(
                                bearing(q[0] - c[0], q[1] - c[1]) - f))
    assert worst > -0.4, worst
    assert ends_off < 0.3, ends_off
    print(f"  frame: hands at rest exact; orbit collapses onto axis at {walked};"
          f" every cycle closes; every rim is quiet and breaks at its hands;"
          f" a facing never steps more than {biggest:.1f} degrees a frame;"
          f" every reach stays on or outside the bodies (margin {worst:.2f})"
          f" and starts {R + CAP} from its hand (off by {ends_off:.2f})")

def check_sign():
    """The numbers the eye cannot check: equal sides, margins, gaps, clearance."""
    y_foot = 5.0 + OVER
    y_bot = y_foot + HEIGHT
    for rows in range(1, QUARTERS + 1):
        sides, margins, gaps, clear = set(), set(), [], set()
        edges = []
        for place in range(rows):
            top = (y_bot - GAP_X - place * (PIP + GAP_X) - PIP
                   + (PIP - PIP * COS) / 2)
            left = 5.0 + (y_bot - top) * TAN
            ax = left + GAP_X
            pts = [(ax, top), (ax + PIP, top),
                   (ax + PIP - PIP * SIN, top + PIP * COS),
                   (ax - PIP * SIN, top + PIP * COS)]
            for i in range(4):
                x1, y1 = pts[i]
                x2, y2 = pts[(i + 1) % 4]
                sides.add(round(math.hypot(x2 - x1, y2 - y1), 3))
            bottom_left = 5.0 + (y_bot - (top + PIP * COS)) * TAN
            margins.add(round(pts[0][0] - left, 3))
            margins.add(round(pts[3][0] - bottom_left, 3))
            margins.add(round(left + BODY - (pts[1][0] + PIP + GAP_X), 3))
            # A circle has no corners to tuck under the lean, so its clearance
            # is measured square to the edge rather than across the page.
            for col in (0, 1):
                across = GAP_X + col * (PIP + GAP_X) + PIP / 2
                clear.add(round(min(across, BODY - across) * COS - PIP / 2, 3))
            edges.append((y_bot - GAP_X - place * (PIP + GAP_X) - PIP,
                          y_bot - GAP_X - place * (PIP + GAP_X)))
        edges.sort()
        gaps.append(round(edges[0][0] - y_foot, 3))          # to the lid
        for a, b in zip(edges, edges[1:]):
            gaps.append(round(b[0] - a[1], 3))
        gaps.append(round(y_bot - edges[-1][1], 3))          # to the foot
        assert sides == {11.0}, sides
        assert margins == {4.0}, margins
        assert min(clear) > 0, clear
        assert gaps[-1] == GAP_X and set(gaps[1:]) == {GAP_X}, gaps
        if rows == QUARTERS:
            assert gaps[0] == GAP_X, gaps
        print(f"  {rows}/4: sides {sorted(sides)} margins {sorted(margins)} "
              f"gaps {gaps} circle clearance {sorted(clear)}")

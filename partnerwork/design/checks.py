"""The claims the eye cannot check, asserted instead of trusted.

Everything the page argues is here as a test: the hands land where the old
columns put them, an orbit collapses onto the matching axis turn mark for
mark, every cycle closes, no reach enters a body, a bare border carries no arm
ink, and the sign's geometry is even to the tenth of a unit.
"""
import math

from .body import (ARM_REST, BODY_R, CHEV_OUT, FROM_ABOVE, HAND_GAP, R,
                   RIM_W, SLOTS, border, hand_bearing, hands_of, other,
                   outline_r, round_of, side_of, slot_bearing, slot_of)
from .figure import danceable, facings, frame, settled
from .geometry import bearing, continuous, wrap180
from .pose import (MOVES, canonicalise, couple, cycle, orbit, relative, rest,
                   spin_about)
from .route import (ROUTE_N, WRAP_MIN, front_of, one_way_round,
                    polyline_len, routed, split_at, way_for,
                    wrap_arc)
from .parts import said
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


HOLD = {"L": "left"}

def check_rules():
    """Every rule as it was given, and the assertion that holds the drawing to
    it.  The numbering matches the ledger in the README; the wording of each
    heading is the wording the rule arrived in.  A rule that is only
    implemented and not asserted is a rule that quietly stops being true.
    """
    told = []

    # RULE 1.  "the hands should only pass through the circle when the hand
    # positions are above" -- and a moving picture is not the frames it is
    # sampled at, it is the blend between them, point by point.  Two
    # neighbouring frames that disagree about which side of a body the line
    # goes round are drawn, in between, as a line sweeping straight through
    # that body.  So this checks what is *drawn*: every consecutive pair, part
    # way between, with the bodies interpolated too because they move as well.
    # The version of this that looked only at the sampled frames let a line
    # through the middle of a dancer, twice.
    swept, at = 99.0, None
    for name, move in MOVES.items():
        poses = [settled(q, HOLD, {}, {}) for q in cycle(move)]
        hands = [hands_of(q) for q in poses]
        frames = [(h["lead"]["L"], h["follow"][side_of("left")],
                   (q["lead"], q["lead_facing"]),
                   (q["follow"], q["follow_facing"]))
                  for h, q in zip(hands, poses)]
        way = one_way_round(frames)
        runs = [routed(*f, way=way)[0] for f in frames]
        for k in range(len(runs) - 1):
            qa, qb = poses[k], poses[k + 1]
            for part in (0.25, 0.5, 0.75):
                drawn = [(a[0] + (b[0] - a[0]) * part,
                          a[1] + (b[1] - a[1]) * part)
                         for a, b in zip(runs[k], runs[k + 1])]
                for who in ("lead", "follow"):
                    c = tuple(qa[who][i] + (qb[who][i] - qa[who][i]) * part
                              for i in (0, 1))
                    f = (qa[f"{who}_facing"] + part
                         * (qb[f"{who}_facing"] - qa[f"{who}_facing"]))
                    for p, q in zip(drawn, drawn[1:]):
                        for i in range(9):
                            t = i / 8
                            pt = (p[0] + (q[0] - p[0]) * t,
                                  p[1] + (q[1] - p[1]) * t)
                            deep = math.dist(pt, c) - outline_r(
                                bearing(pt[0] - c[0], pt[1] - c[1]) - f)
                            if deep < swept:
                                swept, at = deep, (name, k, who)
    assert swept > -0.3, (swept, at)
    told.append(f"only `above` crosses a body, at every instant drawn"
                f" (worst {swept:.2f})")

    # RULE 2.  "the hands can only move from their positions at the side of the
    # body only if a level is specified", and a level alone is not enough: the
    # way has to be said too, or there is no knowing which side it went to.
    for level, way, moves in ((None, None, False), ("low", None, False),
                              (None, "wrap", False), ("low", "lock", True)):
        put = hands_of(settled(rest(), HOLD, said(level), said(way)))["lead"]["L"]
        assert (put != hands_of(rest())["lead"]["L"]) == moves, (level, way)
    told.append("a hand moves only when a level *and* a way are named")

    # RULE 3.  "4 spots, only default and behind" became six again: default,
    # and one a little towards the front and one a little towards the back,
    # measured off the dancer's own facing and never off the page.
    places = {(side, slot): slot_bearing(side, slot)
              for side in ("L", "R") for slot in SLOTS}
    apart = min(abs(wrap180(a - b))
                for i, a in enumerate(places.values())
                for b in list(places.values())[i + 1:])
    assert len(places) == 6, places
    assert apart > 2 * math.degrees(math.asin(R / BODY_R)), apart
    # and they turn with the dancer: settle a hold, turn the follow, and every
    # hand is still exactly where its spot says relative to its own facing
    for turn in (0, 90, 180, 270):
        pose = settled(canonicalise(spin_about(rest(), "follow", turn)),
                       HOLD, {"L": "low"}, {"L": "lock"})
        for who, sd in (("lead", "L"), ("follow", "L")):
            got = hand_bearing(0.0, sd, pose[f"{who}_wind"][sd])
            assert abs(wrap180(got - slot_bearing(*slot_of(sd, "low", "lock")))
                       ) < 1e-9, (turn, who)
    told.append(f"six spots, {apart:.0f} degrees apart at the closest,"
                " off each dancer's own facing")

    # RULES 4, 5 and 6.  "high and low wraps go around to the front of the
    # other hand, low lock goes around the back to the back of the other hand"
    # and "in high lock the line goes around the back of the modified body",
    # to the back of the current hand.
    WHERE = {("high", "wrap"): ("other", "front", "front"),
             ("low", "wrap"): ("other", "front", "front"),
             ("low", "lock"): ("other", "back", "back"),
             ("high", "lock"): ("own", "back", "back")}
    for (level, way), (whose, spot, sends) in WHERE.items():
        for side in ("L", "R"):
            lands = side if whose == "own" else other(side)
            assert slot_of(side, level, way) == (lands, spot), (side, level, way)
        assert round_of(level, way) == sends, (level, way)
        # and the drawn route really does set off that way, at both ends
        turn = 180 if way == "wrap" else 0
        pose = settled(canonicalise(spin_about(rest(), "follow", turn)),
                       HOLD, {"L": level}, {"L": way})
        p = hands_of(pose)
        a, b = p["lead"]["L"], p["follow"][side_of("left")]
        bodies = ((pose["lead"], pose["lead_facing"]),
                  (pose["follow"], pose["follow_facing"]))
        asked = way_for((a, b), bodies, level, way)
        towards = 1 if sends == "front" else -1
        assert asked == (towards * front_of(a, bodies[0]),
                         towards * front_of(b, bodies[1])), (level, way)
        assert routed(a, b, *bodies, way=asked)[1] == asked, (level, way)
    told.append("both wraps land in front and go round the front; both locks"
                " land behind and go round the back")

    # RULE 7.  "lock/wrap positions can only be used when the connecting line
    # goes around no less than just under 1/2 of the circumference.  it doesn't
    # make sense to have a wrap or a lock without the line actually going
    # around the body."
    seen = set()
    for level, way in WHERE:
        for turn in (0, 90, 180, 270):
            pose = canonicalise(spin_about(rest(), "follow", turn))
            p = hands_of(settled(pose, HOLD, {"L": level}, {"L": way}))
            bodies = ((pose["lead"], pose["lead_facing"]),
                      (pose["follow"], pose["follow_facing"]))
            ends = (p["lead"]["L"], p["follow"][side_of("left")])
            asked = way_for(ends, bodies, level, way)
            arcs = wrap_arc(*ends, *bodies, asked)
            ok = danceable(pose, HOLD, {"L": level}, {"L": way})
            assert ok == (arcs[0] is not None and max(arcs) >= WRAP_MIN)
            if arcs[0] is not None:
                seen.add(max(arcs))
    # the arcs are quantised, and the threshold sits in the gap below a half
    assert all(v <= 141 or v >= 180 for v in seen), sorted(seen)
    assert 141 < WRAP_MIN < 180, WRAP_MIN
    told.append(f"a lock or wrap needs {WRAP_MIN} degrees of wrap; the arcs"
                f" this geometry makes are {sorted(int(v) for v in seen)}")

    # RULE 8.  "above has no locks/wraps and can only transition to upper wrap
    # or back to default (physical restrictions)."  `upper wrap` is read as the
    # high wrap; that reading is mine and not the rule's.
    for way in ("lock", "wrap", None):
        assert slot_of("L", "above", way) == ("L", "default"), way
        assert round_of("above", way) is None, way
    assert FROM_ABOVE == ("high wrap", "default"), FROM_ABOVE
    told.append("`above` takes no lock or wrap, and leads only to"
                f" {' or '.join(FROM_ABOVE)}")

    # RULE 9.  the connecting line's two halves are its two hands' own colours
    crossed = frame("f", {"L": "right"}, {"L": "low"})
    assert "var(--left-deep)" in crossed and "var(--right)" in crossed
    told.append("a connection is drawn in its two hands' own colours")

    for line in told:
        print(f"  rule: {line}")

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

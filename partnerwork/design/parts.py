"""Every figure the two pages place, keyed by the name each page uses.

Split the way the pages are: the frame picture is one exploration and the turn
sign another.  The inline assertions are part of the build -- a page whose
orientations collide or whose collapse figures differ is refused, not
published.
"""
from .body import (BODY_R, R, SLOTS, border, chevron, hand, slot_bearing,
                   slot_of)
from .figure import animated, extent, frame
from .geometry import n, polar
from .pose import (MOVES, NO_WIND, canonicalise, cycle, orbit, relative, rest,
                   spin_about)
from .sign import sign
from .style import FAINT

ORIENTATIONS = [
    ("face to face", 0, 0),
    ("the follow faces away", 0, 180),
    ("the lead faces away", 180, 0),
    ("back to back", 180, 180),
]

LOW = {"L": "low", "R": "low"}
SPLIT = {"L": "low", "R": "high"}
HOLD = {"L": "left"}


SETTLINGS = (
    (None, None, "no way said<br>— it stays at its side"),
    ("low", "lock", "<em>low</em> lock"),
    ("high", "lock", "<em>high</em> lock"),
    ("low", "wrap", "<em>low</em> wrap"),
    ("high", "wrap", "<em>high</em> wrap"),
)

CHART_FACING = 40         # the chart's body is turned off the vertical, so the
                          # spots visibly follow the chevron and not the page


def slot_chart(side="L"):
    """One body with all four spots on it, and this hand's three marked.

    Drawn rather than tabulated because the table is the thing most likely to
    be wrong -- and drawn on a body turned off the vertical, because the spots
    are measured off the dancer's facing rather than off the page, and a body
    facing up hides the difference.
    """
    # its own box rather than the square every other figure uses: the labels
    # are wide and the body is small, so a square would draw it tiny
    out = ['<svg viewBox="-80 -46 160 92" width="248" height="143">']
    pose = {"lead": (0.0, 0.0), "lead_facing": float(CHART_FACING),
            "lead_wind": dict(NO_WIND), "ring": None}
    out.append(border(pose, "lead"))
    out.append(chevron((0.0, 0.0), float(CHART_FACING)))
    lands = {slot_of(side, level, way) for level, way, _ in SETTLINGS}
    for place in ("L", "R"):
        for slot in SLOTS:
            aim = CHART_FACING + slot_bearing(place, slot)
            x, y = polar(0.0, 0.0, BODY_R, aim)
            # in this hand's own ink wherever it sits, because that is the
            # point: a Left hand carried to the right side is still the Left
            used = (place, slot) in lands
            out.append(hand(x, y, True, side, used, None,
                            free="fade" if used else "grey"))
            lx, ly = polar(0.0, 0.0, BODY_R + R + 13, aim)
            out.append(f'<text x="{n(lx)}" y="{n(ly + 3)}"'
                       f' text-anchor="{"end" if lx < 0 else "start"}"'
                       ' style="font: 8px ui-sans-serif, system-ui,'
                       f' sans-serif; fill: {FAINT}">'
                       f'{"side" if slot == "default" else slot}</text>')
    return "".join(out) + "</svg>"


def frame_parts():
    """Every SVG the frame page places."""
    parts = {}
    parts["f_none"] = frame("f", HOLD)
    parts["f_low"] = frame("f", HOLD, {"L": "low"})
    parts["f_high"] = frame("f", HOLD, {"L": "high"})
    parts["f_above"] = frame("f", HOLD, {"L": "above"})
    parts["f_over"] = frame("f", {"L": "left", "R": "right"},
                            {"L": "high", "R": "low"}, over="L")

    # the four orientations, twice: with nothing held, where only the colours
    # and the chevrons can say it, and holding, where the line is there as well
    seen = {}
    for i, (name, lead_turn, follow_turn) in enumerate(ORIENTATIONS):
        parts[f"or_open_{i}"] = frame("f", {}, lead_turn=lead_turn,
                                      follow_turn=follow_turn)
        parts[f"or_held_{i}"] = frame("f", HOLD, lead_turn=lead_turn,
                                      follow_turn=follow_turn)
        parts[f"or_tiny_{i}"] = frame("tiny", HOLD, lead_turn=lead_turn,
                                      follow_turn=follow_turn, captions=False)
        seen[name] = parts[f"or_open_{i}"]
    assert len(set(seen.values())) == len(ORIENTATIONS), "orientations collide"

    # free hands: keep the hue, or go grey and lose the orientation with it
    parts["free_fade"] = frame("f", {}, free="fade")
    parts["free_grey"] = frame("f", {}, free="grey")
    parts["free_fade_tiny"] = frame("tiny", {}, free="fade", captions=False)
    parts["free_grey_tiny"] = frame("tiny", {}, free="grey", captions=False)

    # what the pair of colours at the two ends says
    parts["pair_ll"] = frame("f", HOLD)
    parts["pair_ll_turned"] = frame("f", HOLD, follow_turn=180)
    parts["pair_lr"] = frame("f", {"L": "right"})
    parts["pair_lr_turned"] = frame("f", {"L": "right"}, follow_turn=180)

    # the four spots, and the five settlings that reach three of them
    parts["slot_chart"] = slot_chart("L")
    seen = {}
    for k, (level, way, _) in enumerate(SETTLINGS):
        levels = {} if level is None else {"L": level}
        ways = {} if way is None else {"L": way}
        parts[f"settle_{k}"] = frame("f", HOLD, levels, ways=ways,
                                     captions=False)
        seen.setdefault(slot_of("L", level, way), []).append(k)
    # a Left hand reaches three of the four; the fourth belongs to the Right
    assert sorted(seen) == [("L", "behind"), ("L", "default"),
                            ("R", "behind")], sorted(seen)
    # and the two that share a spot are told apart by their fill alone
    assert parts["settle_1"] != parts["settle_2"], "high and low lock collide"
    assert parts["settle_3"] != parts["settle_4"], "high and low wrap collide"

    # the routing the hold decides: a wrap round the front, a low lock round
    # the back, of the body each end belongs to
    for name, level, way in (("route_wrap", "low", "wrap"),
                             ("route_lock", "low", "lock")):
        parts[name] = frame("f", HOLD, {"L": level}, ways={"L": way},
                            captions=False)
    assert parts["route_wrap"] != parts["route_lock"], "the rules agree"

    # a wrap really does put a body in the way, which is what makes `above`
    # passing straight through worth having
    for name, level in (("wrap_low", "low"), ("wrap_above", "above")):
        parts[name] = frame("f", HOLD, {"L": level}, ways={"L": "wrap"},
                            captions=False)
    assert parts["wrap_low"] != parts["wrap_above"], "above went round"

    # an orbit in two stages: the follow travels, then the world comes home
    for tag, locked in (("locked", True), ("drift", False)):
        stage_one = [orbit(rest(), "follow", 90 * f, locked=locked)
                     for f in (0, 0.5, 1)]
        stage_one[0]["ring"] = None          # nothing is travelling yet
        landed = stage_one[-1]
        stage_two = [canonicalise(landed, f) for f in (0.5, 1)]
        for q in stage_two:
            q["ring"] = None
        walk = stage_one + stage_two
        half = max(extent(q, captions=False) for q in walk)
        for k, q in enumerate(walk):
            parts[f"walk_{tag}_{k}"] = frame("wide", HOLD, pose=q,
                                             captions=False, half=half)

    # the collapse: where the orbit lands, and where the axis turn lands
    landed = canonicalise(orbit(rest(), "follow", 90, locked=True))
    landed["ring"] = None                    # the move is over
    parts["collapse_orbit"] = frame("f", HOLD, pose=landed)
    parts["collapse_axis"] = frame("f", HOLD, lead_turn=-90)
    assert relative(landed) == relative(spin_about(rest(), "lead", -90))
    # not merely equal numbers: the two are the same drawing, mark for mark
    assert parts["collapse_orbit"] == parts["collapse_axis"], "collapse differs"

    # and the same four moves, running
    PX = 1.3
    for key, move in MOVES.items():
        tag = key.replace(" ", "_").replace(",", "")
        half = max(extent(q, captions=False) for q in cycle(move))
        parts[f"mv_{tag}"] = animated("mv", HOLD, move, half).replace(
            'class="mv"', f'class="mv" style="width: {n(2 * half * PX)}px;'
            f' height: {n(2 * half * PX)}px"', 1)
        parts[f"mv_{tag}_still"] = frame("mv still", HOLD, captions=False,
                                         half=half).replace(
            'class="mv still"',
            f'class="mv still" style="width: {n(2 * half * PX)}px;'
            f' height: {n(2 * half * PX)}px"', 1)
    return parts


def sign_parts():
    """Every SVG the turn-sign page places."""
    parts = {}
    # quarters, packed up from the foot
    for k in range(1, 5):
        parts[f"q_lead_{k}"] = sign(["lead"] * k, arms=LOW)
        parts[f"q_foll_{k}"] = sign(["follow"] * k, arms=LOW)
        parts[f"q_lead_{k}_small"] = sign(["lead"] * k, arms=LOW, scale=0.72)
    for k in (1, 3):                        # the alternative: spread, not packed
        parts[f"u_lead_{k}"] = sign(["lead"] * k, arms=LOW, packed=False)

    # whose quarter, and the arms inside
    parts["s_split"] = sign(["lead"] * 2, arms=SPLIT)
    parts["s_acw"] = sign(["lead"] * 3, "acw", LOW)
    parts["s_one_hand"] = sign(["follow"] * 2, arms={"L": "low"})
    parts["s_above"] = sign(["follow"] * 4, arms={"L": "above", "R": "above"})
    parts["s_unsaid"] = sign(["lead"], arms={"L": None, "R": None})
    parts["s_lead_small"] = sign(["lead"] * 2, arms=LOW, scale=0.72)
    parts["s_foll_small"] = sign(["follow"] * 2, arms=LOW, scale=0.72)
    # the shade says whose quarter it is as well as the shape does
    assert parts["s_lead_small"] != parts["s_foll_small"], "dancers collide"

    # mixed, now that there is room for more than one split
    parts["m_11"] = sign(["follow", "lead"], arms=LOW)
    parts["m_12"] = sign(["follow", "lead", "lead"], arms=LOW)
    parts["m_22"] = sign(["follow", "follow", "lead", "lead"], arms=LOW)
    parts["m_31"] = sign(["follow", "follow", "follow", "lead"], arms=LOW)
    parts["m_22_small"] = sign(["follow", "follow", "lead", "lead"], arms=LOW,
                               scale=0.72)

    # axis against orbit, on the sign
    parts["o_axis"] = sign(["lead"] * 2, arms=SPLIT, about="axis")
    parts["o_orbit"] = sign(["lead"] * 2, arms=SPLIT, about="orbit")
    parts["o_orbit_acw"] = sign(["follow"] * 3, "acw", SPLIT, about="orbit")
    parts["o_axis_small"] = sign(["lead"] * 2, arms=SPLIT, about="axis",
                                 scale=0.72)
    parts["o_orbit_small"] = sign(["lead"] * 2, arms=SPLIT, about="orbit",
                                  scale=0.72)
    parts["p_split"] = sign(["follow", "lead"], arms=SPLIT,
                            pip_about=["orbit", "axis"])
    parts["p_split_small"] = sign(["follow", "lead"], arms=SPLIT,
                                  pip_about=["orbit", "axis"], scale=0.72)

    # five ways to say "any amount"
    parts["any_full"] = sign(["lead"] * 4, arms=LOW)
    for name in ("open", "spill", "ellipsis", "repeat", "loop"):
        base = ["lead"] * (3 if name in ("ellipsis", "repeat") else 4)
        parts[f"any_{name}"] = sign(base, arms=LOW, ending=name)
        parts[f"any_{name}_small"] = sign(base, arms=LOW, ending=name,
                                          scale=0.72)
        foll = ["follow"] * (3 if name in ("ellipsis", "repeat") else 4)
        parts[f"any_{name}_foll"] = sign(foll, arms=LOW, ending=name)
    return parts

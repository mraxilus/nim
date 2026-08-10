"""Every figure the two pages place, keyed by the name each page uses.

Split the way the pages are: the frame picture is one exploration and the turn
sign another.  The inline assertions are part of the build -- a page whose
orientations collide or whose collapse figures differ is refused, not
published.
"""
from .body import hands_of, side_of
from .figure import animated, extent, frame
from .geometry import n
from .pose import MOVES, canonicalise, cycle, orbit, relative, rest, spin_about
from .route import across_front, polyline_len, round_back, routed
from .sign import sign

ORIENTATIONS = [
    ("face to face", 0, 0),
    ("the follow faces away", 0, 180),
    ("the lead faces away", 180, 0),
    ("back to back", 180, 180),
]

LOW = {"L": "low", "R": "low"}
SPLIT = {"L": "low", "R": "high"}
HOLD = {"L": "left"}


def both_ways(pose, hold=HOLD):
    """The two ways round, as drawn: their point lists, or None where the two
    readings come out at the same route and there is nothing to choose."""
    side, where = next(iter(hold.items()))
    ends_of = hands_of(pose)
    ends = (ends_of["lead"][side], ends_of["follow"][side_of(where)])
    bodies = ((pose["lead"], pose["lead_facing"]),
              (pose["follow"], pose["follow_facing"]))
    runs = [routed(*ends, *bodies, want=way(ends, bodies))[0]
            for way in (across_front, round_back)]
    return None if runs[0] == runs[1] else runs

def priciest(hold=HOLD):
    """The pose where insisting on a side costs the most, and by how much.

    Found by scanning rather than picked to flatter either reading: the largest
    ratio between the two ways round is what a rule would have to be willing to
    draw, and it is worth knowing before choosing between a rule and a bias.
    """
    worst = (None, 1.0)
    for wound in (0.0, 45.0, 90.0, 135.0):
        for lead_turn in (0, 90, 180, 270):
            for follow_turn in (0, 90, 180, 270):
                pose = canonicalise(spin_about(spin_about(
                    rest({"lead": {"L": wound, "R": 0.0}}),
                    "lead", lead_turn), "follow", follow_turn))
                runs = both_ways(pose, hold)
                if runs is None:
                    continue
                short, long = sorted(polyline_len(r) for r in runs)
                if short > 0 and long / short > worst[1]:
                    worst = (pose, long / short)
    assert worst[0] is not None, "the two ways round never differ"
    return worst


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

    # how far the hand has been carried round: the line does the saying, and a
    # hand only leaves the side of its body when the hold names a level
    for k, w in enumerate((0, 45, 90, 135)):
        parts[f"wind_{k}"] = frame("f", HOLD, {"L": "low"},
                                   wind={"lead": {"L": w, "R": 0.0}},
                                   captions=False)
    assert parts["wind_0"] != parts["wind_3"], "winding says nothing"
    # the same winding asked for with no level named, which cannot be obeyed
    parts["wind_pin"] = frame("f", HOLD, wind={"lead": {"L": 90.0, "R": 0.0}},
                              captions=False)
    parts["wind_rest"] = frame("f", HOLD, captions=False)
    assert parts["wind_pin"] == parts["wind_rest"], "an unlevelled hand moved"

    # the open question, drawn: which way round a body should a level send the
    # line?  Both readings, on three poses where the two ways really differ.
    SIDES = {
        "tie": dict(pose=canonicalise(spin_about(rest(), "follow", 270))),
        "wound": dict(wind={"lead": {"L": 45.0, "R": 0.0}}),
        "even": dict(lead_turn=270, follow_turn=270),
    }
    for tag, where in SIDES.items():
        for name, way in (("front", across_front), ("back", round_back)):
            parts[f"side_{name}_{tag}"] = frame("f", HOLD, {"L": "low"},
                                                want=way, captions=False,
                                                **where)
        assert parts[f"side_front_{tag}"] != parts[f"side_back_{tag}"], tag

    # and what insisting would cost: the pose where the two ways round differ
    # most in length, found by scanning rather than picked to flatter the rule
    pose, ratio = priciest()
    for name, way in (("front", across_front), ("back", round_back)):
        parts[f"cost_{name}"] = frame("f", HOLD, {"L": "low"}, pose=pose,
                                      want=way, captions=False)
    parts["cost_ratio"] = f"{ratio:.1f}"
    # the page says the worst case is under half again as long; if a change to
    # the routing makes that false the sentence has to change with it
    assert ratio < 1.5, ratio

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

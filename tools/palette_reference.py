#!/usr/bin/env python3
"""Recompute the palette's separations through an independent library.

`src/core/colorimetry.nim` is this project's own validator. This script measures the same
palette through `colorspacious` — a library written by someone else, from the same published
formulae — so the implementation is checked rather than trusted. The two use different
dichromat models on purpose: colorspacious simulates severity-100 deficiency after Machado,
Oliveira and Fernandes (2009), while the Nim side projects onto the missing cone's plane after
Viénot, Brettel and Mollon (1999). Agreement on normal-vision difference is exact to the
formula; agreement under deficiency is agreement about which pairs are the weak ones.

Usage: palette_reference.py [PALETTE_FILE]
       where PALETTE_FILE holds `name r g b` per line, as tools/palette_check.nim prints.
"""

import itertools
import pathlib
import subprocess
import sys

import numpy
from colorspacious import cspace_convert, deltaE

# Read the palette from the core rather than transcribing it: a second copy of the numbers is
# a second thing to drift.
PALETTE_SOURCE = pathlib.Path(__file__).resolve().parent.parent / "src/core/palette.nim"


def read_palette():
    """Read every slot's name and RGB out of the core's own table."""
    slots = {}
    for line in PALETTE_SOURCE.read_text().splitlines():
        stripped = line.strip()
        if not stripped.startswith("Paint.") or "Color(" not in stripped:
            continue
        name = stripped.split(".", 1)[1].split(":", 1)[0].strip()
        numbers = stripped.split("Color(", 1)[1].rstrip("),")
        channels = {}
        for field in numbers.split(","):
            if ":" not in field:
                continue
            key, value = field.split(":")
            channels[key.strip()] = float(value)
        slots[name] = numpy.array([channels["r"], channels["g"], channels["b"]])
    return slots


def hue_angle(rgb):
    """Read a colour's CIE L*a*b* hue in degrees."""
    lab = cspace_convert(rgb, "sRGB1", "CIELab")
    return numpy.degrees(numpy.arctan2(lab[2], lab[1])) % 360.0


def hue_distance(first, second):
    """Measure the shorter way round between two hues."""
    difference = abs(hue_angle(first) - hue_angle(second))
    return min(difference, 360.0 - difference)


def simulate(rgb, kind):
    """Simulate a severity-100 deficiency, after Machado, Oliveira and Fernandes (2009)."""
    space = {"name": "sRGB1+CVD", "cvd_type": kind, "severity": 100}
    return cspace_convert(rgb, space, "sRGB1").clip(0, 1)


def worst_delta(first, second):
    """Measure the difference through the vision that sees the least of it."""
    return min(
        deltaE(simulate(first, kind), simulate(second, kind), input_space="sRGB1")
        for kind in ("protanomaly", "deuteranomaly", "tritanomaly")
    )


def main():
    palette = read_palette()
    assignable = ["Rose", "Copper", "Olive", "Jade", "Cobalt"]
    axes = ["AxisX", "AxisY", "AxisZ"]

    print("assignable pairs (independent library)")
    for first, second in itertools.combinations(assignable, 2):
        difference = deltaE(palette[first], palette[second], input_space="sRGB1")
        print(
            f"  {first} vs {second:<8} ΔE {difference:7.2f}"
            f"  hue° {hue_distance(palette[first], palette[second]):7.2f}"
            f"  ΔE worst {worst_delta(palette[first], palette[second]):7.2f}"
        )

    print("\nassignable hues against the axis colours")
    for name in assignable:
        for axis in axes:
            difference = deltaE(palette[name], palette[axis], input_space="sRGB1")
            print(
                f"  {name} vs {axis:<6} ΔE {difference:7.2f}"
                f"  hue° {hue_distance(palette[name], palette[axis]):7.2f}"
            )

    print("\nassignable hues against the reserved magenta, worst vision")
    for name in assignable:
        print(f"  {name:<8} ΔE worst {worst_delta(palette[name], palette['Invalid']):7.2f}")


if __name__ == "__main__":
    main()

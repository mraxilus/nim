"""Build the marks page: every figure, every check, one file.

Run from the partnerwork directory:  python3 -m design  [output path]
"""
import sys

from .checks import check_frame, check_sign
from .page import render
from .parts import all_parts


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "design/marks.html"
    parts = all_parts()
    print(f"{len(parts)} pieces")
    check_frame()
    check_sign()
    html = render(parts)
    with open(out, "w") as f:
        f.write(html)
    print(f"written {len(html)} characters to {out}")


main()

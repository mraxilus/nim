"""Build both mark pages: every figure, every check, two files.

Run from the partnerwork directory:  python3 -m design  [output directory]
"""
import sys

from . import frame_page, sign_page
from .checks import check_frame, check_sign
from .parts import frame_parts, sign_parts


PAGES = (("frames.html", frame_parts, frame_page, check_frame),
         ("signs.html", sign_parts, sign_page, check_sign))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "design"
    for name, parts_of, page, check in PAGES:
        parts = parts_of()
        print(f"{name}: {len(parts)} pieces")
        check()
        html = page.render(parts)
        path = f"{out}/{name}"
        with open(path, "w") as f:
            f.write(html)
        print(f"  written {len(html)} characters to {path}")


main()

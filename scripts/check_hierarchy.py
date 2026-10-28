#!/usr/bin/env python3
"""Checks that Single Directory Components include only same-or-lower tiers.

Atomic Design's composition rule, applied to Twig: a component may include
components from its own tier's lower tiers, and organisms may also include
other organisms. The tier is the folder under components/ (atoms, molecules,
organisms, layouts). Includes are found in both Twig forms:
  {% include 'theme:name' ... %}   and   include('theme:name', ...)

Usage: check_hierarchy.py <theme>/components [<theme>/components ...]
Exit 0 clean, 1 findings (file:line: message), 2 usage error.
"""
import pathlib
import re
import sys

ORDER = {"atoms": 1, "molecules": 2, "organisms": 3, "layouts": 4}
SAME_TIER_ALLOWED = {"organisms", "layouts"}
INCLUDE = re.compile(r"""(?:\{%-?\s*(?:include|embed)\s+|include\(\s*)['"]([a-z0-9_]+):([a-z0-9-]+)['"]""")


def main(roots: list[str]) -> int:
    if not roots:
        print(__doc__, file=sys.stderr)
        return 2
    tiers: dict[str, str] = {}
    files: list[tuple[pathlib.Path, str]] = []
    for root in map(pathlib.Path, roots):
        if not root.is_dir():
            print(f"not a directory: {root}", file=sys.stderr)
            return 2
        for twig in root.glob("*/*/*.twig"):
            tier = twig.parent.parent.name
            if tier in ORDER:
                tiers[twig.parent.name] = tier
                files.append((twig, tier))
    findings = 0
    for twig, tier in files:
        for number, line in enumerate(twig.read_text().splitlines(), 1):
            for _theme, name in INCLUDE.findall(line):
                child = tiers.get(name)
                if child is None:
                    print(f"{twig}:{number}: includes unknown component '{name}'")
                    findings += 1
                elif ORDER[child] > ORDER[tier] or (child == tier and tier not in SAME_TIER_ALLOWED):
                    print(f"{twig}:{number}: {tier} '{twig.parent.name}' includes {child} '{name}'; a component may include only lower tiers")
                    findings += 1
    print(f"check_hierarchy: {findings} finding(s) in {len(files)} template(s)", file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

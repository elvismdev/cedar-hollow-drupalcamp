#!/usr/bin/env python3
"""Ports uclahs/surface's CSS into the cedar_hollow theme as standard CSS.

Surface (GPL-2.0-or-later) builds its CSS with PostCSS. This script makes the
mechanical changes needed to load the same files without a build step:

* @custom-media queries are expanded to the literal media queries in
  source/props/media.css.
* The five UCLA brand variables the components read are renamed to brand
  slots defined in the theme's css/props/brand.css, so a brand is swapped by
  editing one file.
* Each file is wrapped in the cascade layer of its Atomic Design tier.
* A header records the source file and commit.

It writes the initial port only. Later edits are made in the theme and are
visible in git as changes on top of the commit that added the port.

Usage: scripts/port-surface-css.py <path to a uclahs/surface clone>
"""

import pathlib
import re
import subprocess
import sys

COMMIT = "76e5dc6"
THEME = pathlib.Path(__file__).resolve().parent.parent / "web/themes/custom/cedar_hollow"
LAYERS = "@layer reset, tokens, base, atoms, components, collections, layouts, utilities;"

CUSTOM_MEDIA = {
    "--mobile-sm": "(width >= 400px)",
    "--mobile": "(width >= 640px)",
    "--tablet": "(width >= 768px)",
    "--laptop": "(width >= 1024px)",
    "--desktop": "(width >= 1280px)",
    "--desktop-large": "(width >= 1440px)",
    "--toolbar": "(width >= 976px)",
}

BRAND = {
    "--ucla-blue": "--brand-primary",
    "--silver-lake-reservoir": "--brand-primary-dark",
    "--midnight-joshua-tree": "--brand-primary-darkest",
    "--ucla-yellow": "--brand-accent",
    "--chumash-soil": "--brand-accent-dark",
}

# Source path in Surface -> (destination in the theme, cascade layer).
FILES = {
    **{
        f"source/props/{name}.css": (f"css/props/{name}.css", "tokens")
        for name in ["animations", "aspects", "borders", "colors", "easing", "fonts", "shadows", "sizes", "zindex"]
    },
    "source/patterns/base/utilities/reset.css": ("css/reset.css", "reset"),
    "source/patterns/base/utilities/prose.css": ("css/prose.css", "base"),
    "source/patterns/elements/button/button.css": ("components/atoms/button/button.css", "atoms"),
    "source/patterns/elements/date/date.css": ("components/atoms/date/date.css", "atoms"),
    "source/patterns/elements/date-badge/date-badge.css": ("components/atoms/date-badge/date-badge.css", "atoms"),
    "source/patterns/elements/eyebrow/eyebrow.css": ("components/atoms/eyebrow/eyebrow.css", "atoms"),
    "source/patterns/elements/readtime/readtime.css": ("components/atoms/readtime/readtime.css", "atoms"),
    "source/patterns/elements/breadcrumb/breadcrumb.css": ("components/atoms/breadcrumb/breadcrumb.css", "atoms"),
    "source/patterns/components/card/card.css": ("components/molecules/card/card.css", "components"),
    "source/patterns/components/featured-card/featured-card.css": ("components/molecules/featured-card/featured-card.css", "components"),
    "source/patterns/components/callout/callout.css": ("components/molecules/callout/callout.css", "components"),
    "source/patterns/components/quote/quote.css": ("components/molecules/quote/quote.css", "components"),
    "source/patterns/layouts/block/block.css": ("css/block.css", "layouts"),
}


def port(text: str, source: str, layer: str) -> str:
    for name, query in CUSTOM_MEDIA.items():
        text = re.sub(r"\(\s*" + re.escape(name) + r"\s*\)", query, text)
    for old, new in BRAND.items():
        text = re.sub(re.escape(old) + r"(?![a-z0-9-])", new, text)
    leftover = re.findall(r"@media[^{]*\(--[a-z-]+\)", text)
    if leftover:
        raise SystemExit(f"{source}: unexpanded custom media {leftover}")

    # Keep a leading file comment above the layer block.
    header = ""
    match = re.match(r"\s*(/\*\*.*?\*/)\s*", text, re.S)
    if match:
        header, text = match.group(1), text[match.end():]
    body = "\n".join(("  " + line) if line.strip() else "" for line in text.rstrip().splitlines())
    credit = f"/* Ported from uclahs/surface {source} at {COMMIT} (GPL-2.0-or-later). */"
    parts = [p for p in [header, credit, LAYERS, f"@layer {layer} {{\n{body}\n}}"] if p]
    return "\n\n".join(parts) + "\n"


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    surface = pathlib.Path(sys.argv[1])
    head = subprocess.run(["git", "-C", str(surface), "rev-parse", "--short", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    if not head.startswith(COMMIT):
        raise SystemExit(f"Surface clone is at {head}; this port is pinned to {COMMIT}.")
    for source, (dest, layer) in FILES.items():
        target = THEME / dest
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(port((surface / source).read_text(), source, layer))
        print(f"{source} -> {dest}")


if __name__ == "__main__":
    main()

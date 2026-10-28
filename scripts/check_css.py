#!/usr/bin/env python3
"""Fail on CSS that is not standard, build-free, BEM-friendly CSS.

Usage: check_css.py <dir-or-file> [<dir-or-file> ...]

Exit status: 0 clean, 1 findings, 2 usage error.

Rules:
  sass            Sass/SCSS syntax ($vars, @mixin/@include/@extend/@use/...,
                  #{} interpolation, // comments, &__ / &-- concatenation,
                  %placeholder selectors)
  custom-media    @custom-media or a media query using (--name)
  import-glob     @import-glob, or @import of a path containing *
  tailwind        @tailwind, @apply and the Tailwind v4 directives
                  (@theme, @utility, @variant, @custom-variant, @config,
                  @plugin, @source, @reference)
  depth           a resolved selector with more than 3 compound parts
  id              an ID selector
  important       !important outside an @layer named "utilities"
"""

import os
import re
import sys

MAX_COMPOUNDS = 3
UTILITIES_LAYER = "utilities"

SASS_AT_RULES = {
    "mixin", "include", "extend", "use", "forward", "if", "else", "each",
    "for", "while", "function", "return", "debug", "warn", "error", "at-root",
    "content",
}
TAILWIND_AT_RULES = {
    "tailwind", "apply", "theme", "utility", "variant", "custom-variant",
    "config", "plugin", "source", "reference",
}
# At-rules whose block holds rules and does not change the selector context.
TRANSPARENT_AT_RULES = {
    "media", "supports", "container", "layer", "scope", "starting-style",
    "document",
}
# At-rules whose block holds declarations or keyframe selectors only.
NON_SELECTOR_AT_RULES = {
    "keyframes", "-webkit-keyframes", "font-face", "property", "page",
    "counter-style", "font-feature-values", "font-palette-values",
    "view-transition", "position-try",
}


def mask(text):
    """Blank comments, strings and url() bodies, keeping offsets and lines."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end == -1 else end + 2
            out.append(re.sub(r"[^\n]", " ", text[i:end]))
            i = end
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append(c + re.sub(r"[^\n]", "x", text[i + 1:j - 1]) + c)
            i = j
        elif text[i:i + 4].lower() == "url(":
            end = text.find(")", i)
            end = n if end == -1 else end + 1
            out.append("url(" + re.sub(r"[^\n]", "x", text[i + 4:end - 1]) + ")")
            i = end
        else:
            out.append(c)
            i += 1
    return "".join(out)


def split_top(s, sep=","):
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return [p.strip() for p in parts if p.strip()]


def strip_groups(sel):
    """Remove the contents of (...) and [...] so only the outer compounds count."""
    out, depth = [], 0
    for ch in sel:
        if ch in "([":
            if depth == 0:
                out.append(ch)
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth == 0:
                out.append(ch)
        elif depth == 0:
            out.append(ch)
    return "".join(out)


def compound_count(sel):
    s = strip_groups(sel)
    s = re.sub(r"\s*[>+~]\s*", " ", s)
    return len([p for p in s.split() if p])


def resolve(parents, sel):
    if not parents:
        return [sel]
    out = []
    for p in parents:
        if "&" in sel:
            out.append(sel.replace("&", p))
        else:
            out.append(p + " " + sel)
    return out


def check_file(path):
    findings = []
    raw = open(path, encoding="utf-8", errors="replace").read()
    text = mask(raw)

    def line_of(pos):
        return text.count("\n", 0, pos) + 1

    def add(pos, rule, msg):
        findings.append((path, line_of(pos), rule, msg))

    # Line-level Sass markers.
    for m in re.finditer(r"(?<![:\w])//", text):
        add(m.start(), "sass", "// line comment is Sass syntax, not CSS")
    for m in re.finditer(r"#\{", text):
        add(m.start(), "sass", "#{} interpolation is Sass syntax")
    # Blank // comments so the text after them parses as the next statement.
    text = re.sub(r"(?<![:\w])//[^\n]*", lambda m: " " * len(m.group(0)), text)

    # Each frame: (kind, selectors, layers) where kind is rule/at/nosel.
    stack = []
    buf_start = 0
    i = 0
    n = len(text)

    def current_selectors():
        for frame in reversed(stack):
            if frame[0] == "rule":
                return frame[1]
        return []

    def in_utilities():
        for frame in stack:
            for layer in frame[2]:
                if layer == UTILITIES_LAYER or layer.endswith("." + UTILITIES_LAYER):
                    return True
        return False

    def in_non_selector():
        return any(f[0] == "nosel" for f in stack)

    def statement(chunk, pos):
        s = chunk.strip()
        if not s:
            return
        at = re.match(r"@([\w-]+)", s)
        if at:
            name = at.group(1).lower()
            if name in TAILWIND_AT_RULES:
                add(pos, "tailwind", "@%s is a Tailwind directive" % name)
            elif name in SASS_AT_RULES:
                add(pos, "sass", "@%s is Sass syntax" % name)
            elif name == "custom-media":
                add(pos, "custom-media", "@custom-media needs a build step")
            elif name == "import-glob":
                add(pos, "import-glob", "@import-glob needs a build step")
            elif name == "import" and "*" in raw[pos:pos + len(chunk)]:
                add(pos, "import-glob", "@import of a glob needs a build step")
            return
        if re.match(r"\$[\w-]+\s*:", s):
            add(pos, "sass", "Sass variable declaration")
        elif re.search(r"(?<![\w-])\$[A-Za-z_][\w-]*", s):
            add(pos, "sass", "Sass variable reference")
        if re.search(r"!\s*important", s, re.I) and not in_utilities():
            add(pos, "important", "!important outside @layer utilities")

    while i < n:
        ch = text[i]
        if ch == ";":
            chunk = text[buf_start:i]
            statement(chunk, buf_start + (len(chunk) - len(chunk.lstrip())))
            buf_start = i + 1
        elif ch == "{":
            chunk = text[buf_start:i]
            pos = buf_start + (len(chunk) - len(chunk.lstrip()))
            prelude = " ".join(chunk.split())
            at = re.match(r"@([\w-]+)\s*(.*)", prelude)
            if at:
                name, rest = at.group(1).lower(), at.group(2)
                layers = []
                if name in TAILWIND_AT_RULES:
                    add(pos, "tailwind", "@%s is a Tailwind directive" % name)
                elif name in SASS_AT_RULES:
                    add(pos, "sass", "@%s is Sass syntax" % name)
                if name == "media" and re.search(r"\(\s*--", rest):
                    add(pos, "custom-media", "custom media query (--name) needs a build step")
                if name == "layer":
                    layers = [x.strip() for x in rest.split(",") if x.strip()]
                if name in NON_SELECTOR_AT_RULES:
                    stack.append(("nosel", [], layers))
                else:
                    stack.append(("at", [], layers))
            elif in_non_selector():
                stack.append(("nosel", [], []))
            else:
                selectors = split_top(prelude)
                resolved = []
                for sel in selectors:
                    if re.match(r"%[\w-]", sel):
                        add(pos, "sass", "%%placeholder selector is Sass syntax: %s" % sel)
                    if re.search(r"&[\w-]", sel):
                        add(pos, "sass", "&-suffix concatenation is Sass syntax: %s" % sel)
                    if re.search(r"#[A-Za-z_\\-]", strip_groups(sel)) or re.search(r"\(\s*[^)]*#[A-Za-z_\\-]", sel):
                        add(pos, "id", "ID selector: %s" % sel)
                    resolved.extend(resolve(current_selectors(), sel))
                for full in resolved:
                    count = compound_count(full)
                    if count > MAX_COMPOUNDS:
                        add(pos, "depth", "%d compound parts (max %d): %s" % (count, MAX_COMPOUNDS, full))
                stack.append(("rule", resolved, []))
            buf_start = i + 1
        elif ch == "}":
            chunk = text[buf_start:i]
            statement(chunk, buf_start + (len(chunk) - len(chunk.lstrip())))
            if stack:
                stack.pop()
            buf_start = i + 1
        i += 1
    statement(text[buf_start:], buf_start)
    return findings


def collect(args):
    files = []
    for a in args:
        if os.path.isdir(a):
            for root, _dirs, names in os.walk(a):
                if "node_modules" in root.split(os.sep):
                    continue
                files.extend(os.path.join(root, f) for f in sorted(names) if f.endswith(".css"))
        elif os.path.isfile(a):
            files.append(a)
        else:
            print("check_css: no such file or directory: %s" % a, file=sys.stderr)
            sys.exit(2)
    return sorted(files)


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    files = collect(argv[1:])
    findings = []
    for f in files:
        findings.extend(check_file(f))
    for path, line, rule, msg in findings:
        print("%s:%d: [%s] %s" % (path, line, rule, msg))
    print("check_css: %d finding(s) in %d file(s) scanned" % (len(findings), len(files)))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

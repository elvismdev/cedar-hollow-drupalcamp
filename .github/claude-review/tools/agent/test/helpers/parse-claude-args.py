#!/usr/bin/env python3
"""Parse a claude_args string the way claude-code-action parses it.

Mirrors parseClaudeArgsToExtraArgs and the tool-list merge in parseSdkOptions
(base-action/src/parse-sdk-options.ts at ae68417): the string is split into
words with shell quoting (shell-quote's parse, after full-line # comments are
dropped and ( ) | & ; < > are kept literal), then each --flag takes the next
word as its value unless that word starts with --. allowedTools,
disallowedTools and add-dir accumulate: they take every following word up to
the next --flag. The allowed and disallowed lists are then split on commas,
trimmed and deduplicated in order; the add-dir values become one entry each.

shlex in POSIX mode splits quotes and whitespace the way shell-quote does for
the strings tested here, which hold no comment, variable or escape sequence.

Usage: parse-claude-args.py '<claude_args>'  ->  JSON object of the result:
  {"flags": {flag: value-or-null}, "allowedTools": [...],
   "disallowedTools": [...], "addDirs": [...]}
"""
import json
import shlex
import sys

ACCUMULATING = {"allowedTools", "allowed-tools", "disallowedTools", "disallowed-tools", "add-dir"}


def parse(text):
    text = "\n".join(line for line in text.split("\n") if not line.strip().startswith("#"))
    words = shlex.split(text, comments=False, posix=True)
    flags = {}
    i = 0
    while i < len(words):
        word = words[i]
        if word.startswith("--"):
            flag = word[2:]
            nxt = words[i + 1] if i + 1 < len(words) else None
            if nxt and not nxt.startswith("--"):
                if flag in ACCUMULATING:
                    values = []
                    while i + 1 < len(words) and not words[i + 1].startswith("--"):
                        i += 1
                        values.append(words[i])
                    # As the action does: append to earlier values, or start
                    # afresh when the flag was absent or seen bare (null).
                    flags[flag] = (flags.get(flag) or []) + values
                else:
                    flags[flag] = nxt
                    i += 1
            else:
                flags[flag] = None
        i += 1

    def tools(*names):
        out = []
        for name in names:
            for value in flags.pop(name, None) or []:
                for tool in value.split(","):
                    tool = tool.strip()
                    if tool and tool not in out:
                        out.append(tool)
        return out

    result = {
        "allowedTools": tools("allowedTools", "allowed-tools"),
        "disallowedTools": tools("disallowedTools", "disallowed-tools"),
        "addDirs": [d.strip() for d in flags.pop("add-dir", None) or [] if d.strip()],
    }
    result["flags"] = flags
    return result


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: parse-claude-args.py '<claude_args>'", file=sys.stderr)
        sys.exit(2)
    print(json.dumps(parse(sys.argv[1])))

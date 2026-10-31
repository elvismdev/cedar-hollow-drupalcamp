#!/usr/bin/env python3
"""Parse a $GITHUB_OUTPUT / $GITHUB_ENV file the way the Actions runner does.

The runner reads a `name<<DELIM` line, then consumes lines until one that
ordinally equals DELIM, and raises only if the end of file arrives first. It
does NOT check whether the value contains the delimiter, so a value carrying
that line terminates the assignment early and whatever follows is parsed as
further assignments. That asymmetry is the whole point of this helper: a test
asserting "the value round-tripped" has to parse the file the way the consumer
does, not the way the producer intended.

Source: actions/runner, EnvFileKeyValuePairs.GetEnumerator, which loops
`while (!string.Equals(tempLine, delimiter, StringComparison.Ordinal))` and
throws "Invalid value. Matching delimiter not found" on EOF.

Usage: parse-env-file.py <file>   ->  JSON object of the resulting assignments
Exits 1 with the runner's message when a delimiter is never closed.
"""
import json
import sys


def parse(text):
    pairs = {}
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        line = lines[i]
        if '<<' in line:
            name, delim = line.split('<<', 1)
            if not name or not delim:
                print('Invalid format', file=sys.stderr)
                sys.exit(1)
            i += 1
            buf = []
            while i < len(lines) and lines[i] != delim:
                buf.append(lines[i])
                i += 1
            if i >= len(lines):
                print(f"Invalid value. Matching delimiter not found '{delim}'",
                      file=sys.stderr)
                sys.exit(1)
            pairs[name] = '\n'.join(buf)
            i += 1
        elif '=' in line:
            name, value = line.split('=', 1)
            pairs[name] = value
            i += 1
        else:
            i += 1
    return pairs


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('usage: parse-env-file.py <file>', file=sys.stderr)
        sys.exit(2)
    with open(sys.argv[1]) as fh:
        print(json.dumps(parse(fh.read())))

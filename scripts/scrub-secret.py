#!/usr/bin/env python3
"""Remove a secret from files before they are uploaded as an artifact.

Usage: scrub-secret.py --env NAME PATH [PATH ...]

The secret is read from the environment variable NAME, never from the command
line, so it does not appear in the process list. Every file under each PATH is
rewritten with each spelling of the secret replaced by "[redacted]": the plain
value, the value as escaped inside a JSON string, and the value
percent-encoded. A PATH that does not exist is skipped.

Zip and gzip archives (Playwright traces are zips) are deleted instead: their
entries are compressed, so the secret can be neither found nor replaced in
their bytes. Other binary files, such as screenshots, are scanned and
rewritten byte for byte like text.

After rewriting, every remaining file is read again. If any still holds the
secret, or a file could not be read, rewritten or deleted, the files concerned
are listed and the exit status is 1, so a step that uploads only on success
never uploads them. The secret itself is never printed.

Exit status: 0 clean, 1 a file still holds the secret or could not be handled,
2 usage error (no --env, or the variable is not set). A variable that is set
but empty means there is no secret to remove, which is not an error.
"""

import argparse
import json
import os
import sys
import urllib.parse

REDACTED = b"[redacted]"
ARCHIVE_MAGIC = (b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08", b"\x1f\x8b")


def spellings(secret):
    forms = {
        secret,
        json.dumps(secret)[1:-1],
        urllib.parse.quote(secret, safe=""),
    }
    # Longest first, so a spelling that contains another is replaced whole.
    return sorted((f.encode() for f in forms), key=len, reverse=True)


def files_under(paths):
    for path in paths:
        if os.path.isfile(path):
            yield path
        elif os.path.isdir(path):
            for dirpath, _dirnames, filenames in os.walk(path):
                for name in sorted(filenames):
                    yield os.path.join(dirpath, name)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--env", required=True, help="variable holding the secret")
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args(argv)

    if args.env not in os.environ:
        print(f"scrub-secret: {args.env} is not set", file=sys.stderr)
        return 2
    secret = os.environ[args.env]
    if not secret:
        print(f"scrub-secret: {args.env} is empty, nothing to remove")
        return 0
    forms = spellings(secret)

    problems = []
    scrubbed = 0
    for path in list(files_under(args.paths)):
        try:
            with open(path, "rb") as handle:
                data = handle.read()
            if data.startswith(ARCHIVE_MAGIC):
                os.remove(path)
                print(f"scrub-secret: removed archive {path}")
                continue
            clean = data
            for form in forms:
                clean = clean.replace(form, REDACTED)
            if clean != data:
                with open(path, "wb") as handle:
                    handle.write(clean)
                scrubbed += 1
        except OSError as error:
            problems.append(f"{path}: {error.strerror or error}")

    for path in files_under(args.paths):
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError as error:
            problems.append(f"{path}: {error.strerror or error}")
            continue
        if any(form in data for form in forms):
            problems.append(f"{path}: still holds the secret")

    if problems:
        print("scrub-secret: these files must not be uploaded:", file=sys.stderr)
        for problem in sorted(set(problems)):
            print(f"  {problem}", file=sys.stderr)
        return 1
    print(f"scrub-secret: removed the secret from {scrubbed} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

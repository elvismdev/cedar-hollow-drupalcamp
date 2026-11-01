# Shared by merge-records.py and render-issue.py: the names of the files in a
# state directory, the fingerprint pattern, and the strict reader every state
# file, agent entry and run record goes through. Both scripts load this file by
# its path next to them, so it works under python3 -I, which ignores
# PYTHONPATH and the script's directory.
#
# The reader opens without following a symlink at the leaf, accepts only a
# regular file with one link and at most the given number of bytes, refuses a
# file that changes while it is read, and parses one JSON value with no
# duplicate keys, NaN, Infinity or nesting deep enough to exhaust recursion.
import errno
import json
import os
import re
import stat

FINDINGS = "findings.json"
LEDGER = "coverage-ledger.json"
METADATA = "run-metadata.json"
DISPUTED = "disputed.json"
HISTORY = "audit-history.json"
# Bookkeeping only merge-records.py writes; check-agent-run.sh refuses any
# agent write to a file of this name.
TRUSTED_META = "trusted-meta.json"

FINGERPRINT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$")


class Refused(Exception):
    """A file or argument that cannot be used safely."""


def _reject_constant(name):
    raise ValueError("non-finite number")


def _unique_pairs(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError("duplicate key")
        out[key] = value
    return out


def parse_strict(data):
    """One JSON value from UTF-8 bytes: no duplicate keys, NaN or Infinity."""
    text = data.decode("utf-8")
    try:
        return json.loads(text, object_pairs_hook=_unique_pairs, parse_constant=_reject_constant)
    except RecursionError:
        raise ValueError("nested too deeply")


def read_fd(fd, limit):
    """Reads a regular file with one link and at most limit bytes from an open
    descriptor, refusing one that changes while it is read. Returns the bytes."""
    before = os.fstat(fd)
    if not stat.S_ISREG(before.st_mode):
        raise Refused("not a regular file")
    if before.st_nlink != 1:
        raise Refused("hardlinked")
    if before.st_size > limit:
        raise Refused("oversized")
    chunks, total = [], 0
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise Refused("oversized")
        chunks.append(chunk)
    after = os.fstat(fd)
    if (after.st_dev, after.st_ino, after.st_nlink, after.st_size, stat.S_IFMT(after.st_mode)) != (
        before.st_dev, before.st_ino, before.st_nlink, before.st_size, stat.S_IFMT(before.st_mode)
    ) or total != before.st_size:
        raise Refused("changed while read")
    return b"".join(chunks)


def open_nofollow(path, dir_fd=None):
    try:
        return os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    except OSError as err:
        if err.errno in (errno.ELOOP, errno.EMLINK):
            raise Refused("symlink")
        raise


def read_bytes(path, limit, dir_fd=None):
    fd = open_nofollow(path, dir_fd)
    try:
        return read_fd(fd, limit)
    finally:
        os.close(fd)


def read_json(path, limit, dir_fd=None):
    return parse_strict(read_bytes(path, limit, dir_fd))

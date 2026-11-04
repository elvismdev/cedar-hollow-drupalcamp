# How Claude Code 2.1.316's Glob tool splits an absolute pattern into the
# folder it searches and the glob it hands ripgrep, read from its code: the
# pattern up to the last / before the first *, ?, [ or { is the folder (/ when
# that is the first character), the rest is the glob, and a pattern with none
# of those characters is split by Node's dirname and basename, which ignore
# trailing slashes. check-trace-tools.sh judges an absolute Glob pattern
# through this function; glob-split-corpus.json holds splits measured from the
# binary that the test suite and the ripgrep canary check it against.
import posixpath
import re

GLOB_META = re.compile(r'[*?\[{]')


def split(pattern):
    """(folder searched, glob) for an absolute Glob pattern."""
    m = GLOB_META.search(pattern)
    if m is None:
        trimmed = pattern.rstrip('/') or '/'
        return posixpath.dirname(trimmed), posixpath.basename(trimmed)
    cut = pattern.rfind('/', 0, m.start())
    return pattern[:cut] or '/', pattern[cut + 1:]

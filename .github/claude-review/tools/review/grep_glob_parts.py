# How Claude Code turns a Grep tool's glob field into ripgrep --glob
# arguments, read from its 2.1.309 and 2.1.316 code: split on whitespace, then
# split each piece on commas unless it holds a brace group ("{" and "}"),
# which stays whole, and drop empty pieces. check-trace-tools.sh judges these
# parts and check-trace-tools-ripgrep.test.sh passes them to ripgrep, both
# through this one function.


def parts(value):
    """The globs Claude Code passes to ripgrep for a Grep glob value."""
    found = []
    for piece in value.split():
        if '{' in piece and '}' in piece:
            found.append(piece)
        else:
            found.extend(t for t in piece.split(',') if t)
    return found

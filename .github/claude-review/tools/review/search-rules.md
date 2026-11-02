## How to search

A check reads every Read, Glob and Grep call you make after you finish, and
fails the whole review if one breaks these rules, so keep to them:

- A `file_path` or `path` uses only letters, digits and `. _ / @ + -`, and
  never `..`, `~` or `.git`.
- A Glob `pattern` is relative and uses only those characters plus `* { } ,`.
- A Grep `glob` uses only letters, digits and `. _ / @ + - * { } ,`. Never use
  `!`, `?`, `[`, `]` or a space, so never write a negated glob such as
  `!**/node_modules/**`; narrow the search with `path` instead.
- A Grep with no `path`, or with a `path` in your working directory, takes a
  `glob` only when no part of it can match the name `.git`: the part after
  its last `/` must not be `*`, `**`, `*.*` or match `.git` (such as `.git*`
  or `*.git`), and no other part may match `.git` either. So `*.php`,
  `*gitignore*`, `{.gitignore,composer.json}` and `src/{a,b}/*.yml` work,
  and `*`, `**` and `src/**` do not. To search every file in one folder, put
  the folder in `path` and leave `glob` out.

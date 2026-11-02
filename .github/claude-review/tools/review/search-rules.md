## How to search

A check reads every Read, Glob and Grep call you make after you finish, and
fails the whole review if one breaks these rules, so keep to them:

- A `file_path` or `path` uses only letters, digits and `. _ / @ + -`, and
  never `..`, `~` or `.git`.
- A Glob `pattern` is relative and uses only those characters plus `* { } ,`.
- A Grep `glob` uses only letters, digits and `. _ / @ + - * { } ,`. Never use
  `!`, `?`, `[`, `]` or a space, so never write a negated glob such as
  `!**/node_modules/**`; narrow the search with `path` instead.
- A Grep with no `path`, or with a `path` in your working directory, takes
  folder and brace globs (`src/**/*.php`, `{web/modules/*.php,tests/*.php}`,
  `*gitignore*`, `{.gitignore,composer.json}`), but a glob is refused when any
  segment of it, or of a comma or brace alternative, can match `.git`
  (`.git`, `.git*`, `*.git`, `*`, `*.*`), when it ends in `**`, holds `..`,
  or starts with `!`. So `*`, `**` and `src/**` are refused. Name the folder
  instead of a bare `*` segment: `web/modules/*.php`, not `*/x.php`. To
  search every file in one folder, put the folder in `path` and leave `glob`
  out.

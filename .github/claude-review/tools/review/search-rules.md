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
  folder and brace globs (`src/**/*.php`, `{scripts/*,web/modules/custom/**}`,
  `*/x.php`, `*gitignore*`, `{.gitignore,composer.json}`), but a glob is
  refused when, read whole, it could match the `.git` folder: with no `/` it
  must not match the name `.git` (`*`, `**`, `.g*`, `*.git`), and with a `/`
  it must not match `.git` itself or name `.git` on the way to a path inside
  it (`**/*`, `**/.git`, `.git/config`, `**/.git/**`). Each comma part and
  brace alternative is judged on its own, and `..` or a leading `!` is
  refused. To search every file in one folder, put the folder in `path` and
  leave `glob` out.

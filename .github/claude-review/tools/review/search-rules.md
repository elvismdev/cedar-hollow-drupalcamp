## How to search

A check reads every Read, Glob and Grep call you make after you finish, and
fails the whole review if one breaks these rules, so keep to them:

- A `file_path` or `path` uses only letters, digits and `. _ / @ + -`, and
  never `..`, `~` or `.git`.
- A Glob `pattern` is relative and uses only those characters plus `* { } ,`.
- A Grep `glob` uses only letters, digits and `. _ / @ + - * { } ,`. Never use
  `?`, `[`, `]` or a space, and use `!` only as the first character of a
  comma part: such a part (`!**/node_modules/**`) only excludes files and
  works from any `path`. A glob holding a brace group is not split on
  commas, so it must not also have a comma outside its braces: write
  `!{vendor,node_modules}/**` or `src/**/*.php,!vendor/**`, not
  `src/**/*.php,{web,docs}/**` or `src/**/*.php,!{vendor,node_modules}/**`.
- A Grep with no `path`, or with a `path` in your working directory, takes
  folder and brace globs (`src/**/*.php`, `{scripts/*,web/modules/custom/**}`,
  `*/x.php`, `*gitignore*`, `{.gitignore,composer.json}`), but a glob is
  refused when, read whole, it could match the `.git` folder: with no `/` it
  must not match the name `.git` (`*`, `**`, `.g*`, `*.git`), and with a `/`
  it must not match `.git` itself or name `.git` on the way to a path inside
  it (`**/*`, `**/.git`, `.git/config`, `**/.git/**`). Each other comma part
  and brace alternative is judged on its own, so `!web/**,*` is refused for
  its `*` part; `..` is refused, and so is a `!` anywhere but the start of a
  part (`{!a,b}`), and so is a `path` that passes through a symbolic link or is not
  in normal form (`//`, `/./`, a trailing `/.`): give a path inside the
  checkout that does not pass through a symbolic link. To search every file
  in one folder, put the folder in `path` and leave `glob` out.
- Keep each search's output small: use `head_limit`, `output_mode`
  `files_with_matches`, or a narrower `path` or `glob`. An output over about
  20,000 characters is saved to a file you cannot read, so you lose it and
  have to search again.

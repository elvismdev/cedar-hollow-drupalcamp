## How to search

A check reads every Read, Glob and Grep call you make after you finish, and
fails the whole review if one breaks these rules, so keep to them:

- A `file_path` or `path` uses only letters, digits and `. _ / @ + -`, and
  never `..`, `~` or `.git`.
- A Glob `pattern` uses only those characters plus `* { } ,`. A relative
  pattern is searched from the `path`. An absolute pattern ignores the `path`
  and is searched from its folder before the first `*` or `{`, so it is
  judged like a path: no `//`, `.` or `..` segment and no trailing `/`, that
  folder and every brace alternative inside the allowed folders, never
  through a symbolic link, and from the checkout's top level or a folder
  above it, it is refused when its glob could list `.git` (a glob with no
  `/` matches names at any depth there): `<checkout>/src/*.php` passes,
  `<checkout>/*.php` and `<checkout>/*/config` do not; use `src/*.php`
  relative instead. A pattern with no `*` or `{` is searched from its
  folder too and matches its last name at any depth, so from the checkout's
  top level name a subfolder: `<checkout>/src/x.php`, not
  `<checkout>/x.php`.
- A Grep `glob` uses only letters, digits and `. _ / @ + - * { } ,`. Never use
  `?`, `[`, `]` or a space, and use `!` only as the first character of a
  comma part: such a part (`!**/node_modules/**`) only excludes files and
  works from any `path`. A glob holding a brace group is not split on
  commas, so do not also put a comma outside its braces: ripgrep then reads
  that comma, and any `!` after the first character, as a literal character,
  and the glob matches nothing you meant (the check warns about it rather
  than failing). Write `!{vendor,node_modules}/**` or `src/**/*.php,!vendor/**`, not
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
  part (`{!a,b}`), except in a whole glob with a comma outside its braces,
  where it is a literal character and the glob is only warned about; and so
  is a `path` that passes through a symbolic link or is not
  in normal form (`//`, `/./`, a trailing `/.`): give a path inside the
  checkout that does not pass through a symbolic link. To search every file
  in one folder, put the folder in `path` and leave `glob` out.
- Keep each search's output small: use `head_limit`, `output_mode`
  `files_with_matches`, or a narrower `path` or `glob`. An output over about
  20,000 characters is saved to a file you cannot read, so you lose it and
  have to search again.

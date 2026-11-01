#!/usr/bin/env bash
# Tests for run-in-sandbox.sh: what the sandbox must block and what it must
# allow, the run record's shape, and, on a fixture site built here with
# rebuild.sh on SQLite, both modes, a fixture script, an HTTP login with a
# test account from create-test-accounts.php, and an unchanged site directory.
#
# Cases that need a capability this machine lacks print a SKIP line naming it.
# Under CI (CI=true) a missing capability fails the suite instead, so the
# cases always run there.
set -euo pipefail
# shellcheck source=../../claude-review/tools/agent/test/assert.sh
. "$(dirname "$0")/../../claude-review/tools/agent/test/assert.sh"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SA="$ROOT/.github/security-audit"
RUN="$SA/run-in-sandbox.sh"
WORK="$(mktemp -d)"
WT="$WORK/wt"
cleanup() {
  if [ -d "$WT" ]; then
    chmod -R u+w "$WT/web/sites/default" 2>/dev/null || true
    git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null || true
  fi
  # The installer leaves sites/default read-only, in the worktree and its copy.
  chmod -R u+w "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
  git -C "$ROOT" worktree prune
}
trap cleanup EXIT

skip_or_fail() { # reason
  if [ "${CI:-}" = true ]; then echo "FAIL: $1" >&2; exit 1; fi
  echo "SKIP: $1"
}
token() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
field() { jq -r "$1" "$2"; }

# Usage errors need no sandbox.
printf '<?php\n' > "$WORK/empty.php"
mkdir -p "$WORK/empty-site"
for args in "fp c drush $WORK/empty-site $WORK/empty.php" "fp a shell $WORK/empty-site $WORK/empty.php" \
            "fp a drush $WORK/no-site $WORK/empty.php" "fp a drush $WORK/empty-site $WORK/no-script.php" \
            "fp a drush" " a drush $WORK/empty-site $WORK/empty.php"; do
  rc=0
  # shellcheck disable=SC2086
  bash "$RUN" $args > /dev/null 2>&1 || rc=$?
  assert_exit 2 "$rc" "usage error for: $args"
done
rc=0
bash "$RUN" "" a drush "$WORK/empty-site" "$WORK/empty.php" > /dev/null 2>&1 || rc=$?
assert_exit 2 "$rc" "an empty fingerprint is a usage error"

# Capabilities.
sandbox_ok=1
for tool in bwrap prlimit timeout jq php; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    skip_or_fail "$tool is not installed; sandbox cases not run"; sandbox_ok=""; break
  fi
done
if [ -n "$sandbox_ok" ] && ! bwrap --help 2>&1 | grep -q -- '--size' && ! sudo -n true 2> /dev/null; then
  skip_or_fail "bubblewrap $(bwrap --version | cut -d' ' -f2) has no --size and sudo is not passwordless, so /work cannot be size-limited; sandbox cases not run"
  sandbox_ok=""
fi
if [ -n "$sandbox_ok" ] && ! bwrap --unshare-all --ro-bind /usr /usr --symlink usr/lib /lib \
    --symlink usr/lib64 /lib64 --symlink usr/bin /bin /usr/bin/true 2> /dev/null; then
  skip_or_fail "bubblewrap cannot create unprivileged namespaces here; sandbox cases not run"
  sandbox_ok=""
fi
# RLIMIT_NPROC counts every task (threads included) of the user, outside the
# sandbox too, so the 256 limit leaves room only when the user runs fewer.
tasks="$(ps -u "$(id -u)" -L --no-headers | wc -l | tr -d ' ')"
echo "Tasks of this user before the sandbox runs: $tasks"
if [ -n "$sandbox_ok" ] && [ "$tasks" -ge 200 ]; then
  skip_or_fail "this user already runs $tasks tasks, too close to the sandbox's 256 process limit for it to start; sandbox cases not run"
  sandbox_ok=""
fi
site_ok=1
if ! command -v composer > /dev/null 2>&1 || ! command -v php > /dev/null 2>&1 \
    || ! php -r 'exit(PHP_VERSION_ID >= 80300 && extension_loaded("pdo_sqlite") ? 0 : 1);'; then
  skip_or_fail "PHP 8.3 or later with pdo_sqlite, and composer, are needed to build the fixture site ($(php -r 'echo PHP_VERSION, " pdo_sqlite=", extension_loaded("pdo_sqlite") ? "yes" : "no";' 2> /dev/null || echo 'no php')); fixture site cases not run"
  site_ok=""
fi

run() { # name slot mode site script [fixture]: writes $WORK/<name>.json
  local name="$1"; shift
  bash "$RUN" "fp-$name" "$@" > "$WORK/$name.json"
}

if [ -n "$sandbox_ok" ]; then
  # A minimal site: drush php:script becomes a plain include, and the router
  # answers every request, so these cases do not depend on Drupal.
  STUB="$WORK/stub-site"
  mkdir -p "$STUB/vendor/bin" "$STUB/web"
  printf '<?php\nrequire $argv[2];\n' > "$STUB/vendor/bin/drush.php"
  printf '<?php\necho "router-ok\\n";\n' > "$STUB/web/.ht.router.php"

  # The record's shape, and a command run inside.
  printf '<?php\npassthru("php -r '\''echo 42;'\''", $rc);\nexit($rc);\n' > "$WORK/p42.php"
  run p42 a drush "$STUB" "$WORK/p42.php"
  assert_eq "exit_code fingerprint limits mode script_sha256 slot stderr stdout timed_out" \
    "$(jq -r 'keys | join(" ")' "$WORK/p42.json")" "the record has exactly the run record's keys"
  assert_eq "fp-p42 a drush" "$(jq -r '"\(.fingerprint) \(.slot) \(.mode)"' "$WORK/p42.json")" "the record echoes fingerprint, slot and mode"
  assert_eq "$(sha256sum "$WORK/p42.php" | cut -d' ' -f1)" "$(field .script_sha256 "$WORK/p42.json")" "script_sha256 is the script's sha256"
  assert_eq '{"address_space_bytes":2147483648,"cpu_seconds":60,"file_size_bytes":268435456,"processes":256,"timeout_seconds":120,"work_bytes":1073741824,"output_bytes":65536}' \
    "$(jq -c '.limits | del(.tmp_bytes)' "$WORK/p42.json")" "the record states the limits"
  assert_eq "42" "$(field .stdout "$WORK/p42.json")" "php -r 'echo 42;' prints 42"
  assert_eq "0 false" "$(jq -r '"\(.exit_code) \(.timed_out)"' "$WORK/p42.json")" "a clean run exits 0 without timing out"

  # Network: nothing outside, by name or by address. Loopback works (http cases below).
  cat > "$WORK/net.php" <<'EOF'
<?php
foreach (['https://example.com/', 'http://1.1.1.1/'] as $url) {
  $c = curl_init($url);
  curl_setopt_array($c, [CURLOPT_RETURNTRANSFER => TRUE, CURLOPT_CONNECTTIMEOUT => 5, CURLOPT_TIMEOUT => 10]);
  echo curl_exec($c) === FALSE ? "blocked $url\n" : "fetched $url\n";
}
EOF
  run net a drush "$STUB" "$WORK/net.php"
  assert_eq "blocked https://example.com/
blocked http://1.1.1.1/" "$(field .stdout "$WORK/net.json")" "an external curl fails, by name and by address"

  # Environment: an outside variable is absent, the sandbox's own are set.
  CANARY="$(token)"
  cat > "$WORK/env.php" <<'EOF'
<?php
echo json_encode(getenv()), "\n";
EOF
  AUDIT_SANDBOX_CANARY="$CANARY" run env a drush "$STUB" "$WORK/env.php"
  env_out="$(field .stdout "$WORK/env.json")"
  case "$env_out$(field .stderr "$WORK/env.json")" in
    *"$CANARY"*) echo "FAIL: an outside environment variable reached the sandbox" >&2; exit 1 ;;
  esac
  assert_eq "/work/home /work/tmp /usr/bin:/bin" "$(jq -r '"\(.HOME) \(.TMPDIR) \(.PATH)"' <<< "$env_out")" "HOME, TMPDIR and PATH are the sandbox's"

  # Filesystem: /usr is read-only and the outside home is absent; /work is writable.
  cat > "$WORK/fs.php" <<EOF
<?php
echo @file_put_contents('/usr/audit-canary', 'x') === FALSE ? "usr-write blocked\n" : "usr-write allowed\n";
echo @scandir('$HOME') === FALSE ? "home-read blocked\n" : "home-read allowed\n";
echo @file_put_contents('/work/audit-canary', 'x') === 1 ? "work-write allowed\n" : "work-write blocked\n";
EOF
  run fs a drush "$STUB" "$WORK/fs.php"
  assert_eq "usr-write blocked
home-read blocked
work-write allowed" "$(field .stdout "$WORK/fs.json")" "a write to /usr and a read of $HOME fail, a write to /work works"

  # Memory: 100 MiB is allowed, 3 GiB is stopped by the address space limit.
  cat > "$WORK/hog.php" <<'EOF'
<?php
ini_set('memory_limit', '-1');
$small = str_repeat('x', 100 * 1024 * 1024);
echo "small-ok\n";
$big = str_repeat('x', 3 * 1024 * 1024 * 1024);
echo "big-ok\n";
EOF
  run hog a drush "$STUB" "$WORK/hog.php"
  assert_eq "small-ok" "$(field .stdout "$WORK/hog.json")" "a memory hog is stopped after a small allocation works"
  assert_contains "$(field .stderr "$WORK/hog.json")" "Out of memory" "the memory hog's failure is recorded"
  [ "$(field .exit_code "$WORK/hog.json")" -ne 0 ] || { echo "FAIL: the memory hog exited 0" >&2; exit 1; }

  # Processes: a spawn loop stops at the process limit.
  cat > "$WORK/fork.php" <<'EOF'
<?php
$children = [];
$failed = FALSE;
for ($i = 0; $i < 600; $i++) {
  $p = @proc_open(['sleep', '60'], [], $pipes);
  if ($p === FALSE) { $failed = TRUE; break; }
  $children[] = $p;
}
echo 'spawned=' . count($children) . ' failed=' . ($failed ? 'yes' : 'no') . "\n";
EOF
  run fork a drush "$STUB" "$WORK/fork.php"
  fork_out="$(field .stdout "$WORK/fork.json")"
  assert_contains "$fork_out" "failed=yes" "a spawn loop is stopped"
  spawned="$(sed -n 's/^spawned=\([0-9]*\) .*/\1/p' <<< "$fork_out")"
  [ -n "$spawned" ] && [ "$spawned" -ge 1 ] && [ "$spawned" -lt 256 ] \
    || { echo "FAIL: spawned [$spawned] processes, expected 1 to 255" >&2; exit 1; }

  # File size: 100 MiB is allowed, a 300 MiB file is stopped at 256 MiB.
  cat > "$WORK/w300.php" <<'EOF'
<?php
$chunk = str_repeat('x', 1024 * 1024);
$f = fopen('/work/ok.bin', 'w');
for ($i = 0; $i < 100; $i++) { fwrite($f, $chunk); }
fclose($f);
echo "100mb-ok\n";
$f = fopen('/work/big.bin', 'w');
for ($i = 1; $i <= 300; $i++) { fwrite($f, $chunk); if ($i % 50 === 0) { echo "wrote=$i\n"; } }
fclose($f);
echo "300mb-done\n";
EOF
  run w300 a drush "$STUB" "$WORK/w300.php"
  assert_eq "100mb-ok
wrote=50
wrote=100
wrote=150
wrote=200
wrote=250" "$(field .stdout "$WORK/w300.json")" "a 300 MiB write is stopped past 250 MiB"
  [ "$(field .exit_code "$WORK/w300.json")" -ne 0 ] || { echo "FAIL: the 300 MiB write exited 0" >&2; exit 1; }

  # /work: files under the size limit fill it to about 1 GiB and no further.
  cat > "$WORK/fill.php" <<'EOF'
<?php
$chunk = str_repeat('x', 1024 * 1024);
$total = 0;
for ($n = 0; $n < 5; $n++) {
  $f = fopen("/work/fill$n.bin", 'w');
  for ($i = 0; $i < 250; $i++) {
    if (@fwrite($f, $chunk) !== strlen($chunk)) { echo "nospace total_mb=$total\n"; exit(4); }
    $total++;
  }
  fclose($f);
}
echo "filled total_mb=$total\n";
EOF
  run fill a drush "$STUB" "$WORK/fill.php"
  fill_out="$(field .stdout "$WORK/fill.json")"
  assert_contains "$fill_out" "nospace" "a write past 1 GiB into /work is stopped"
  fill_mb="$(sed -n 's/^nospace total_mb=\([0-9]*\)$/\1/p' <<< "$fill_out")"
  [ -n "$fill_mb" ] && [ "$fill_mb" -ge 900 ] && [ "$fill_mb" -lt 1024 ] \
    || { echo "FAIL: /work held [$fill_mb] MiB, expected 900 to 1023" >&2; exit 1; }
  assert_eq "4" "$(field .exit_code "$WORK/fill.json")" "the full /work is recorded"

  # Output: stdout is truncated to 64 KiB.
  printf '<?php\necho str_repeat("x", 100000);\n' > "$WORK/big-out.php"
  run bigout a drush "$STUB" "$WORK/big-out.php"
  assert_eq "65536" "$(jq -r '.stdout | length' "$WORK/bigout.json")" "stdout is truncated to 64 KiB"

  # Time: a sleep past the timeout is stopped and recorded.
  printf '<?php\necho "start\\n";\nsleep(150);\necho "woke\\n";\n' > "$WORK/sleep.php"
  run sleep a drush "$STUB" "$WORK/sleep.php"
  assert_eq "124 true start" "$(jq -r '"\(.exit_code) \(.timed_out) \(.stdout | rtrimstr("\n"))"' "$WORK/sleep.json")" "a sleep past the timeout is stopped and recorded"

  # HTTP mode serves the docroot on loopback.
  cat > "$WORK/loop.php" <<'EOF'
<?php
$c = curl_init('http://127.0.0.1:8888/');
curl_setopt($c, CURLOPT_RETURNTRANSFER, TRUE);
$r = curl_exec($c);
echo $r === FALSE ? "loopback blocked\n" : $r;
EOF
  run loop b http "$STUB" "$WORK/loop.php"
  assert_eq "router-ok" "$(field .stdout "$WORK/loop.json")" "http mode serves the site on 127.0.0.1:8888"
fi

if [ -n "$site_ok" ]; then
  # The fixture site: rebuild.sh on SQLite with the configuration copy, in a
  # worktree so this checkout's settings.php is untouched. This checkout's
  # rebuild.sh replaces the worktree's so the version under test runs.
  git -C "$ROOT" worktree add --detach "$WT" HEAD > /dev/null
  cp "$ROOT/scripts/rebuild.sh" "$WT/scripts/rebuild.sh"
  bash "$SA/sqlite-config.sh" "$WORK/config-copy"
  (cd "$WT" && env -u COMPOSER REBUILD_COMPOSER=composer REBUILD_DRUSH=vendor/bin/drush \
    REBUILD_DB_URL=sqlite://localhost/sites/default/files/.ht.sqlite \
    REBUILD_RECIPE_PATH=../recipes/cedar_hollow_demo_content \
    REBUILD_CONFIG_DIR="$WORK/config-copy" REBUILD_SKIP_IMAGE_CHECK=1 \
    bash scripts/rebuild.sh) > "$WORK/rebuild.log" 2>&1 \
    || { tail -n 40 "$WORK/rebuild.log" >&2; echo "FAIL: the fixture site did not build" >&2; exit 1; }
  [ -f "$WT/web/sites/default/files/.ht.sqlite" ] || { echo "FAIL: no SQLite database in sites/default/files" >&2; exit 1; }

  # create-test-accounts.php refuses when demo_editor is missing.
  db="$WT/web/sites/default/files/.ht.sqlite"
  cp "$db" "$WORK/db.bak"
  (cd "$WT" && vendor/bin/drush role:delete demo_editor -y) > /dev/null 2>&1
  rc=0
  (cd "$WT" && vendor/bin/drush php:script "$SA/create-test-accounts.php" "$WORK/missing.json") > /dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL: create-test-accounts.php exited 0 without demo_editor" >&2; exit 1; }
  [ ! -e "$WORK/missing.json" ] || { echo "FAIL: accounts were written without demo_editor" >&2; exit 1; }
  assert_eq "0" "$(cd "$WT" && vendor/bin/drush php:eval "echo count(\\Drupal::entityTypeManager()->getStorage('user')->loadByProperties(['name' => ['audit_authenticated', 'audit_editor']]));")" \
    "no account was created without demo_editor"
  cp "$WORK/db.bak" "$db"

  (cd "$WT" && vendor/bin/drush php:script "$SA/create-test-accounts.php" "$WT/accounts.json")
  assert_eq "audit_authenticated:authenticated audit_editor:authenticated,demo_editor" \
    "$(jq -r '[.accounts[] | "\(.name):\(.roles | join(","))"] | join(" ")' "$WT/accounts.json")" "accounts.json lists both accounts with their roles"
  assert_eq "32 32" "$(jq -r '[.accounts[].password | select(test("^[A-Za-z0-9_-]{32}$")) | length] | join(" ")' "$WT/accounts.json")" \
    "each password is 32 URL-safe characters"
  [ "$(jq -r '.accounts[0].password' "$WT/accounts.json")" != "$(jq -r '.accounts[1].password' "$WT/accounts.json")" ] \
    || { echo "FAIL: the two passwords are equal" >&2; exit 1; }

  # The site directory the sandbox gets, as build-site hands it off.
  SITE="$WORK/site"
  mkdir "$SITE"
  for path in composer.json composer.lock vendor web config recipes accounts.json; do
    cp -a "$WT/$path" "$SITE/"
  done
  site_sum() {
    (cd "$SITE" && find . -print0 | sort -z | xargs -0 stat -c '%n %a %s %Y' | sha256sum
     cd "$SITE" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum) | sha256sum
  }
  before="$(site_sum)"

  if [ -n "$sandbox_ok" ]; then
    TITLE="Audit canary $(token)"
    ALIAS="/audit-canary-$(token)"
    cat > "$WORK/fixture.php" <<EOF
<?php
\$node = \Drupal\node\Entity\Node::create([
  'type' => 'speaker',
  'title' => '$TITLE',
  'status' => 1,
  'path' => ['alias' => '$ALIAS'],
]);
\$node->save();
EOF
    cat > "$WORK/read-drush.php" <<EOF
<?php
\$nodes = \Drupal::entityTypeManager()->getStorage('node')->loadByProperties(['title' => '$TITLE']);
echo \$nodes ? reset(\$nodes)->label() : 'not found', "\n";
EOF
    run site-drush a drush "$SITE" "$WORK/read-drush.php" "$WORK/fixture.php"
    assert_eq "$TITLE" "$(field .stdout "$WORK/site-drush.json")" "drush mode reads the fixture's node title"

    cat > "$WORK/read-http.php" <<EOF
<?php
\$c = curl_init('http://127.0.0.1:8888$ALIAS');
curl_setopt(\$c, CURLOPT_RETURNTRANSFER, TRUE);
\$html = (string) curl_exec(\$c);
echo curl_getinfo(\$c, CURLINFO_RESPONSE_CODE), ' ', str_contains(\$html, '$TITLE') ? 'title found' : 'title missing', "\n";
EOF
    run site-http b http "$SITE" "$WORK/read-http.php" "$WORK/fixture.php"
    assert_eq "200 title found" "$(field .stdout "$WORK/site-http.json")" "http mode reads the fixture's node title"

    EDITOR_PASS="$(jq -r '.accounts[] | select(.name == "audit_editor") | .password' "$WT/accounts.json")"
    cat > "$WORK/login.php" <<EOF
<?php
function login(string \$name, string \$pass): string {
  \$c = curl_init();
  curl_setopt_array(\$c, [CURLOPT_RETURNTRANSFER => TRUE, CURLOPT_COOKIEFILE => '', CURLOPT_FOLLOWLOCATION => TRUE]);
  curl_setopt(\$c, CURLOPT_URL, 'http://127.0.0.1:8888/user/login');
  \$form = (string) curl_exec(\$c);
  if (!preg_match('/name="form_build_id" value="([^"]+)"/', \$form, \$m)) {
    return 'no login form';
  }
  curl_setopt_array(\$c, [
    CURLOPT_POST => TRUE,
    CURLOPT_POSTFIELDS => http_build_query(['name' => \$name, 'pass' => \$pass, 'form_build_id' => \$m[1], 'form_id' => 'user_login_form', 'op' => 'Log in']),
  ]);
  curl_exec(\$c);
  // A login redirects to /user/<uid>, with a query string.
  \$path = (string) parse_url(curl_getinfo(\$c, CURLINFO_EFFECTIVE_URL), PHP_URL_PATH);
  return preg_match('#^/user/[0-9]+\$#', \$path) ? 'logged in' : 'not logged in';
}
echo 'wrong password: ', login('audit_editor', 'not-the-password'), "\n";
echo 'test account: ', login('audit_editor', '$EDITOR_PASS'), "\n";
EOF
    run site-login a http "$SITE" "$WORK/login.php"
    assert_eq "wrong password: not logged in
test account: logged in" "$(field .stdout "$WORK/site-login.json")" "http mode logs in as a test account, and not with a wrong password"

    assert_eq "$before" "$(site_sum)" "the original site directory is unchanged"
  else
    echo "SKIP: fixture site built and accounts tested, but the sandbox cases on it were not run (see the sandbox SKIP above)"
  fi
fi

pass run-in-sandbox.test.sh

#!/usr/bin/env bash
# Runs one proof-of-concept script against a copy of the audit site inside a
# bubblewrap sandbox and prints its run record as JSON on stdout.
#   run-in-sandbox.sh <fingerprint> <slot> <mode> <site-dir> <script> [fixture] > <run-record.json>
# slot is a or b. mode is drush (the script runs under drush php:script) or
# http (the script is a PHP client of the site served on 127.0.0.1:8888).
# fixture is an optional PHP script run under drush php:script first, to
# prepare data. <site-dir> is the project root (composer.json, vendor/, web/)
# and is bound read-only; the sandbox works on a copy in /work.
#
# The sandbox has no network beyond its own loopback, an empty environment
# apart from PATH, HOME and TMPDIR, read-only system directories, a 1 GiB
# /work and a 64 MiB /tmp. It runs under address space, CPU time, file size
# and process limits, inside a 120 second timeout. Where bubblewrap has no
# --size option, /work is a 1 GiB tmpfs mounted with sudo for this run, bound
# in, and unmounted afterwards, and /tmp is /work/tmp.
# stdout and stderr are each truncated to 64 KiB in the record. The exit
# status is 0 whenever a record is printed; the script's own status is in it.
set -euo pipefail

readonly WORK_BYTES=1073741824
readonly TMP_BYTES=67108864
readonly AS_BYTES=2147483648
readonly CPU_SECONDS=60
readonly FSIZE_BYTES=268435456
readonly NPROC=256
readonly TIMEOUT_SECONDS=120
readonly OUTPUT_BYTES=65536

usage() {
  echo "usage: run-in-sandbox.sh <fingerprint> <slot> <mode> <site-dir> <script> [fixture]" >&2
  exit 2
}

[ "$#" -eq 5 ] || [ "$#" -eq 6 ] || usage
fingerprint="$1"; slot="$2"; mode="$3"; site_dir="$4"; script="$5"; fixture="${6:-}"
[ -n "$fingerprint" ] || usage
case "$slot" in a | b) ;; *) echo "run-in-sandbox.sh: slot must be a or b" >&2; exit 2 ;; esac
case "$mode" in http | drush) ;; *) echo "run-in-sandbox.sh: mode must be http or drush" >&2; exit 2 ;; esac
[ -d "$site_dir" ] || { echo "run-in-sandbox.sh: $site_dir is not a directory" >&2; exit 2; }
[ -f "$script" ] || { echo "run-in-sandbox.sh: $script is not a file" >&2; exit 2; }
if [ -n "$fixture" ] && [ ! -f "$fixture" ]; then
  echo "run-in-sandbox.sh: $fixture is not a file" >&2
  exit 2
fi
for tool in bwrap prlimit timeout jq sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "run-in-sandbox.sh: $tool is not installed" >&2; exit 2; }
done
site_dir="$(cd "$site_dir" && pwd)"
script="$(cd "$(dirname "$script")" && pwd)/$(basename "$script")"
if [ -n "$fixture" ]; then
  fixture="$(cd "$(dirname "$fixture")" && pwd)/$(basename "$fixture")"
fi

out_dir="$(mktemp -d)"
mounted=""
cleanup() {
  if [ -n "$mounted" ]; then
    sudo umount "$mounted" || echo "run-in-sandbox.sh: could not unmount $mounted" >&2
  fi
  rm -rf "$out_dir"
}
trap cleanup EXIT

if bwrap --help 2>&1 | grep -q -- '--size'; then
  work_args=(--size "$WORK_BYTES" --tmpfs /work --dir /work/home --dir /work/tmp)
  tmp_args=(--size "$TMP_BYTES" --tmpfs /tmp)
  tmp_limit="$TMP_BYTES"
else
  work_dir="$out_dir/work"
  mkdir -m 0700 "$work_dir"
  sudo mount -t tmpfs -o "size=1g,uid=$(id -u),mode=0700" tmpfs "$work_dir"
  mounted="$work_dir"
  mkdir "$work_dir/home" "$work_dir/tmp"
  work_args=(--bind "$work_dir" /work)
  tmp_args=(--bind "$work_dir/tmp" /tmp)
  tmp_limit=null
fi

input_args=(--ro-bind "$site_dir" /in/site --ro-bind "$script" /in/poc.php)
if [ -n "$fixture" ]; then
  input_args+=(--ro-bind "$fixture" /in/fixture.php)
fi

# Runs inside the sandbox as: bash -c "$driver" driver <mode>
# vendor/bin/drush is a shell wrapper, which php would print rather than run;
# vendor/bin/drush.php is the PHP entry point.
# shellcheck disable=SC2016
driver='
set -u
mode="$1"
cp -a /in/site /work/site || exit 70
cp /in/poc.php /work/poc.php || exit 70
if [ -f /in/fixture.php ]; then cp /in/fixture.php /work/fixture.php || exit 70; fi
cd /work/site/web || exit 70
if [ -f /work/fixture.php ]; then
  php ../vendor/bin/drush.php php:script /work/fixture.php || exit $?
fi
if [ "$mode" = drush ]; then
  exec php ../vendor/bin/drush.php php:script /work/poc.php
fi
PHP_CLI_SERVER_WORKERS=4 php -S 127.0.0.1:8888 .ht.router.php > /work/tmp/server.log 2>&1 &
server=$!
ready=""
for _ in $(seq 1 40); do
  if php -r "exit(@fsockopen(\"127.0.0.1\", 8888, \$n, \$m, 0.5) ? 0 : 1);"; then ready=1; break; fi
  sleep 0.5
done
if [ -z "$ready" ]; then
  echo "run-in-sandbox: the site did not answer on 127.0.0.1:8888 within 20 seconds" >&2
  cat /work/tmp/server.log >&2
  kill "$server" 2>/dev/null
  exit 69
fi
php /work/poc.php
rc=$?
kill "$server" 2>/dev/null
wait "$server" 2>/dev/null
exit "$rc"
'

start="$(date +%s)"
rc=0
timeout "$TIMEOUT_SECONDS" \
  prlimit --as="$AS_BYTES" --cpu="$CPU_SECONDS" --fsize="$FSIZE_BYTES" --nproc="$NPROC" \
  bwrap --unshare-all --new-session --die-with-parent --clearenv \
    "${work_args[@]}" \
    "${input_args[@]}" \
    --ro-bind /usr /usr --symlink usr/lib /lib --symlink usr/lib64 /lib64 --symlink usr/bin /bin \
    --ro-bind /etc/php /etc/php --ro-bind /etc/alternatives /etc/alternatives \
    --ro-bind /etc/ld.so.cache /etc/ld.so.cache \
    "${tmp_args[@]}" --proc /proc --dev /dev \
    --setenv PATH /usr/bin:/bin --setenv HOME /work/home --setenv TMPDIR /work/tmp \
    --chdir /work \
    bash -c "$driver" driver "$mode" \
  > "$out_dir/stdout" 2> "$out_dir/stderr" || rc=$?
elapsed=$(( $(date +%s) - start ))

# timeout exits 124 when it stops the command; a script exiting 124 by itself
# finishes well inside the limit.
timed_out=false
if [ "$rc" -eq 124 ] && [ "$elapsed" -ge "$TIMEOUT_SECONDS" ]; then
  timed_out=true
fi

head -c "$OUTPUT_BYTES" "$out_dir/stdout" > "$out_dir/stdout.cut"
head -c "$OUTPUT_BYTES" "$out_dir/stderr" > "$out_dir/stderr.cut"
jq -n \
  --arg fingerprint "$fingerprint" --arg slot "$slot" --arg mode "$mode" \
  --arg script_sha256 "$(sha256sum "$script" | cut -d' ' -f1)" \
  --argjson limits "{\"address_space_bytes\": $AS_BYTES, \"cpu_seconds\": $CPU_SECONDS, \"file_size_bytes\": $FSIZE_BYTES, \"processes\": $NPROC, \"timeout_seconds\": $TIMEOUT_SECONDS, \"work_bytes\": $WORK_BYTES, \"tmp_bytes\": $tmp_limit, \"output_bytes\": $OUTPUT_BYTES}" \
  --argjson exit_code "$rc" --argjson timed_out "$timed_out" \
  --rawfile stdout "$out_dir/stdout.cut" --rawfile stderr "$out_dir/stderr.cut" \
  '{fingerprint: $fingerprint, slot: $slot, mode: $mode, script_sha256: $script_sha256,
    limits: $limits, exit_code: $exit_code, stdout: $stdout, stderr: $stderr,
    timed_out: $timed_out}'

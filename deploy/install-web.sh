#!/usr/bin/env bash
# Installs a static Angular build that a CI pipeline (Jenkins) has shipped to
# this server. Installed as /usr/local/sbin/<name>-install-web and runnable
# only by the "deploy" user through sudo, with no arguments.
#
# TRUST BOUNDARY. This script runs as root, while the package contents are
# decided by the repository. Therefore:
#   - nothing from the package is ever executed;
#   - the script never updates itself from the package;
#   - the package is untrusted data: only regular files and directories are
#     accepted, with no owners or modes taken from the archive.
# A push can change what the site looks like, but cannot run a command on the
# server. Updating this script is an administrator's job.
#
# ATOMIC RELEASES. Every deploy goes into its own folder under RELEASES, and
# WEB_LINK (the nginx root) is a symlink to the active one, so switching is a
# single rename(2). If nginx then fails to serve the new release, the previous
# one is restored. The first run turns a plain docroot left by an older deploy
# method into a "-before-symlink" release.
#
# OLD CHUNKS ARE KEPT. Angular loads pages as lazy chunks. A browser that
# opened the app before the deploy still asks for the previous release's
# chunks, so its main-*.js and chunk-*.js files are copied into the new
# release. Only the release directly before (per its own ngsw.json), so they
# do not pile up from release to release.
set -euo pipefail

# --- configuration ----------------------------------------------------------
INCOMING="/srv/deploy/incoming/web.tar.gz"
WEB_LINK="/var/www/app"
RELEASES="/var/www/app-releases"
LOG="/var/log/deploy-web.log"
LOCK="/run/lock/install-web.lock"
DEPLOY_USER="deploy"
RELEASES_KEPT=3
MAX_PACKAGE_BYTES=$((50 * 1024 * 1024))
CHECK_HOST="app.example.com"   # nginx server_name, checked over 127.0.0.1:80
# -----------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (through sudo)." >&2
  exit 1
fi

# Output goes to $LOG and stays visible in the CI log. Process substitution
# into tee does not survive "sudo use_pty", so the script re-runs itself once
# through a pipe instead.
if [[ "${INSTALL_LOGGED:-}" != "1" ]]; then
  export INSTALL_LOGGED=1
  self="$(readlink -f "$0")"
  set +e
  "$self" "$@" 2>&1 | tee -a "$LOG"
  exit "${PIPESTATUS[0]}"
fi

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Another deploy is running. Aborted." >&2
  exit 1
fi

echo "=== $(date --iso-8601=seconds) installing $CHECK_HOST"

if [[ -L "$INCOMING" || ! -f "$INCOMING" ]]; then
  echo "Package missing or not a regular file: $INCOMING" >&2
  exit 1
fi
owner="$(stat -c '%U' "$INCOMING")"
if [[ "$owner" != "$DEPLOY_USER" && "$owner" != "root" ]]; then
  echo "Package is owned by '$owner', not '$DEPLOY_USER' or root. Aborted." >&2
  exit 1
fi
size="$(stat -c '%s' "$INCOMING")"
if (( size > MAX_PACKAGE_BYTES )); then
  echo "Package is $size bytes, over the $MAX_PACKAGE_BYTES byte limit. Aborted." >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
tar -xzf "$INCOMING" -C "$stage" --no-same-owner --no-same-permissions

# Symlinks, devices, FIFOs and the like are rejected: a symlink inside a
# release could make nginx serve any file on the server.
odd="$(find "$stage" -mindepth 1 ! -type f ! -type d -print -quit)"
if [[ -n "$odd" ]]; then
  echo "Package contains an entry that is not a regular file or directory: ${odd#"$stage"/}" >&2
  exit 1
fi
extra="$(find "$stage" -mindepth 1 -maxdepth 1 ! -name browser -print -quit)"
if [[ -n "$extra" ]]; then
  echo "Package may only contain browser/, found: ${extra#"$stage"/}" >&2
  exit 1
fi
new="$stage/browser"
for required in index.html ngsw.json; do
  if [[ ! -f "$new/$required" ]]; then
    echo "Incomplete package: browser/$required is missing." >&2
    exit 1
  fi
done

# Integrity: every file in ngsw.json's hashTable must exist with the same
# SHA-1, and index.html must reference exactly one main-*.js and one
# styles-*.css that exist. Python only reads files here; nothing from the
# package runs.
check_package() {
  python3 - "$1" <<'PY'
import hashlib, json, os, re, sys

root = sys.argv[1]
table = json.load(open(os.path.join(root, "ngsw.json"), encoding="utf-8")).get("hashTable", {})
if not table:
    sys.exit("ngsw.json has no hashTable.")
for name, want in table.items():
    path = os.path.join(root, name.lstrip("/"))
    if not os.path.isfile(path):
        sys.exit("ngsw.json lists a file that does not exist: " + name)
    with open(path, "rb") as fh:
        if hashlib.sha1(fh.read()).hexdigest() != want:
            sys.exit("Hash does not match ngsw.json: " + name)
index = open(os.path.join(root, "index.html"), encoding="utf-8").read()
mains = re.findall(r'src="(main-[\w-]+\.js)"', index)
styles = re.findall(r'href="(styles-[\w-]+\.css)"', index)
if len(mains) != 1 or len(styles) != 1:
    sys.exit("index.html must reference exactly one main-*.js and one styles-*.css.")
for ref in mains + styles:
    if not os.path.isfile(os.path.join(root, ref)):
        sys.exit("index.html references a file that does not exist: " + ref)
print("Package valid: %d files match ngsw.json." % len(table), file=sys.stderr)
print(mains[0])
PY
}

# The JS chunk names of a release, according to that release's own ngsw.json.
release_chunks() {
  python3 - "$1" <<'PY'
import json, re, sys

for name in json.load(open(sys.argv[1], encoding="utf-8")).get("hashTable", {}):
    name = name.lstrip("/")
    if re.fullmatch(r"(main|chunk)-[\w-]+\.js", name):
        print(name)
PY
}

if ! main="$(check_package "$new")"; then
  exit 1
fi

install -d -m 0755 -o root -g root "$RELEASES"
release="$RELEASES/$(date +%Y%m%d-%H%M%S)"
if [[ -e "$release" ]]; then
  echo "Release folder already exists: $release" >&2
  exit 1
fi
cp -r "$new" "$release"

previous=""
if [[ -L "$WEB_LINK" ]]; then
  previous="$(readlink -f "$WEB_LINK")"
elif [[ -d "$WEB_LINK" ]]; then
  previous="$WEB_LINK"
fi

carried=0
if [[ -n "$previous" && -f "$previous/ngsw.json" ]]; then
  while IFS= read -r name; do
    if [[ -f "$previous/$name" && ! -L "$previous/$name" && ! -e "$release/$name" ]]; then
      cp "$previous/$name" "$release/$name"
      carried=$((carried + 1))
    fi
  done < <(release_chunks "$previous/ngsw.json")
fi
echo "Chunks carried over from the previous release: $carried"

chown -R root:root "$release"
chmod -R u=rwX,go=rX "$release"

ln -sfn "$release" "$WEB_LINK.new"
if [[ -d "$WEB_LINK" && ! -L "$WEB_LINK" ]]; then
  # Once only: the plain folder from the old deploy method becomes the
  # previous release, and the symlink takes its place.
  previous="$RELEASES/$(date +%Y%m%d-%H%M%S)-before-symlink"
  echo "First run: moving $WEB_LINK to $previous and replacing it with a symlink."
  mv "$WEB_LINK" "$previous"
fi
mv -Tf "$WEB_LINK.new" "$WEB_LINK"
echo "Active release: $release"

verify_release() {
  local body
  if ! body="$(curl -fsS --max-time 10 -H "Host: $CHECK_HOST" http://127.0.0.1/)"; then
    echo "nginx did not answer for $CHECK_HOST." >&2
    return 1
  fi
  if [[ "$body" != *"$main"* ]]; then
    echo "nginx is still serving the old index.html, not the new release." >&2
    return 1
  fi
  if ! curl -fsS -o /dev/null --max-time 10 -H "Host: $CHECK_HOST" "http://127.0.0.1/$main"; then
    echo "nginx failed to serve $main." >&2
    return 1
  fi
}

if ! verify_release; then
  if [[ -n "$previous" && -d "$previous" ]]; then
    ln -sfn "$previous" "$WEB_LINK.new"
    mv -Tf "$WEB_LINK.new" "$WEB_LINK"
    echo "Check failed. Rolled back to the previous release: $previous" >&2
  else
    echo "Check failed, and there is no previous release to roll back to." >&2
  fi
  exit 1
fi
echo "Checked through local nginx ($CHECK_HOST): index.html and $main are served."

# Keep the last few releases. The active release and the one directly before
# it are never removed.
current="$(readlink -f "$WEB_LINK")"
find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r \
  | tail -n "+$((RELEASES_KEPT + 1))" | while IFS= read -r name; do
      dir="$RELEASES/$name"
      [[ "$dir" == "$current" || "$dir" == "$previous" ]] && continue
      rm -rf -- "$dir"
      echo "Old release removed: $name"
    done

rm -f "$INCOMING"
echo "=== $(date --iso-8601=seconds) done"

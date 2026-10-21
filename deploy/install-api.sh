#!/usr/bin/env bash
# Installs a Go API binary that a CI pipeline (Jenkins) has shipped to this
# server. Installed as /usr/local/sbin/<name>-install-api and runnable only by
# the "deploy" user through sudo, with no arguments (see example.sudoers).
#
# TRUST BOUNDARY. This script runs as root; the service it installs does not.
# It refuses to install when the unit runs as anyone other than SERVICE_USER,
# so that a push to the repository can never quietly become root. The binary
# is owned by root, so the service cannot overwrite its own executable.
#
# MIGRATIONS ARE NOT RUN HERE. Applying DDL belongs to a human who has just
# taken a backup. This script only REFUSES to install a binary whose package
# lists a migration that schema_migrations has not recorded: such a binary
# starts fine, answers /readyz with 200, and then fails the first request
# that touches the missing column.
set -euo pipefail

# --- configuration ----------------------------------------------------------
INCOMING="/srv/deploy/incoming/api.tar.gz"
BINARY_NAME="api"
TARGET_DIR="/opt/api"
TARGET="$TARGET_DIR/$BINARY_NAME"
SERVICE="api"
SERVICE_USER="www-data"
PORT=8090
ENV_FILE="/etc/api/api.env"          # DB_DSN=user:pass@tcp(host:3306)/dbname?...
LOG="/var/log/deploy-api.log"
LOCK="/run/lock/install-api.lock"
DEPLOY_USER="deploy"
MAX_PACKAGE_BYTES=$((100 * 1024 * 1024))
READY_SECONDS=25
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

# The lock is held on fd 9. Every systemctl call closes it (9>&-) so that no
# process started by systemd inherits the fd and keeps the lock alive.
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Another deploy is running. Aborted." >&2
  exit 1
fi

echo "=== $(date --iso-8601=seconds) installing $BINARY_NAME"

# The unit itself is installed by an administrator, by hand.
if ! systemctl cat "$SERVICE" >/dev/null 2>&1 9>&-; then
  echo "Unit $SERVICE is not installed." >&2
  exit 1
fi
user="$(systemctl show -p User --value "$SERVICE" 9>&-)"
if [[ "$user" != "$SERVICE_USER" ]]; then
  echo "Unit $SERVICE runs as '$user', not '$SERVICE_USER'. Aborted." >&2
  exit 1
fi

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

# Exactly two regular files: the binary and migrations.txt. A package built
# for a different service is rejected here by name.
entries="$(find "$stage" -mindepth 1 | wc -l)"
new="$stage/$BINARY_NAME"
list="$stage/migrations.txt"
if [[ "$entries" -ne 2 || -L "$new" || ! -f "$new" || -L "$list" || ! -f "$list" ]]; then
  echo "Package must contain exactly two regular files, $BINARY_NAME and migrations.txt; found $entries entries." >&2
  exit 1
fi
# Every line must be a three-digit migration number, and the list must not be
# empty: an empty list would make the migration check below check nothing.
if [[ ! -s "$list" ]] || grep -qvE '^[0-9]{3}$' "$list"; then
  echo "migrations.txt is malformed: every line must be a three-digit migration number." >&2
  exit 1
fi
# 64-bit little-endian ELF for x86-64 (0x3e). A 64-bit ELF header is 64 bytes;
# anything smaller cannot be a binary.
if (( $(stat -c '%s' "$new") < 64 )); then
  echo "File is too small to be an ELF binary ($(stat -c '%s' "$new") bytes)." >&2
  exit 1
fi
magic="$(od -An -tx1 -N4 "$new" | tr -d ' \n')"
class="$(od -An -tx1 -j4 -N1 "$new" | tr -d ' \n')"
machine="$(od -An -tx1 -j18 -N2 "$new" | tr -d ' \n')"
if [[ "$magic" != "7f454c46" || "$class" != "02" || "$machine" != "3e00" ]]; then
  echo "File is not a Linux x86-64 ELF binary (magic=$magic class=$class machine=$machine)." >&2
  exit 1
fi
echo "Package valid: x86-64 ELF, $(stat -c '%s' "$new") bytes, SHA256 $(sha256sum "$new" | cut -c1-16)…"

# Every migration this binary needs must already be in schema_migrations. The
# database name comes from the service's own DB_DSN; mariadb runs as root over
# the local socket, with no password on the command line.
db="$(sed -n 's#^DB_DSN=.*/\([A-Za-z0-9_]*\)?.*#\1#p' "$ENV_FILE")"
if [[ -z "$db" ]]; then
  echo "Could not read the database name from DB_DSN in $ENV_FILE. Aborted." >&2
  exit 1
fi
if ! applied="$(mariadb -N -e "SELECT version FROM \`$db\`.schema_migrations" 2>&1)"; then
  echo "Could not read schema_migrations in $db: $applied" >&2
  exit 1
fi
pending="$(comm -23 <(sort -u "$list") <(printf '%s\n' "$applied" | tr -d '\r' | sort -u))"
if [[ -n "$pending" ]]; then
  echo "Migrations not yet applied to $db: $(echo $pending). Apply them first, then re-run this build." >&2
  exit 1
fi
echo "Migrations complete: all $(wc -l < "$list") required migrations are recorded in $db."

wait_ready() {
  local i
  for ((i = 1; i <= READY_SECONDS; i++)); do
    if curl -fsS --max-time 3 "http://127.0.0.1:$PORT/readyz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

install -d -m 0755 -o root -g root "$TARGET_DIR"
install -m 0755 -o root -g root "$new" "$TARGET.new"
had_previous=0
if [[ -f "$TARGET" ]]; then
  cp -p "$TARGET" "$TARGET.bak"
  had_previous=1
  echo "Previous binary saved: $TARGET.bak ($(sha256sum "$TARGET.bak" | cut -c1-16)…)"
fi
mv -f "$TARGET.new" "$TARGET"

# A release counts as successful only if the restart itself succeeded AND
# /readyz answers. A restart that fails at the systemd level (a missing unit
# dependency, start-limit-hit) never stops the old process, so /readyz keeps
# answering 200 from the OLD binary while the new one waits on disk for the
# next reboot. So the restart result is checked on its own, and its failure
# must not abort the script through set -e before the rollback below runs.
restarted=1
systemctl restart "$SERVICE" 9>&- || { restarted=0; echo "systemctl restart failed." >&2; }

if (( restarted == 1 )) && wait_ready; then
  echo "$BINARY_NAME ready on 127.0.0.1:$PORT."
  rm -f "$INCOMING"
  echo "=== $(date --iso-8601=seconds) done"
  exit 0
fi

echo "New release failed its check." >&2
journalctl -u "$SERVICE" -n 30 --no-pager >&2 || true
if (( had_previous == 0 )); then
  systemctl stop "$SERVICE" 9>&- || true
  echo "No previous binary; service stopped." >&2
  exit 1
fi
# Restored with mv, not by copying over the file in place: writing to a binary
# that is running (or being restarted in a loop by systemd) fails with
# "Text file busy", while mv only replaces the directory entry.
cp -p "$TARGET.bak" "$TARGET.new"
mv -f "$TARGET.new" "$TARGET"
if (( restarted == 1 )); then
  # The new binary ran and failed: start the old one again.
  systemctl restart "$SERVICE" 9>&- || true
fi
# If the restart failed from the start, the old process never stopped and is
# still serving; restoring the file is enough.
if wait_ready; then
  echo "Rolled back to the previous binary, and $BINARY_NAME is ready again." >&2
else
  echo "Rolled back to the previous binary, BUT $BINARY_NAME is not ready. Check: journalctl -u $SERVICE" >&2
fi
exit 1

#!/usr/bin/env bash
# Runs deploy/install-api.sh against a real systemd and a real MariaDB, in
# Docker, exactly the way CI calls it: as the "deploy" user through sudo.
#
#	tests/installer/run.sh
#
# Needs Docker and Go. Leaves nothing behind.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
net="installer-test-$$"
db="installer-test-db-$$"
srv="installer-test-srv-$$"
cleanup() {
  docker rm -f "$db" "$srv" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

echo "== Building the stand-in API and a package that needs migrations 001-003"
(cd "$here/fakeapi" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$work/api" .)
printf '001\n002\n003\n' > "$work/migrations.txt"
(cd "$work" && tar -czf api.tar.gz --owner=0 --group=0 api migrations.txt)
cp "$repo/deploy/install-api.sh" "$repo/deploy/example.sudoers" \
  "$here/setup.sh" "$here/scenarios.sh" "$work/"

echo "== Starting MariaDB and a systemd host"
docker network create "$net" >/dev/null
docker run -d --name "$db" --network "$net" -e MARIADB_ROOT_PASSWORD=test-root \
  -e MARIADB_DATABASE=shop mariadb:10.11 >/dev/null
docker run -d --name "$srv" --network "$net" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v "$work:/t:ro" jrei/systemd-ubuntu:24.04 >/dev/null
sleep 10

docker exec "$srv" bash /t/setup.sh "$db"
docker exec "$srv" bash /t/scenarios.sh

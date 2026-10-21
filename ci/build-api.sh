#!/usr/bin/env bash
# Tests and builds the API for Linux, then packages the binary together with
# migrations.txt: the numbers of every sql/NNN_*.sql file this binary needs.
# install-api.sh compares that list with schema_migrations on the server.
#
#	ci/build-api.sh                    -> build/api.tar.gz
#	ci/build-api.sh /tmp/package.tgz   -> another path
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/build/api.tar.gz}"
cd "$root/api"

echo "== gofmt"
unformatted="$(gofmt -l .)"
if [[ -n "$unformatted" ]]; then
  echo "Not gofmt-formatted:" >&2
  echo "$unformatted" >&2
  exit 1
fi

echo "== go vet"
go vet ./...

echo "== go test"
go test ./... -count=1

echo "== go build (linux/amd64)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -ldflags='-s -w' -o "$stage/api" .

echo "== Migration list"
(cd "$root/sql" && ls [0-9][0-9][0-9]_*.sql | cut -c1-3 | sort -u) > "$stage/migrations.txt"
echo "$(wc -l < "$stage/migrations.txt") migrations, latest $(tail -1 "$stage/migrations.txt")"

echo "== Package"
mkdir -p "$(dirname "$out")"
rm -f "$out"
tar -czf "$out" --owner=0 --group=0 -C "$stage" api migrations.txt
echo "Package ready: $out ($(du -h "$out" | cut -f1)), binary SHA256 $(sha256sum "$stage/api" | cut -c1-16)…"

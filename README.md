# satumeja-pos-architecture

How [SatuMeja](https://satumeja.com) is built and shipped. SatuMeja is a
restaurant and billiard-hall POS: guests scan a QR code at the table and
order from their phone, staff run the floor from a merchant console and an
Android cashier app, and ESP32 devices show table QR codes and switch
billiard-table lights. It is a commercial product running in production, so
its source stays private. This repository holds the parts worth showing: the
architecture, the deployment machinery, and the tools and tests behind them.
All of it is real code taken from the private repositories, not rewritten
for display.

## The system

```text
order.satumeja.com     guest app (Angular, no login)       ┐
merchant.satumeja.com  merchant console (Angular, PWA)     ├─> nginx ─> main API (Go) ──┐
Android cashier app    (Flutter)                           ┘                            ├─> MariaDB
admin.satumeja.com     platform console (Angular) ──────────> nginx ─> platform API (Go)┘
ESP32 table displays and billiard relays ── HTTPS long-poll, outbound only ─> main API
```

Seven repositories, one per deployable part, each with its own Jenkins job:
two Go APIs, three Angular builds, the Flutter app (analyze and test only),
and the firmware (compile only). See [docs/architecture.md](docs/architecture.md).

**Money is never a float.** Prices are resolved on the server, totals are
computed by MariaDB in `DECIMAL`, the API sends them as strings, and the web
apps hold integer cents ([web/money.ts](web/money.ts)).

**Each service holds only the credentials it needs.** The platform console
runs as a separate process with its own system user, its own token secret,
and per-table database grants (19 tables, no `DELETE`). It cannot read the
payment-gateway keys or the device tokens.

## What is in this repository

| Path | What it is |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Services, credentials, devices, and the money rules |
| [docs/splitting-the-api.md](docs/splitting-the-api.md) | Splitting one API into two in production: proving the source matched the running binary byte for byte, pruning ~27,000 lines of dead code, and a cutover that could be undone in seconds |
| [docs/deploy-safety.md](docs/deploy-safety.md) | What the installers guarantee, and the rollback bug that testing found |
| [deploy/install-api.sh](deploy/install-api.sh) | Root-side installer for a Go binary: validates the package, refuses a binary whose migrations have not run, installs it root-owned, rolls back on failure |
| [deploy/install-web.sh](deploy/install-web.sh) | Root-side installer for an Angular build: checks every file against `ngsw.json`, switches releases atomically through a symlink, verifies through nginx, rolls back |
| [deploy/example.service](deploy/example.service), [deploy/example.sudoers](deploy/example.sudoers) | The hardened systemd unit and the one-command sudo rule CI deploys through |
| [ci/](ci/) | Build script and Jenkinsfile for the API |
| [tests/installer/](tests/installer/) | 25 scenarios run against real systemd and MariaDB in Docker: `tests/installer/run.sh` |
| [tools/prune/](tools/prune/) | The Go tool that removed the dead code after the split |
| [web/](web/) | The integer-cents money helper and its tests: `cd web && npm ci && npm test` |

## What is not here

The ordering, billing, billiard, payment-gateway, and device-protocol code; the
database schema; the firmware; and anything about the servers they run on.

## Stack

Go (standard library `net/http`, `database/sql`) · MariaDB · Angular 22 ·
Flutter · ESP32 (Arduino, PlatformIO) · nginx · systemd · Jenkins · Docker
for tests

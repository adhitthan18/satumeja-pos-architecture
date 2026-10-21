# Splitting one API into two, in production

SatuMeja started as one Go service that served everything: guests, cashiers,
merchants, devices, payment webhooks, and the platform console used to create
restaurants and manage subscriptions. That meant the code reached by the
platform console ran in the same process as the payment-gateway keys, with
the same token secret as every restaurant owner's login. The goal was to move
the console into its own service without the restaurants noticing.

## 1. Prove the source is what is running

Before touching anything: was the code in the repository the code in
production? The deployed binary embeds its build information:

```text
$ go version -m /opt/api/api | grep vcs
build  vcs.revision=3052595…
build  vcs.modified=true
```

Built from an older commit, with uncommitted changes. The next commit claimed
to be exactly "what has been running in production", so the binary was
rebuilt from that commit's `api/` folder on top of the recorded revision,
with the same Go version and flags as the original deploy script. The
SHA-256 matched the production binary **byte for byte**. From then on, every
claim about "what production does" could be checked against the source.

## 2. One codebase becomes two

The platform API was created as a copy of the main API, and its `routes()`
reduced to the 32 `/api/platform/*` endpoints plus `/healthz` and `/readyz`.
`main()` lost the payment providers, the device gateway, the realtime hub, and
all background workers, and gained only what the console needs: the public
URL for firmware downloads, and the upload folder.

At that point most of the code was unreachable, but it all still compiled.
Removing it by hand would have been hundreds of edits across files where
platform handlers sat next to merchant code. [tools/prune](../tools/prune/)
does it in rounds until nothing is left:

| | Lines of non-test Go |
|---|---|
| Before | 30,998 |
| After pruning | 3,726 |

Each round asks `deadcode` what is unreachable from `main`, asks `go/types`
which types, vars and consts nothing references (including exported ones,
which `staticcheck` assumes may be used), removes them, and runs `goimports`.
Removals cascade, so it took five rounds. A build for both Windows and Linux,
and the remaining tests, proved nothing needed was lost.

Two things only showed up by reading what was left:

* The health page reported the payment gateways' status. In the new service
  that would always say "not configured", because the keys deliberately are
  not there. It now asks the main API's `/readyz` instead.
* Initialising the upload folder created `menu/`, a merchant feature. On a
  service only allowed to write `firmware/`, that would have silently
  disabled firmware uploads.

The platform API ended with nine environment variables, none of them a
payment key or device token.

## 3. Least privilege, measured

Every query in the pruned service was matched against the table list from the
migrations: it touches 19 tables, five of them read-only, and never deletes a
row. Its database user got exactly those grants. Its token secret is new, so
a leaked restaurant-owner secret cannot mint platform tokens, and its systemd
unit runs as its own user with a read-only filesystem except for the firmware
folder ([deploy/example.service](../deploy/example.service)).

## 4. Cutover that can be undone in seconds

The new service was started next to the old one, on another loopback port,
and tested over loopback first: `/readyz` 200, platform endpoints 401 without
a token, merchant endpoints 404, and a login attempt for a nonexistent admin
401 (not 500, which would have meant a missing grant).

Then the platform vhost's two `proxy_pass` lines moved from the old port to
the new one. Rolling back is restoring those two lines and reloading nginx.
Platform admins had to sign in again once, because of the new secret; nobody
else noticed anything.

## 5. Closing the old path

The old service still contained the platform code, and an audit after the
cutover found that the **merchant** vhost forwarded every `/api/` path to it,
so the old console API was still reachable through another hostname. That
was closed twice: immediately in nginx (`location /api/platform/ { return
404; }`), then permanently by removing the routes from the main API and
pruning again. This time `prune -keep` protected twelve functions that had
been dead *before* the change, so the commit contained only what the split
made unnecessary: 2,841 lines.

# Architecture

## Services

| Part | Serves | Runs as | Holds |
|---|---|---|---|
| Main API (Go) | guests, cashiers, merchants, devices; payment webhooks | `www-data` | database user with the app's grants, payment-gateway keys, device-gateway token, staff token secret |
| Platform API (Go) | the platform console only (`/api/platform/*`, 32 endpoints) | its own system user | its own database user (19 tables, no `DELETE`), its own token secret. Nothing else |
| Guest app (Angular) | `order.satumeja.com` | static files | — |
| Merchant console (Angular PWA) | `merchant.satumeja.com` | static files | — |
| Platform console (Angular) | `admin.satumeja.com` | static files | — |
| Cashier app (Flutter) | Android tablets | — | release signing key stays off CI |
| Firmware | ESP32 table displays, billiard relays, ESP32-C3 nodes | — | per-device token issued at enrollment |

Both APIs listen on loopback only; nginx is the only way in, and each vhost
forwards only the paths its app needs. The platform vhost forwards
`/api/platform/` and answers 404 for every other `/api/` path; the merchant
vhost explicitly answers 404 for `/api/platform/`, so the platform console is
reachable from exactly one hostname.

The main API alone runs the background work (expiring invoices and billiard
sessions, device alerts, idempotency-key cleanup), so there is never a second
copy racing it. The platform console's health page asks the main API's
`/readyz` over loopback instead of inspecting payment gateways itself, so it
needs none of their keys.

## Tokens

Staff and platform-admin tokens are both HS256 JWTs, but they are signed with
**different secrets** and carry a `typ` claim. The staff parser rejects any
token whose `typ` is not `staff`, so even a platform token signed with the
staff secret (one issued before the split, say) cannot be used as a staff
token: a platform admin has no `restaurant_id` or `outlet_id`, and accepting
one would run tenant queries against outlet zero.

## Devices

Devices only make outbound HTTPS connections, so a restaurant's router needs
no port forwarding. A device long-polls for its next command for up to 20
seconds; when a cashier starts a billiard session, the API wakes the waiting
poll immediately instead of waiting for the next one. Commands carry absolute
states (`ON` until a deadline, `OFF`), never toggles, so a retry can never
flip a light the wrong way, and the relay keeps its own deadline so the light
still goes off if the internet drops.

## Money

* **Prices come from the server.** The client sends only menu item IDs,
  quantities and option IDs; the server looks up every price.
* **MariaDB does the arithmetic, in `DECIMAL`.** Totals, discounts and
  billiard time charges are computed in SQL, for example:

  ```sql
  amount = IF(package_price IS NULL,
              ROUND(hourly_rate * ? / 60, 2),
              ROUND(package_price + hourly_rate * GREATEST(? - package_minutes, 0) / 60, 2))
  ```

  Neither Go nor JavaScript ever holds money in a float.
* **The API sends `DECIMAL` as strings**, and the web apps convert them to
  integer cents for display ([web/money.ts](../web/money.ts)), so the guest's
  screen and the printed receipt never disagree by one rupiah.
* **Outlet scope comes from the token**, never from a request parameter.
* **The application never alters its schema.** Its database user has no
  `ALTER` or `DROP`; numbered migrations are applied by a human, after a
  backup, and the installer refuses a binary that needs one that has not run
  ([deploy-safety.md](deploy-safety.md)).

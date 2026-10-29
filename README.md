# tailscale

Custom DollarDeploy service that joins the host to your
[Tailscale](https://tailscale.com) tailnet, installed from the official
[Linux apt packages](https://pkgs.tailscale.com/stable/#linux).

DollarDeploy clones this repo to `$APPDIR/services/<name>` and runs its
`prepare.sh` during the host's prepare run. The script is self-contained.

What it does:

1. Installs Tailscale from `pkgs.tailscale.com` (apt) for the host's distro.
2. Brings the node up with your auth key (`tailscale up`), optionally as an
   **ephemeral** node.
3. Applies settings (accept-dns, extra args, userspace networking) and enables
   IP forwarding automatically when advertising routes / an exit node. By default
   it lets Tailscale pick its recommended hostname; set `TAILSCALE_HOSTNAME` to
   pin a specific name.
4. Exposes Prometheus client metrics **over the tailnet only** (`:5252`).
5. Exposes apps deployed on the host as
   [Tailscale Services](https://tailscale.com/docs/features/tailscale-services),
   each with its own `https://<name>.<tailnet>.ts.net` URL (see below).
6. Exports the node's hostname / Tailscale IPs back to the service env.

## Install

1. Open the app and go to your **Host**.
2. Open the **Services** tab.
3. Click **Add service** and choose **Custom**.
4. Paste the repo URL: `https://github.com/dollardeploy/service-tailscale/`
5. Set `TAILSCALE_AUTH_SECRET` (required) as a host or service env var.
6. Save, then **Prepare** the host.

> `TAILSCALE_AUTH_SECRET` is **required** — the prepare run fails fast if it is
> not set. Use a tailnet auth key or an OAuth client secret.

## Settings (override via host/service env vars)

| Env var                         | Default              | Description                                                                            |
| ------------------------------- | -------------------- | -------------------------------------------------------------------------------------- |
| `TAILSCALE_AUTH_SECRET`         | _(required)_         | Auth key / OAuth client secret used by `tailscale up`.                                 |
| `TAILSCALE_EPHEMERAL`           | `0`                  | Register as ephemeral (appends `?ephemeral=true` to the key).                          |
| `TAILSCALE_HOSTNAME`            | _(Tailscale-chosen)_ | Tailscale machine name (`--hostname`). Empty lets Tailscale pick its recommended name. |
| `TAILSCALE_ACCEPT_DNS`          | `1`                  | Accept tailnet DNS config (`--accept-dns`).                                            |
| `TAILSCALE_EXTRA_ARGS`          | _(none)_             | Extra flags passed verbatim to `tailscale up` (tags, routes, exit node).               |
| `TAILSCALE_EXIT_NODE`           | `0`                  | Advertise as an exit node (`--advertise-exit-node`); also enables IP forwarding.       |
| `TAILSCALE_RESET`               | `1`                  | Pass `--reset` so each prepare applies the configured flags; `0` keeps prior settings. |
| `TAILSCALE_USERSPACE`           | `0`                  | Userspace networking instead of kernel `/dev/net/tun` (`--tun=userspace-networking`).  |
| `TAILSCALE_ENABLE_METRICS`      | `1`                  | Expose client metrics on the tailnet IP `:5252` (`tailscale set --webclient`).         |
| `TAILSCALE_STATE_DIR`           | `/var/lib/tailscale` | State directory (informational; matches the package default).                          |
| `TAILSCALE_AUTH_ONCE`           | `0`                  | Container-only; no host equivalent (host `up` runs once, idempotently).                |
| `TAILSCALE_ENABLE_HEALTH_CHECK` | `1`                  | Container-only; on a host use `tailscale status`.                                      |
| `TAILSCALE_LOCAL_ADDR_PORT`     | `0.0.0.0:4000`       | Container-only; host metrics are fixed to the tailnet IP `:5252`.                      |

| `TAILSCALE_TAGS` | _(none)_ | Comma separated ACL tags (`--advertise-tags`), e.g. `tag:dollardeploy`. Required for services. |
| `TAILSCALE_SERVICES` | `auto` | Apps exposed as Tailscale Services: `auto`, a list like `app1,app2`, or empty for none. |
| `TAILSCALE_SERVICES_HTTP` | `1` | Also serve plain HTTP on port 80 of each service. |
| `TAILSCALE_SERVE_TIMEOUT` | `60` | Seconds to wait for each `tailscale serve` call. |

> Boolean settings use `1` (on) / `0` (off).

## Expose apps on the tailnet

Every app on the host can get its own tailnet URL, `https://<name>.<tailnet>.ts.net`,
with a valid certificate and its own access rules, without being exposed publicly.
Each service forwards to nginx on `127.0.0.1:80`. Tailscale keeps the `Host`
header, so nginx routes the request to the app whose hostname matches.

With `TAILSCALE_SERVICES=auto` (the default), every app whose hostname is
`<name>.<tailnet>.ts.net` becomes service `svc:<name>`. Set a list
(`app1,app2`) to choose them explicitly. Services on this node that are no longer
wanted are drained and removed on the next prepare.

### Tailscale admin console (once per tailnet)

1. **DNS**: enable **MagicDNS** and **HTTPS Certificates**.
2. **Access controls**: add a tag for the hosts, a tag for the services, then
   auto-approval and access for every service with that tag, so new apps need
   no policy change (adjust `src` to the users or groups that need it):

   ```json
   {
     "tagOwners": {
       "tag:dollardeploy": ["autogroup:admin"],
       "tag:dollardeploy-app": ["autogroup:admin"]
     },
     "autoApprovers": {
       "services": {
         "tag:dollardeploy-app": ["tag:dollardeploy"]
       }
     },
     "grants": [
       {
         "src": ["autogroup:member"],
         "dst": ["tag:dollardeploy-app"],
         "ip": ["80", "443"]
       }
     ]
   }
   ```

   Use `tag:dollardeploy-app` only on services, never on devices, or the grant
   opens those devices too. To limit access per app, list services instead:
   `"dst": ["svc:app1", "svc:app2"]`.

3. **Services**: define one service per app: name `app1`, endpoints `tcp:443`
   and `tcp:80` (or only `tcp:443` with `TAILSCALE_SERVICES_HTTP=0`), tag
   `tag:dollardeploy-app`. The tag gives it auto-approval and access from the
   policy above. Without the tag, approve the host on the service page after
   the first prepare.
4. **Keys**: generate a **reusable** auth key with tag `tag:dollardeploy` and use
   it as `TAILSCALE_AUTH_SECRET`. For a host that already joined untagged, set
   its tags on the **Machines** page (Edit ACL tags) instead.

### DollarDeploy

1. Host env: `TAILSCALE_TAGS=tag:dollardeploy` (same tag as the auth key).
2. For each app:
   - hostname `app1.<tailnet>.ts.net`. DollarDeploy treats `.ts.net` as internal:
     no DNS check, no Let's Encrypt certificate, HTTP-only nginx site.
   - **Restrict access to specific IP addresses only**: `127.0.0.1`. The nginx site also answers on the
     public IP, so without this anyone sending `Host: app1.<tailnet>.ts.net` to
     the server reaches the app. Tailscale connects from loopback.
3. Deploy the apps, then **Prepare** the host. The service picks up new app
   hostnames on each prepare, so prepare again after adding an app.

The service URLs are exported as `TAILSCALE_SERVICE_URLS`.

Notes:

- Requires Tailscale >= 1.86; the script upgrades the package when needed.
- All tailnet traffic reaches nginx from `127.0.0.1`, so the app sees the client
  in `X-Forwarded-For` and the per-app rate limit is shared by all tailnet users.
- Tailscale adds `Tailscale-User-Login` / `Tailscale-User-Name` headers with the
  caller's identity (not for tagged devices).

> The `TAILSCALE_*` names mirror the `tailscale/tailscale` container env vars for
> familiarity. On a host install the daemon does not read them directly — the
> script translates the ones with a host equivalent into `tailscale up` /
> `tailscaled` flags. The vars marked _container-only_ are accepted for config
> compatibility but not applied.

## Metrics

Metrics are intentionally **not** exposed on the public IP. With
`TAILSCALE_ENABLE_METRICS=true` the script runs `tailscale set --webclient`, which
serves Prometheus client metrics at `http://<tailscale-ip>:5252/metrics` over the
tailnet (grant access to port `5252` in your tailnet ACLs). Locally on the host
they are always available at `http://100.100.100.100/metrics`. Requires
Tailscale >= 1.78. See [client metrics](https://tailscale.com/kb/1482/client-metrics).

## Exported env vars

The service writes these back into its own env (emitted as
`SERVICE_CUSTOM_<service-id>_<KEY>` so multiple custom services don't collide,
then stored under `<KEY>`):

- `TAILSCALE_HOSTNAME` — the node name
- `TAILSCALE_IP` / `TAILSCALE_IP6` — tailnet IPv4 / IPv6
- `TAILSCALE_DNSNAME` — MagicDNS name
- `TAILSCALE_METRICS_URL` — `http://<ip>:5252/metrics`
- `TAILSCALE_SERVICE_URLS` — comma separated `https://<name>.<tailnet>.ts.net` service URLs

## Uninstall

Remove the service from the host's **Services** tab. DollarDeploy runs
`uninstall.sh`, which `tailscale down` + `logout` (deregistering the node, and
removing ephemeral nodes from the tailnet), disables `tailscaled` and purges the
package. Set `TAILSCALE_KEEP_PACKAGE=1` to only leave the tailnet without
removing the package.

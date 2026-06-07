# Tailscale

Custom DollarDeploy service that joins the host to your
[Tailscale](https://tailscale.com) tailnet, installed from the official
[Linux apt packages](https://pkgs.tailscale.com/stable/#linux).

DollarDeploy clones this repo to `$APPDIR/services/<name>` and runs its
`prepare.sh` during the host's prepare run. The script is self-contained.

What it does:

1. Installs Tailscale from `pkgs.tailscale.com` (apt) for the host's distro.
2. Brings the node up with your auth key (`tailscale up`), optionally as an
   **ephemeral** node.
3. Applies settings (hostname, accept-dns, extra args, userspace networking) and
   enables IP forwarding automatically when advertising routes / an exit node.
4. Exposes Prometheus client metrics **over the tailnet only** (`:5252`).
5. Exports the node's hostname / Tailscale IPs back to the service env.

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

| Env var                         | Default              | Description                                                                           |
| ------------------------------- | -------------------- | ------------------------------------------------------------------------------------- |
| `TAILSCALE_AUTH_SECRET`         | _(required)_         | Auth key / OAuth client secret used by `tailscale up`.                                |
| `TAILSCALE_EPHEMERAL`           | `true`               | Register as ephemeral (appends `?ephemeral=true` to the key).                         |
| `TAILSCALE_HOSTNAME`            | host's hostname      | Tailscale machine name (`--hostname`).                                                |
| `TAILSCALE_ACCEPT_DNS`          | `true`               | Accept tailnet DNS config (`--accept-dns`).                                           |
| `TAILSCALE_EXTRA_ARGS`          | _(none)_             | Extra flags passed verbatim to `tailscale up` (tags, routes, exit node).              |
| `TAILSCALE_USERSPACE`           | `false`              | Userspace networking instead of kernel `/dev/net/tun` (`--tun=userspace-networking`). |
| `TAILSCALE_ENABLE_METRICS`      | `true`               | Expose client metrics on the tailnet IP `:5252` (`tailscale set --webclient`).        |
| `TAILSCALE_STATE_DIR`           | `/var/lib/tailscale` | State directory (informational; matches the package default).                         |
| `TAILSCALE_AUTH_ONCE`           | `false`              | Container-only; no host equivalent (host `up` runs once, idempotently).               |
| `TAILSCALE_ENABLE_HEALTH_CHECK` | `true`               | Container-only; on a host use `tailscale status`.                                     |
| `TAILSCALE_LOCAL_ADDR_PORT`     | `0.0.0.0:4000`       | Container-only; host metrics are fixed to the tailnet IP `:5252`.                     |

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

The service writes these back (prefixed `SERVICE_CUSTOM_`):

- `TAILSCALE_HOSTNAME` — the node name
- `TAILSCALE_IP` / `TAILSCALE_IP6` — tailnet IPv4 / IPv6
- `TAILSCALE_DNSNAME` — MagicDNS name
- `TAILSCALE_METRICS_URL` — `http://<ip>:5252/metrics`

## Uninstall

Remove the service from the host's **Services** tab. DollarDeploy runs
`uninstall.sh`, which `tailscale down` + `logout` (deregistering the node, and
removing ephemeral nodes from the tailnet), disables `tailscaled` and purges the
package. Set `TAILSCALE_KEEP_PACKAGE=1` to only leave the tailnet without
removing the package.

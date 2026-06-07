#!/bin/bash
# Tailscale custom service for DollarDeploy - uninstall
#
# Logs the node out (removing ephemeral nodes from the tailnet), stops and
# disables tailscaled, and removes the package and apt source.
#
# DollarDeploy runs this (when present) as the app user when the custom service
# is removed from the host. Best-effort: it keeps going on errors.

set -uo pipefail

# Keep the tailscale package installed (only leave the tailnet).
TAILSCALE_KEEP_PACKAGE="${TAILSCALE_KEEP_PACKAGE:-0}"

run="sudo"
if [ "$(id -u)" -eq 0 ]; then
  run=""
fi

echo "tailscale: starting uninstall"

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale: not installed, nothing to uninstall"
  exit 0
fi

# Leave the tailnet and remove credentials. logout deregisters the node, which
# also cleans up ephemeral nodes immediately.
$run tailscale down || echo "tailscale: down failed, continuing"
$run tailscale logout || echo "tailscale: logout failed, continuing"

$run systemctl disable --now tailscaled || echo "tailscale: failed to stop tailscaled, continuing"

if [ "${TAILSCALE_KEEP_PACKAGE}" != "1" ]; then
  echo "tailscale: removing package and apt source"
  $run env DEBIAN_FRONTEND=noninteractive apt-get purge -y tailscale || echo "tailscale: purge failed, continuing"
  $run rm -f /etc/apt/sources.list.d/tailscale.list
  $run rm -f /usr/share/keyrings/tailscale-archive-keyring.gpg
  $run rm -f /etc/sysctl.d/99-tailscale.conf
  $run rm -rf /var/lib/tailscale
fi

echo "tailscale: uninstall done"

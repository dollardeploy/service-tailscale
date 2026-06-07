#!/bin/bash
# Tailscale custom service for DollarDeploy
# https://pkgs.tailscale.com/stable/#linux
#
# Installs Tailscale from the official apt repository, joins the host to your
# tailnet with an auth key and applies (overridable) settings. Metrics are
# exposed only over the tailnet / loopback, never on the public IP.
#
# DollarDeploy clones this repo to $APPDIR/services/<name> and runs this script
# as the app user (via sudo) with SERVICE_ID set, during the host's prepare run.
# It is self-contained and inherits the host/service env vars (exported through
# the main prepare.sh) to override the defaults below.

set -euo pipefail

# --- Required ---------------------------------------------------------------
# Tailscale auth key (or OAuth client secret). Set as a host/service env var.
if [ -z "${TAILSCALE_AUTH_SECRET:-}" ]; then
  echo "tailscale: TAILSCALE_AUTH_SECRET is required (set it as a host/service env var)"
  exit 1
fi

# --- Overridable settings (set as host/service env vars) --------------------
# Register this node as ephemeral (removed from the tailnet shortly after it
# goes offline). Appends ?ephemeral=true to the auth key.
TAILSCALE_EPHEMERAL="${TAILSCALE_EPHEMERAL:-0}"
# Extra flags passed verbatim to `tailscale up` (e.g. tags, routes, exit node).
# Empty by default.
TAILSCALE_EXTRA_ARGS="${TAILSCALE_EXTRA_ARGS:-}"
# tailscaled state directory. The apt package already stores state here.
TAILSCALE_STATE_DIR="${TAILSCALE_STATE_DIR:-/var/lib/tailscale}"
# Use userspace networking instead of the kernel /dev/net/tun device.
TAILSCALE_USERSPACE="${TAILSCALE_USERSPACE:-false}"
# Container-only knob (containerboot). On a host `tailscale up` runs once and is
# idempotent, so this is accepted but has no host equivalent.
TAILSCALE_AUTH_ONCE="${TAILSCALE_AUTH_ONCE:-false}"
# Accept DNS configuration pushed by the tailnet.
TAILSCALE_ACCEPT_DNS="${TAILSCALE_ACCEPT_DNS:-true}"
# Container-only knob. On a host, health is observed via `tailscale status`.
TAILSCALE_ENABLE_HEALTH_CHECK="${TAILSCALE_ENABLE_HEALTH_CHECK:-true}"
# Container-only knob. On a host the metrics endpoint is fixed to the tailnet
# IP on :5252 (see TAILSCALE_ENABLE_METRICS); kept for config compatibility.
TAILSCALE_LOCAL_ADDR_PORT="${TAILSCALE_LOCAL_ADDR_PORT:-0.0.0.0:4000}"
# Expose Prometheus client metrics over the tailnet only (tailscale set
# --webclient -> http://<tailscale-ip>:5252/metrics, plus http://100.100.100.100/metrics locally).
TAILSCALE_ENABLE_METRICS="${TAILSCALE_ENABLE_METRICS:-true}"
# Tailscale machine name. Defaults to the host's hostname.
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-$(hostname)}"
# ---------------------------------------------------------------------------

# Privilege escalation, mirrors the other DollarDeploy scripts.
run="sudo"
if [ "$(id -u)" -eq 0 ]; then
  run=""
fi

echo "tailscale: starting custom service preparation"

# --- Install Tailscale from the official apt repository ---------------------
if ! command -v tailscale >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-ubuntu}"
  CODENAME="${VERSION_CODENAME:-}"
  if [ -z "${CODENAME}" ]; then
    echo "tailscale: cannot determine distro codename from /etc/os-release"
    exit 1
  fi
  echo "tailscale: installing for ${DISTRO_ID} ${CODENAME}"
  $run install -m 0755 -d /usr/share/keyrings
  curl -fsSL "https://pkgs.tailscale.com/stable/${DISTRO_ID}/${CODENAME}.noarmor.gpg" \
    | $run tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL "https://pkgs.tailscale.com/stable/${DISTRO_ID}/${CODENAME}.tailscale-keyring.list" \
    | $run tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  $run apt-get update
  $run env DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
else
  echo "tailscale: already installed ($(tailscale version | head -n1))"
fi

# --- Daemon flags -----------------------------------------------------------
# Only userspace networking needs a daemon flag; kernel mode (TAILSCALE_USERSPACE=false)
# is the package default. State lives in /var/lib/tailscale by default.
DAEMON_FLAGS=""
if [ "${TAILSCALE_USERSPACE}" = "true" ]; then
  DAEMON_FLAGS="--tun=userspace-networking"
fi
if [ "${TAILSCALE_STATE_DIR}" != "/var/lib/tailscale" ]; then
  echo "tailscale: note - TAILSCALE_STATE_DIR=${TAILSCALE_STATE_DIR} differs from the package default and is not applied to avoid conflicting with the systemd --state flag"
fi

DEFAULT_FILE="/etc/default/tailscaled"
if [ -f "${DEFAULT_FILE}" ] && grep -qE "^[[:space:]]*FLAGS=" "${DEFAULT_FILE}"; then
  $run sed -i "s|^[[:space:]]*FLAGS=.*|FLAGS=\"${DAEMON_FLAGS}\"|" "${DEFAULT_FILE}"
else
  echo "FLAGS=\"${DAEMON_FLAGS}\"" | $run tee -a "${DEFAULT_FILE}" >/dev/null
fi

$run systemctl enable tailscaled
$run systemctl restart tailscaled

# --- Enable IP forwarding when routing/exit-node is requested ---------------
if printf '%s' "${TAILSCALE_EXTRA_ARGS}" | grep -qE "advertise-routes|advertise-exit-node"; then
  echo "tailscale: enabling IP forwarding for subnet routing / exit node"
  {
    echo "net.ipv4.ip_forward = 1"
    echo "net.ipv6.conf.all.forwarding = 1"
  } | $run tee /etc/sysctl.d/99-tailscale.conf >/dev/null
  $run sysctl -p /etc/sysctl.d/99-tailscale.conf
fi

# --- Build the auth key (optionally ephemeral) ------------------------------
# Not echoed: it is a secret.
AUTHKEY="${TAILSCALE_AUTH_SECRET}"
if [ "${TAILSCALE_EPHEMERAL}" = "1" ] && [[ "${AUTHKEY}" != *"ephemeral="* ]]; then
  if [[ "${AUTHKEY}" == *"?"* ]]; then
    AUTHKEY="${AUTHKEY}&ephemeral=true"
  else
    AUTHKEY="${AUTHKEY}?ephemeral=true"
  fi
fi

# --- Bring the node up ------------------------------------------------------
UP_ARGS=(--authkey="${AUTHKEY}" --hostname="${TAILSCALE_HOSTNAME}" --accept-dns="${TAILSCALE_ACCEPT_DNS}")
if [ -n "${TAILSCALE_EXTRA_ARGS}" ]; then
  read -ra EXTRA <<< "${TAILSCALE_EXTRA_ARGS}"
  UP_ARGS+=("${EXTRA[@]}")
fi
echo "tailscale: bringing node up as '${TAILSCALE_HOSTNAME}' (ephemeral=${TAILSCALE_EPHEMERAL})"
$run tailscale up "${UP_ARGS[@]}"

# --- Metrics (tailnet-internal only) ----------------------------------------
if [ "${TAILSCALE_ENABLE_METRICS}" = "true" ]; then
  echo "tailscale: enabling web client / metrics on the tailnet IP (:5252)"
  $run tailscale set --webclient \
    || echo "tailscale: could not enable --webclient (requires Tailscale >= 1.78), metrics still available at http://100.100.100.100/metrics"
fi

# --- Export sensible values back to the service env -------------------------
# Captured by the host output listener (see lib/queue/outputListener.ts).
TAILSCALE_IP4="$($run tailscale ip -4 2>/dev/null | head -n1 || true)"
TAILSCALE_IP6="$($run tailscale ip -6 2>/dev/null | head -n1 || true)"
TAILSCALE_DNSNAME=""
if command -v jq >/dev/null 2>&1; then
  TAILSCALE_DNSNAME="$($run tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//' || true)"
fi

echo "tailscale: node IPv4 ${TAILSCALE_IP4:-unknown}, hostname ${TAILSCALE_HOSTNAME}"
echo "{{env:SERVICE_CUSTOM_TAILSCALE_HOSTNAME:${TAILSCALE_HOSTNAME}}}"
[ -n "${TAILSCALE_IP4}" ] && echo "{{env:SERVICE_CUSTOM_TAILSCALE_IP:${TAILSCALE_IP4}}}"
[ -n "${TAILSCALE_IP6}" ] && echo "{{env:SERVICE_CUSTOM_TAILSCALE_IP6:${TAILSCALE_IP6}}}"
[ -n "${TAILSCALE_DNSNAME}" ] && echo "{{env:SERVICE_CUSTOM_TAILSCALE_DNSNAME:${TAILSCALE_DNSNAME}}}"
[ -n "${TAILSCALE_IP4}" ] && echo "{{env:SERVICE_CUSTOM_TAILSCALE_METRICS_URL:http://${TAILSCALE_IP4}:5252/metrics}}"

echo "tailscale: done"

#!/usr/bin/env bash
# T-0003 / ADR-0024: bring up the local Minikube dev cluster with real TLS, in one command.
#
# Minikube only — no OrbStack, no Docker Compose (ADR-0024, T-0003 AC4). Every step converges
# rather than creates, so re-running this is the normal way to repair a half-up cluster.
#
# What it does NOT do: edit your host resolver. Wiring *.test to the cluster needs root and touches
# system DNS, so this script prints the exact per-OS snippet and leaves the decision to you.
# `smoke-dev.sh` reports whether that half is wired, separately from whether ingress works.
#
# Usage: dev-up.sh
# Env:   MINIKUBE_PROFILE (default: gitfrok)   MINIKUBE_DRIVER (default: minikube decides)
#        MINIKUBE_CPUS (default: 4)            MINIKUBE_MEMORY (default: 6144, in MiB)
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${MINIKUBE_PROFILE:-gitfrok}"
CPUS="${MINIKUBE_CPUS:-4}"
MEMORY="${MINIKUBE_MEMORY:-6144}"
NS=default
TLS_SECRET=gitsaas-tls
WILDCARD='*.gitsaas.test'
VERSIONS=deploy/dev/versions.env

# Pin every kubectl call to this profile's context. Without --context a stray `kubectl config
# use-context` elsewhere could point these applies at a completely different cluster.
KUBECTL=(kubectl --context "$PROFILE")

# Deployments to wait on, and how long each gets. Zitadel runs schema migrations on first boot, so
# it is slow in a way the others are not.
DEPLOYMENTS="postgres valkey redpanda seaweedfs hello"
ZITADEL_TIMEOUT=420s
DEFAULT_TIMEOUT=240s

step() { printf '\n==> %s\n' "$1"; }
die()  { printf 'dev-up: FAIL — %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------- preflight
step "Preflight"
for cmd in minikube kubectl mkcert; do
  command -v "$cmd" >/dev/null || die "$cmd not installed.
  minikube: https://minikube.sigs.k8s.io/docs/start/
  kubectl:  https://kubernetes.io/docs/tasks/tools/
  mkcert:   brew install mkcert  |  dnf install mkcert  |  apt install mkcert"
done
echo "minikube, kubectl, mkcert present"

# ------------------------------------------------------------------ versions.env vs manifests
# Checked before anything is applied: bringing up a cluster from tags that no longer match the
# recorded ones is worse than not bringing it up. Same script CI runs via `make verify`.
step "Asserting manifest image tags match $VERSIONS"
# Resolution enabled here (ADR-0034): this script is about to pull these images anyway, so learning
# that a tag does not exist costs one registry query instead of an ErrImagePull loop and a confused
# ten minutes. A rate-limited registry reports inconclusive, not failure.
CHECK_IMAGE_RESOLVE=1 ./scripts/check-dev-images.sh || die "image tags drifted from $VERSIONS (above)"

# ---------------------------------------------------------------------------- cluster
step "Minikube profile '$PROFILE'"
if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  echo "already running — leaving CPU/memory sizing untouched"
else
  start_args=(-p "$PROFILE" --cpus="$CPUS" --memory="$MEMORY" --addons=ingress --addons=ingress-dns)
  if [ -n "${MINIKUBE_DRIVER:-}" ]; then
    start_args+=(--driver="$MINIKUBE_DRIVER")
  fi
  echo "creating: minikube start ${start_args[*]}"
  minikube start "${start_args[@]}"
fi

# Idempotent on an existing cluster, and required on one created before these addons existed.
step "Addons: ingress + ingress-dns (ADR-0024)"
minikube addons enable ingress -p "$PROFILE"
minikube addons enable ingress-dns -p "$PROFILE"

# `kubectl wait` errors out instead of waiting when nothing matches the selector yet, so poll for
# the pod to exist before waiting on its condition.
step "Waiting for the ingress-nginx controller"
tries=0
until "${KUBECTL[@]}" get pods -n ingress-nginx \
        -l app.kubernetes.io/component=controller 2>/dev/null | grep -q controller; do
  tries=$((tries + 1))
  [ "$tries" -lt 90 ] || die "ingress-nginx controller pod never appeared"
  sleep 2
done
"${KUBECTL[@]}" wait -n ingress-nginx --for=condition=ready pod \
  -l app.kubernetes.io/component=controller --timeout=300s

# ---------------------------------------------------------------------------- TLS
# The key never touches the repo: it is generated in a temp dir, loaded into the cluster, and shred
# on exit. A committed private key is not a secret, and a gitignore entry is one `git add -f` away
# from being wrong.
step "mkcert wildcard certificate for $WILDCARD (AC3)"
# `mkcert -install` puts the CA in the SYSTEM trust store, which needs root. That is a convenience
# for browsers and for bare `curl`; the cluster never needs it, and neither does smoke-dev.sh, which
# validates explicitly with --cacert against $(mkcert -CAROOT)/rootCA.pem. So a failure here must not
# abort the bring-up — the same reasoning this script already applies to host DNS, which it prints
# instead of doing. Aborting was over-strict: on a host without passwordless sudo it stopped the
# cluster from coming up at all over a step no acceptance criterion depends on.
if ! mkcert -install >/dev/null 2>&1; then
  if [ -f "$(mkcert -CAROOT)/rootCA.pem" ]; then
    printf '  note: mkcert -install could not write the system trust store (needs root).\n'
    printf '        The CA exists, so the cluster and "make dev-smoke" are unaffected.\n'
    printf '        For browser trust, run: mkcert -install\n'
  else
    die "mkcert has no CA at $(mkcert -CAROOT) and 'mkcert -install' failed — run 'mkcert -install' by hand"
  fi
fi
tlsdir=$(mktemp -d)
trap 'rm -rf "$tlsdir"' EXIT
mkcert -cert-file "$tlsdir/tls.crt" -key-file "$tlsdir/tls.key" "$WILDCARD" >/dev/null
echo "issued by CA at $(mkcert -CAROOT)"

# Re-issued on every run and upserted, so an expired or host-mismatched secret self-heals.
"${KUBECTL[@]}" create secret tls "$TLS_SECRET" \
  --cert="$tlsdir/tls.crt" --key="$tlsdir/tls.key" -n "$NS" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

# ---------------------------------------------------------------------------- workloads
# Ingress last: it is the only object that depends on the Services and the TLS secret existing.
step "Applying manifests"
for m in postgres valkey redpanda seaweedfs zitadel hello ingress; do
  "${KUBECTL[@]}" apply -f "deploy/dev/$m.yaml"
done

step "Waiting for rollouts"
for d in $DEPLOYMENTS; do
  "${KUBECTL[@]}" rollout status "deployment/$d" -n "$NS" --timeout="$DEFAULT_TIMEOUT"
done
# Kept last and given its own budget: first boot is init + migrations + FirstInstance setup.
"${KUBECTL[@]}" rollout status deployment/zitadel -n "$NS" --timeout="$ZITADEL_TIMEOUT"

# ---------------------------------------------------------------------------- host DNS
IP=$(minikube ip -p "$PROFILE")
step "Host DNS for *.gitsaas.test — not automated, needs root"
case "$(uname -s)" in
  Darwin)
    cat <<EOF
  sudo mkdir -p /etc/resolver
  printf 'nameserver $IP\n' | sudo tee /etc/resolver/test >/dev/null
EOF
    ;;
  Linux)
    cat <<EOF
  NetworkManager + dnsmasq:
    printf 'server=/test/$IP\n' | sudo tee /etc/NetworkManager/dnsmasq.d/minikube.conf >/dev/null
    sudo systemctl reload NetworkManager

  systemd-resolved:
    sudo mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=$IP\nDomains=~test\n' |
      sudo tee /etc/systemd/resolved.conf.d/minikube-test.conf >/dev/null
    sudo systemctl restart systemd-resolved

  Neither, or you would rather not touch system DNS — enough for the smoke test, no wildcard:
    echo '$IP hello.gitsaas.test zitadel.gitsaas.test s3.gitsaas.test filer.gitsaas.test' |
      sudo tee -a /etc/hosts >/dev/null
EOF
    ;;
  *) echo "  unrecognised OS — point a resolver for the .test TLD at $IP" ;;
esac

step "dev-up: OK"
cat <<EOF
Cluster:  minikube profile '$PROFILE' at $IP
Context:  kubectl --context $PROFILE
Hosts:    https://hello.gitsaas.test    (smoke-test fixture)
          https://zitadel.gitsaas.test  (admin@gitsaas.test / ChangeMe123!)
          https://s3.gitsaas.test       https://filer.gitsaas.test
Verify:   make dev-smoke
EOF

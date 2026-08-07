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
#        MINIKUBE_PORTS (default: 80:80,443:443 — see below; empty string disables)
#        MINIKUBE_RUNTIME (default: containerd — see below)
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${MINIKUBE_PROFILE:-gitfrok}"
CPUS="${MINIKUBE_CPUS:-4}"
MEMORY="${MINIKUBE_MEMORY:-6144}"

# Publish the ingress ports from the node container to the host loopback.
#
# Without this, AC3's specified path cannot work under *rootless* podman: the node IP (192.168.49.2)
# sits on a network namespace the host cannot route into, so `ping` is 100% loss and a `--resolve` to
# that IP times out. The previous record concluded AC3 needed a rootful driver or KVM. It does not —
# it needs the ports published, which the podman driver supports directly.
#
# Binding 80/443 as a non-root user additionally needs net.ipv4.ip_unprivileged_port_start=0; the
# create path checks for that below rather than letting `minikube start` fail with a bind error that
# names neither sysctl nor cause. Set MINIKUBE_PORTS='' to opt out (e.g. when something already owns
# 80/443 on the host, or on a rootful driver where the node IP routes and this is unnecessary).
PORTS="${MINIKUBE_PORTS-80:80,443:443}"

# The node's container runtime, stated rather than defaulted.
#
# minikube 1.35 defaults to *docker*, which means provisioning installs and starts dockerd inside the
# node. On this host that fails outright — `Job for docker.service failed`, then `StartHost failed` —
# and the cluster never comes up. `deploy/dev/README.md` has documented `--container-runtime=containerd`
# since the first bring-up, but this script never passed it, so the two disagreed and only the README
# was right. The existing cluster was containerd because it was created by hand from the README; the
# create path here had never run to completion, which is exactly how the disagreement survived.
#
# minikube's own start-up notice says it will default to containerd from v1.39.0. Pinning it here means
# this script behaves the same before and after that flip, instead of silently changing under us.
RUNTIME="${MINIKUBE_RUNTIME:-containerd}"
NS=default
TLS_SECRET=gitsaas-tls
WILDCARD='*.gitsaas.test'
VERSIONS=deploy/dev/versions.env

# The OPA bundle governance owns and the data plane loads. POLICY_SRC is a path into the governance
# submodule — read, never written — and POLICY_ENV/POLICY_MOUNT are the contract a dataplane
# manifest has to honour once one exists (backend/cmd/dataplane-app reads POLICY_ENV and exits
# without it). Named here rather than inline so the manifest and the script cannot drift.
POLICY_SRC=governance/policies
POLICY_CM=gitfrok-policy-bundle
POLICY_MOUNT=/etc/gitfrok/policy
POLICY_ENV=GITFROK_POLICY_BUNDLE_DIR

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
  # inotify headroom, checked only on the create path because a running cluster has already paid
  # this cost. The node runs systemd as PID 1, and systemd allocates its own inotify instances; if
  # the per-user ceiling is already consumed by a desktop session it gets none and exits during
  # `prepare kic ssh` with "Failed to allocate manager object: Too many open files". minikube then
  # retries, and the retry fails on a *different* error (see the volume cleanup below), so the
  # message that reaches the operator names neither inotify nor the real cause. Fedora ships 128,
  # which a GUI login can nearly exhaust on its own — this is not an exotic misconfiguration.
  #
  # Checked, not fixed: raising it is `sysctl`, which needs root and outlives this script. Same
  # reasoning as the host-DNS step at the bottom, which also prints instead of doing.
  instances_max=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo unknown)
  if [ "$instances_max" != unknown ]; then
    # `-type l` + `readlink`, not `find -lname`. `-lname` is a GNU findutils extension that BusyBox
    # find rejects outright, and this sits in a command substitution in a pipeline under
    # `set -euo pipefail` — so on a non-GNU *Linux* userland (Alpine, where /proc exists so this block
    # is entered) the failure killed the whole script instantly, with no `die` message at all. macOS
    # was never affected: no /proc means `instances_max` is already "unknown" and this is skipped.
    # `-exec … +` and `-type l` are both POSIX. The trailing `|| true` is the belt to that braces: a
    # preflight that cannot count must degrade to a useless check, never to an unexplained exit.
    instances_used=$(find /proc/*/fd -type l -exec readlink {} + 2>/dev/null |
      grep -c inotify || true)
    if [ "$((instances_max - instances_used))" -lt 64 ]; then
      die "not enough inotify instances to boot the node: fs.inotify.max_user_instances=$instances_max
  with ~$instances_used already in use, leaving $((instances_max - instances_used)) free. The node's
  systemd needs its own, and fails with 'Too many open files' if it cannot get them.

  Raise it (needs root; persists across reboots):
    printf 'fs.inotify.max_user_instances=512\nfs.inotify.max_user_watches=524288\n' |
      sudo tee /etc/sysctl.d/99-minikube-inotify.conf >/dev/null
    sudo sysctl --system

  Or for this boot only:  sudo sysctl -w fs.inotify.max_user_instances=512"
    fi
    echo "inotify: $((instances_max - instances_used)) of $instances_max instances free"
  fi

  # Clear a half-created profile before creating one. minikube's own in-run retry deletes the
  # failed *container* but leaves the podman *volume*, so attempt two dies on "volume with name
  # $PROFILE already exists" — a stale-state error that masks whatever actually broke attempt one.
  # It also leaves the profile registered but unusable, which means every later run takes this
  # branch and fails the same way. `minikube delete` is what removes both, so a re-run genuinely
  # repairs a failed create, as the header of this script claims it does.
  if minikube profile list -o json 2>/dev/null | grep -q "\"Name\":\"$PROFILE\"" ||
     [ -d "$HOME/.minikube/machines/$PROFILE" ]; then
    echo "profile exists but is not running — clearing it (container + volume) before recreating"
    minikube delete -p "$PROFILE" || die "could not delete the stale '$PROFILE' profile"
  fi

  # The volume can outlive the profile. `minikube delete` removes both, but only while minikube still
  # knows the profile exists — once the registration is gone the volume is orphaned and nothing above
  # touches it, so the create fails with `volume with name $PROFILE already exists` and no hint that a
  # leftover from a previous run is the cause. Checked against whichever engine is actually present.
  for engine in podman docker; do
    command -v "$engine" >/dev/null 2>&1 || continue
    if "$engine" volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$PROFILE"; then
      echo "orphaned $engine volume '$PROFILE' from a failed create — removing it"
      "$engine" volume rm "$PROFILE" >/dev/null ||
        die "could not remove the orphaned $engine volume '$PROFILE'; remove it by hand and re-run"
    fi
  done

  start_args=(-p "$PROFILE" --cpus="$CPUS" --memory="$MEMORY" --container-runtime="$RUNTIME"
    --addons=ingress --addons=ingress-dns)
  if [ -n "${MINIKUBE_DRIVER:-}" ]; then
    start_args+=(--driver="$MINIKUBE_DRIVER")
  fi

  # Port publishing, and the sysctl it depends on. Checked here for the same reason the inotify block
  # above exists: without it `minikube start` fails deep inside container creation with a bind error
  # that names the port and nothing else, and the operator has no way to know one sysctl fixes it.
  if [ -n "$PORTS" ]; then
    unpriv_start=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo unknown)
    # Only ports below the ceiling are a problem, and only when we are not root. Extract the *host*
    # side of each host:node pair — that is the side actually bound on this machine.
    if [ "$unpriv_start" != unknown ] && [ "$(id -u)" -ne 0 ]; then
      for pair in $(printf '%s' "$PORTS" | tr ',' ' '); do
        host_port=${pair%%:*}
        if [ "$host_port" -lt "$unpriv_start" ] 2>/dev/null; then
          die "cannot publish port $host_port as a non-root user:
  net.ipv4.ip_unprivileged_port_start=$unpriv_start, so ports below $unpriv_start need root.

  Lower it (needs root; persists across reboots):
    echo 'net.ipv4.ip_unprivileged_port_start=0' |
      sudo tee /etc/sysctl.d/99-unprivileged-ports.conf >/dev/null
    sudo sysctl --system

  Or skip port publishing:  MINIKUBE_PORTS='' $0
  (ingress then reachable only via kubectl port-forward under a rootless driver)"
        fi
      done
    fi
    start_args+=(--ports="$PORTS")
  fi
  echo "creating: minikube start ${start_args[*]}"
  minikube start "${start_args[@]}"
fi

# Idempotent on an existing cluster, and required on one created before these addons existed.
step "Addons: ingress + ingress-dns (ADR-0024)"
minikube addons enable ingress -p "$PROFILE"
minikube addons enable ingress-dns -p "$PROFILE"

# nginx defaults `worker_processes` to the host CPU count, but the controller pod's cgroup caps
# PIDs well below what that many workers plus their thread pools need. On a 12-CPU host the pod hit
# `pthread_create() failed (11: Resource temporarily unavailable)` and nginx logged "worker process
# exited with fatal code 2 and cannot be respawned". The surviving workers still completed the TCP
# handshake but never answered, so requests hung until the client timed out — 4 of 6 probes returned
# curl exit 28 while the other 2 answered normally. That reads as a network fault, not a resource
# one, which is why it is worth pinning rather than leaving to the host's core count: the dev
# cluster serves a handful of requests, so two workers is ample and makes behaviour identical on
# every machine. ingress-nginx watches this ConfigMap and reloads nginx itself, so no restart here.
step "Capping ingress-nginx worker processes"
tries=0
until "${KUBECTL[@]}" get configmap ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; do
  tries=$((tries + 1))
  [ "$tries" -lt 60 ] || die "ingress-nginx ConfigMap never appeared"
  sleep 2
done
"${KUBECTL[@]}" patch configmap ingress-nginx-controller -n ingress-nginx \
  --type merge -p '{"data":{"worker-processes":"2"}}'

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

# ---------------------------------------------------------------------- policy bundle
# The OPA bundle the data plane loads via GITFROK_POLICY_BUNDLE_DIR (ADR-0006, invariant 2). It is
# built here from the governance checkout rather than committed as a manifest, for the same reason
# the TLS key above is generated rather than committed: governance is the bundle's only author
# (invariants 13 and 21), and a copy of the rules under deploy/dev/ would be a second source of
# truth that drifts. Note this is the opposite call from image tags, which deploy/dev/ deliberately
# hardcodes and asserts ("assert, don't generate") — tags are a *pin* the super-repo owns, whereas
# the policy is *content* another repo owns.
step "Policy bundle ConfigMap '$POLICY_CM' from $POLICY_SRC"
[ -f "$POLICY_SRC/.manifest" ] ||
  die "no policy bundle at $POLICY_SRC/.manifest — run 'make bootstrap' to materialise the submodules"

# Flat keys over a nested tree: ConfigMap keys cannot contain '/', and they do not need to. OPA
# resolves policies by the `package` declaration inside each file, not by its path, so a flat
# directory loads identically to the nested one — verified with `opa eval` against both layouts.
#
# Two traps this loop exists to avoid, both of which produce a bundle that *loads* and then denies
# every request in the system:
#
#   1. `--from-file=<dir>` is NOT recursive. Pointed at $POLICY_SRC it picks up `.manifest` alone
#      and silently misses every .rego under gitsaas/. The result passes the backend's startup
#      check — the revision is present, so the bundle is valid — and then answers every query with
#      an undefined decision. Confirmed in-cluster: a manifest-only bundle evaluates to `{}`.
#      Fail-fast at boot cannot catch this, because nothing about it is malformed.
#   2. A flat key namespace collides where a nested tree does not. Two files named authz.rego under
#      different packages would silently overwrite each other, and the survivor is whichever the
#      loop reached last.
#
# *_test.rego is excluded to match the loader's own filter (backend/modules/policy/.../opa/pdp.go):
# they are governance's tests OF the policy, they reference rules that exist only to be tested, and
# including them can fail compilation.
# The bundle always has a .manifest, so cm_args is never expanded empty — which matters, because
# under bash 3.2 (macOS, AC4) `"${arr[@]}"` on an empty array trips `set -u`. Seen keys are tracked
# in a plain string for the same reason.
cm_args=(--from-file=".manifest=$POLICY_SRC/.manifest")
seen_keys=" "
policy_count=0
while IFS= read -r -d '' f; do
  key=${f##*/}
  case "$seen_keys" in
    *" $key "*)
      die "two policy files share the basename '$key' (second: $f).
  ConfigMap keys are flat, so one would silently overwrite the other. Rename one in governance." ;;
  esac
  seen_keys="$seen_keys$key "
  cm_args+=("--from-file=$key=$f")
  policy_count=$((policy_count + 1))
# No `sort` here on purpose. It was `| sort -z`, which is a GNU extension — FreeBSD-derived sort and
# busybox both accept it, so I cannot show from a Linux host that macOS's rejects it, and it is not
# claimed as a defect. It is dropped because it bought nothing: ConfigMap `data` is a map, so key
# order carries no meaning, kubectl emits the keys sorted regardless, and duplicate basenames are
# already a hard failure above. Removing an unportable dependency with no purpose beats keeping one
# whose portability is an open question (T-0003 AC4).
done < <(find "$POLICY_SRC" -name '*.rego' ! -name '*_test.rego' -print0)

# Trap 1's guard. A bundle with a manifest and no rules is the failure this whole comment is about.
[ "$policy_count" -gt 0 ] ||
  die "found no .rego policies under $POLICY_SRC — a bundle with no rules denies every request"

"${KUBECTL[@]}" create configmap "$POLICY_CM" -n "$NS" \
  "${cm_args[@]}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
echo "revision $(sed -n 's/.*"revision"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$POLICY_SRC/.manifest" | head -1), $policy_count policy file(s)"
printf '  mount it at %s and set %s to that path.\n' "$POLICY_MOUNT" "$POLICY_ENV"
printf '  No workload consumes it yet: deploy/dev/ has no dataplane manifest, and backend/ has no\n'
printf '  Dockerfile to build one from. See deploy/dev/README.md ("Policy bundle").\n'

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

# Which address the host should point *.gitsaas.test at.
#
# Not always the node IP. Under a rootless driver the node IP is in a network namespace the host
# cannot route into, so a resolver aimed there resolves fine and then times out — which reads as a
# broken cluster rather than an unreachable address. When the ingress ports are published (the
# default, see MINIKUBE_PORTS), the reachable address is the loopback the publish lands on.
if [ -n "$PORTS" ]; then
  DNS_TARGET=127.0.0.1
  echo "ingress ports are published, so point DNS at the loopback, not the node IP ($IP)"
else
  DNS_TARGET="$IP"
fi
case "$(uname -s)" in
  Darwin)
    cat <<EOF
  sudo mkdir -p /etc/resolver
  printf 'nameserver $DNS_TARGET\n' | sudo tee /etc/resolver/test >/dev/null
EOF
    ;;
  Linux)
    cat <<EOF
  NetworkManager + dnsmasq:
    printf 'server=/test/$DNS_TARGET\n' | sudo tee /etc/NetworkManager/dnsmasq.d/minikube.conf >/dev/null
    sudo systemctl reload NetworkManager

  systemd-resolved:
    sudo mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=$DNS_TARGET\nDomains=~test\n' |
      sudo tee /etc/systemd/resolved.conf.d/minikube-test.conf >/dev/null
    sudo systemctl restart systemd-resolved

  Neither, or you would rather not touch system DNS — enough for the smoke test, no wildcard:
    echo '$DNS_TARGET hello.gitsaas.test zitadel.gitsaas.test s3.gitsaas.test filer.gitsaas.test' |
      sudo tee -a /etc/hosts >/dev/null
EOF
    ;;
  *) echo "  unrecognised OS — point a resolver for the .test TLD at $DNS_TARGET" ;;
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

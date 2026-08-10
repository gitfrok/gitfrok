#!/usr/bin/env bash
# Super-repo fitness function: every deploy/dev manifest uses exactly the image tags recorded in
# deploy/dev/versions.env (ADR-0023, T-0003 AC2).
#
# The manifests hardcode their tags so `kubectl apply -f` works standalone without the bootstrap
# script. That leaves two copies of every tag free to drift. Templating the manifests would fix the
# duplication by making them unappliable on their own, so the drift is made a hard failure instead:
# assert, don't generate — the same shape as the other checks in here.
#
# Needs no cluster, so `make verify` (and therefore CI) gates it. scripts/dev-up.sh calls it too,
# before it applies anything.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSIONS=deploy/dev/versions.env
MANIFESTS="postgres.yaml valkey.yaml redpanda.yaml seaweedfs.yaml zitadel.yaml hello.yaml dataplane.yaml controlplane.yaml git-storaged.yaml bff.yaml webfrontend.yaml"

fail=0
report() { echo "DEV-IMAGE DRIFT: $1"; fail=1; }

[ -f "$VERSIONS" ] || { echo "dev-images: FAIL — $VERSIONS not found"; exit 1; }

set -a
# Literal path, not "$VERSIONS": shellcheck can only reason about a constant source (SC1090).
# shellcheck disable=SC1091  # data file, not a script — nothing for shellcheck to follow
. ./deploy/dev/versions.env
set +a

# First-party dev plane images are loaded into the cluster node by dev-up.sh
# (minikube image build), not published to an external registry — exempt them
# from registry resolution below, which would otherwise fail and block the
# dev bring-up. They are still required entries above so the image recorded
# in versions.env is the one asserted running on the cluster.
FIRST_PARTY_IMAGES="$DATAPLANE_IMAGE $CONTROLPLANE_IMAGE $GIT_STORAGED_IMAGE $BFF_IMAGE $WEBFRONTEND_IMAGE"

# One image per line, so comparison never depends on word splitting.
expected_images() { # expected_images <manifest>
  case "$1" in
    postgres.yaml)  printf '%s\n' "$POSTGRES_IMAGE" ;;
    valkey.yaml)    printf '%s\n' "$VALKEY_IMAGE" ;;
    redpanda.yaml)  printf '%s\n' "$REDPANDA_IMAGE" ;;
    seaweedfs.yaml) printf '%s\n' "$SEAWEEDFS_IMAGE" ;;
    # Zitadel's db-wait init container is busybox, so this manifest legitimately carries two.
    zitadel.yaml)   printf '%s\n' "$ZITADEL_IMAGE" "$BUSYBOX_IMAGE" ;;
    hello.yaml)     printf '%s\n' "$BUSYBOX_IMAGE" ;;
    # First-party plane images (T-0021): built and loaded into the cluster node
    # by dev-up.sh, never published to an external registry for dev. Their
    # resolution is exempted below; they are still required here so the image
    # recorded in versions.env is the one asserted on the cluster.
    dataplane.yaml) printf '%s\n' "$DATAPLANE_IMAGE" ;;
    git-storaged.yaml) printf '%s\n' "$GIT_STORAGED_IMAGE" ;;
    controlplane.yaml) printf '%s\n' "$CONTROLPLANE_IMAGE" ;;
    bff.yaml) printf '%s\n' "$BFF_IMAGE" ;;
    webfrontend.yaml) printf '%s\n' "$WEBFRONTEND_IMAGE" ;;
    *) echo "unmapped manifest: $1" >&2; return 1 ;;
  esac
}

for file in $MANIFESTS; do
  path="deploy/dev/$file"
  if [ ! -f "$path" ]; then
    report "$file is missing"
    continue
  fi
  actual=$(grep -E '^[[:space:]]*image:' "$path" |
             sed -E 's/^[[:space:]]*image:[[:space:]]*//' | sort -u)
  want=$(expected_images "$file" | sort -u)
  if [ "$actual" = "$want" ]; then
    echo "  ok    $file"
  else
    report "$file uses [$(echo "$actual" | tr '\n' ' ')], $VERSIONS says [$(echo "$want" | tr '\n' ' ')]"
  fi
done

# Every manifest image must be mapped above — a new service whose tag nobody records would
# otherwise pass silently, which is the exact gap this check exists to close.
all_actual=$(grep -hE '^[[:space:]]*image:' deploy/dev/*.yaml |
               sed -E 's/^[[:space:]]*image:[[:space:]]*//' | sort -u)
all_want=$(for file in $MANIFESTS; do expected_images "$file"; done | sort -u)
unmapped=$(comm -13 <(printf '%s\n' "$all_want") <(printf '%s\n' "$all_actual"))
[ -z "$unmapped" ] || report "images in deploy/dev with no $VERSIONS entry: $(echo "$unmapped" | tr '\n' ' ')"

# ----------------------------------------------------------------- ADR-0034: pin shape
# These were a WARN until ADR-0034 was Accepted. A floating tag is whatever the node last pulled,
# which is the opposite of a version floor of record — and a warning nobody must act on is a warning
# nobody acts on: ZITADEL_IMAGE stayed ':latest' across three tasks under the old WARN.
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    *:latest|*:latest-*) report "$ref uses a floating tag — ADR-0034 forbids ':latest'" ;;
  esac
  # Fully qualified: a reference whose first path segment carries no dot (and is not localhost) is
  # resolved against the implicit docker.io. That default is not a decision (ADR-0034).
  first=${ref%%/*}
  case "$ref" in
    */*) case "$first" in
           *.*|localhost|*:*) ;;
           *) report "$ref is not fully qualified — name the registry (ADR-0034)" ;;
         esac ;;
    *)   report "$ref is not fully qualified — name the registry (ADR-0034)" ;;
  esac
  # Specificity: reject a bare major (`postgres:18`) or a non-numeric tag. NOT a demand for three
  # components — "patch level" means "the most specific version upstream publishes", and upstreams
  # disagree about how many numbers that takes: PostgreSQL's patch releases are 18.4, SeaweedFS ships
  # only 4.40, while valkey and busybox do publish 9.1.1 and 1.35.0. A three-component rule would fail
  # a maximally-specific pin, so the text check enforces "at least major.minor" and the resolution
  # probe below plus review cover whether something more specific exists.
  tag=${ref##*:}
  case "$ref" in
    *@sha256:*) ;;                                   # digest-pinned: exact by construction
    *:*) case "$tag" in
           v[0-9]*.[0-9]*|[0-9]*.[0-9]*) ;;
           *) report "$ref is not specific enough — ADR-0034 wants at least major.minor, not a rolling tag" ;;
         esac ;;
    *) report "$ref has no tag at all — ADR-0034 wants a specific version tag" ;;
  esac
done <<EOF
$all_want
EOF

# --------------------------------------------------- ADR-0034: the reference actually resolves
# The check that would have caught `redpandadata/redpanda:v26.1` — a tag that was never published —
# for the cost of one registry request instead of a cluster run and seven hours of debugging.
#
# Opt-in via CHECK_IMAGE_RESOLVE=1 because it needs the network, and a fitness function that fails
# on a train with no signal teaches people to skip it. Unauthenticated Docker Hub pulls are also rate
# limited per IP, and shared CI runners hit that regularly — which is why a refused query is reported
# as inconclusive rather than as drift. CI and scripts/dev-up.sh set it; a bare
# `make verify` on a laptop stays offline. It is skipped LOUDLY — silence would let a green run imply
# something it never checked.
if [ "${CHECK_IMAGE_RESOLVE:-0}" = "1" ]; then
  if ! command -v skopeo >/dev/null && ! command -v podman >/dev/null && ! command -v docker >/dev/null; then
    report "CHECK_IMAGE_RESOLVE=1 but none of skopeo/podman/docker is installed — cannot verify that pins resolve"
  else
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      # First-party dev plane images live in the cluster node, not in an external registry —
      # skip the probe that would flag them as missing (see FIRST_PARTY_IMAGES above).
      case " $FIRST_PARTY_IMAGES " in
        *" $ref "*) echo "  skip  first-party dev image: $ref"; continue ;;
      esac
      if command -v skopeo >/dev/null; then
        probe=(skopeo inspect --raw "docker://$ref")
      elif command -v podman >/dev/null; then
        probe=(podman manifest inspect "$ref")
      else
        probe=(docker manifest inspect "$ref")
      fi
      if out=$("${probe[@]}" 2>&1); then
        echo "  ok    resolves: $ref"
      else
        # "Could not tell" is not "does not exist", and conflating them would make this gate worse
        # than useless: it would fail correct pins on a rate limit and train people to ignore it.
        # Only an explicit absence is drift. Everything else is reported as inconclusive — loudly,
        # because a silent skip lets a green run imply a check that never happened.
        case "$out" in
          *"manifest unknown"*|*"not found"*|*NotFound*|*"does not exist"*|*"repository name not known"*)
            report "$ref does not resolve in its registry — ADR-0034 (this is how redpanda:v26.1 shipped)" ;;
          *toomanyrequests*|*"rate limit"*|*[Uu]nauthorized*|*"authentication required"*)
            echo "  ??    inconclusive: $ref — registry refused the query (rate limit or auth), not a missing tag" ;;
          *"no such host"*|*"connection refused"*|*timeout*|*"TLS handshake"*)
            echo "  ??    inconclusive: $ref — could not reach the registry" ;;
          *)
            echo "  ??    inconclusive: $ref — unrecognised registry error: $(printf '%s' "$out" | head -1)" ;;
        esac
      fi
    done <<EOF
$all_want
EOF
  fi
else
  echo "  skip  registry resolution (set CHECK_IMAGE_RESOLVE=1; needs network) — ADR-0034"
fi

if [ "$fail" -ne 0 ]; then echo "dev-images: FAIL"; exit 1; fi
echo "dev-images: OK"

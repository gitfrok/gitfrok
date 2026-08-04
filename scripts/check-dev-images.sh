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
MANIFESTS="postgres.yaml valkey.yaml redpanda.yaml seaweedfs.yaml zitadel.yaml hello.yaml"

fail=0
report() { echo "DEV-IMAGE DRIFT: $1"; fail=1; }

[ -f "$VERSIONS" ] || { echo "dev-images: FAIL — $VERSIONS not found"; exit 1; }

set -a
# Literal path, not "$VERSIONS": shellcheck can only reason about a constant source (SC1090).
# shellcheck disable=SC1091  # data file, not a script — nothing for shellcheck to follow
. ./deploy/dev/versions.env
set +a

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

# A floating tag is whatever the node last pulled — the opposite of a version floor of record.
# Reported, not failed: versions.env ships one today (ADR-0031-style follow-up, not a regression).
case "$all_want" in
  *:latest*) echo "  WARN  a tag in $VERSIONS is ':latest' — not reproducible (ADR-0023)" ;;
esac

if [ "$fail" -ne 0 ]; then echo "dev-images: FAIL"; exit 1; fi
echo "dev-images: OK"

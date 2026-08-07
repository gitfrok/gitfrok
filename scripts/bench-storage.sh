#!/usr/bin/env bash
# T-0007 driver: run bench-git-workload.sh on SeaweedFS-FUSE and on a block-backed directory, and
# emit both results plus the remount durability check that the inner script cannot do for itself.
#
# ADR-0020 left one knob open: is FUSE viable for LIVE bare repos, or are block volumes the only
# option? ADR-0016 assumes block. This settles it with measurements instead of opinion.
#
# EXPERIMENT DESIGN — read before trusting a number:
#
#   Both arms sit on the SAME physical disk. The block arm is a host directory; the FUSE arm is a
#   SeaweedFS filer whose volume store is a host directory on that same disk. So the delta between
#   the arms isolates the storage *path* (FUSE + filer + chunked object store) from the device, which
#   is the comparison ADR-0020 actually asks for. It does NOT reproduce cloud block-volume latency,
#   network hops between pods, or a multi-node filer — absolute numbers from a workstation are
#   directional only, and the result doc says so.
#
#   The correctness verdicts do not have that caveat. O_EXCL atomicity, rename() atomicity and
#   fsync-then-remount are properties of the filesystem implementation, not of the hardware it runs
#   on. A backend that fails them here fails them on any cluster.
#
# Requires podman (rootless is fine) and /dev/fuse. Writes results under --out.
set -euo pipefail

# count_to replaces `seq`, which is not guaranteed to exist: stock macOS ships `jot` instead, and
# T-0003 AC4 requires these scripts to work there. The failure mode is what makes this worth avoiding
# rather than documenting — with `seq` missing, `for i in $(seq 1 N)` iterates **zero** times under
# `set -e` instead of failing, so a benchmark or a wait-loop silently does nothing and reports success.
# This is POSIX shell arithmetic and depends on no external command.
count_to() { # count_to <n> — print 1..n, one per line
  local i=1
  while [ "$i" -le "$1" ]; do printf '%s\n' "$i"; i=$((i + 1)); done
}

cd "$(dirname "$0")/.."

SEAWEEDFS_IMAGE=$(awk -F= '/^SEAWEEDFS_IMAGE=/{print $2}' deploy/dev/versions.env)
[ -n "$SEAWEEDFS_IMAGE" ] || { echo "SEAWEEDFS_IMAGE not found in deploy/dev/versions.env"; exit 1; }

out="bench-results"
repeats=3
concurrency=4
size_mb=24
keep=false

usage() {
  cat >&2 <<'USAGE'
usage: bench-storage.sh [--out DIR] [--repeats N] [--concurrency N] [--size-mb N] [--keep]
  --out          results directory (default ./bench-results)
  --repeats      timed samples per operation (default 3)
  --concurrency  parallel workers (default 4)
  --size-mb      fixture payload size in MiB (default 24)
  --keep         keep the bench container and scratch data for inspection
USAGE
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out) out=${2:-}; shift 2 ;;
    --repeats) repeats=${2:-}; shift 2 ;;
    --concurrency) concurrency=${2:-}; shift 2 ;;
    --size-mb) size_mb=${2:-}; shift 2 ;;
    --keep) keep=true; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

command -v podman >/dev/null || { echo "podman not installed"; exit 1; }
[ -c /dev/fuse ] || { echo "/dev/fuse missing — the FUSE arm cannot run on this host"; exit 1; }

# Scratch lives outside the repo and outside /tmp on purpose: /tmp is tmpfs on many hosts, and
# benchmarking a "block volume" against RAM would produce a flattering number for the wrong reason.
scratch=${BENCH_SCRATCH:-$HOME/.cache/gitfrok-bench}
mkdir -p "$scratch/block" "$scratch/seaweed-data" "$out"

# Filesystem type, portably — and it must be *known*, not assumed.
#
# This was `stat -f -c %T "$scratch" 2>/dev/null || echo unknown`. Both `-c` and the combined `-f`
# filesystem mode are GNU coreutils syntax; BSD `stat` (so macOS, T-0003 AC4) has neither. There the
# call failed, the redirect swallowed the error, `fstype` became "unknown", and the guard below waved
# it through — so the one check standing between this benchmark and a flattering tmpfs number was
# inert on exactly the platform nobody had run it on. A silent fallback to "unknown" is worse than no
# check, because the output looks equally authoritative either way (T-0007's verdict fed ADR-0033).
detect_fstype() { # detect_fstype <path>  -> prints type, non-zero if undeterminable
  local path="$1" out mp
  # GNU coreutils.
  if out=$(stat -f -c %T "$path" 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"; return 0
  fi
  # No GNU stat. `df -P` names the mount point, then `mount` names that mount's type — in one of two
  # formats, so both are matched:
  #   BSD/macOS:  /dev/disk1s5 on / (apfs, local, journaled)
  #   Linux:      /dev/nvme0n1p3 on /home type btrfs (rw,relatime)
  # Mount points containing spaces or regex metacharacters defeat this; that is a documented limit
  # rather than a silent one, because the caller refuses to run when detection fails.
  mp=$(df -P "$path" 2>/dev/null | awk 'NR==2 {print $NF}')
  [ -n "$mp" ] || return 1
  out=$(mount 2>/dev/null | sed -n \
    -e "s|^.* on ${mp} type \([^ ]*\) .*|\1|p" \
    -e "s|^.* on ${mp} (\([^,)]*\).*|\1|p" | head -1)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

if fstype=$(detect_fstype "$scratch"); then
  case "$fstype" in
    tmpfs|ramfs|devtmpfs)
      echo "refusing to run: scratch $scratch is $fstype (RAM). Set BENCH_SCRATCH to a real disk."
      exit 1 ;;
  esac
elif [ "${BENCH_ALLOW_UNKNOWN_FS:-0}" = "1" ]; then
  fstype="unknown (BENCH_ALLOW_UNKNOWN_FS=1)"
else
  echo "refusing to run: cannot determine the filesystem type of $scratch, so the RAM-disk guard"
  echo "cannot be applied. Benchmarking a 'block volume' that is really tmpfs produces a flattering"
  echo "number for the wrong reason, which is what this guard exists to prevent."
  echo "Point BENCH_SCRATCH at a path on a filesystem this can identify, or set"
  echo "BENCH_ALLOW_UNKNOWN_FS=1 to proceed and have the result recorded as unverified."
  exit 1
fi

container=t0007-bench
podman rm -f "$container" >/dev/null 2>&1 || true

echo "== T-0007 storage benchmark"
echo "   image:       $SEAWEEDFS_IMAGE"
echo "   scratch:     $scratch ($fstype)"
echo "   params:      repeats=$repeats concurrency=$concurrency size_mb=$size_mb"
echo

# One container holds both arms so the FUSE mount and the block directory are in the same mount
# namespace and the same kernel page cache regime — otherwise the comparison would smuggle in a
# container-boundary difference.
podman run -d --name "$container" \
  --device /dev/fuse --cap-add SYS_ADMIN \
  -v "$scratch/block":/bench/block:z \
  -v "$scratch/seaweed-data":/seaweed:z \
  -v "$PWD/scripts/bench-git-workload.sh":/usr/local/bin/bench-git-workload.sh:ro,z \
  --entrypoint sleep "$SEAWEEDFS_IMAGE" infinity >/dev/null

cleanup() {
  if [ "$keep" = true ]; then
    echo "-- keeping container '$container' and $scratch (--keep)"
  else
    podman exec "$container" sh -c 'umount /mnt/seaweed 2>/dev/null || true' >/dev/null 2>&1 || true
    podman rm -f "$container" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# git is what we measure; coreutils is for a date(1) with %N (busybox has none, so every fast
# operation would time as 0 ms); bash is for the inner script's arrays. An in-cluster run needs the
# same three in whatever image it uses.
echo "-- installing git + coreutils + bash in the bench container"
podman exec "$container" apk add --no-cache git coreutils bash >/dev/null 2>&1

echo "-- starting SeaweedFS (master + volume + filer) and mounting it"
# -ip.bind=0.0.0.0 and -ip=127.0.0.1 are load-bearing, not boilerplate. By default weed binds to the
# interface address it detects (192.168.x.y in a container) and nothing answers on loopback, so both
# the readiness probe and `weed mount -filer=localhost:8888` fail while the filer is perfectly
# healthy — which reads as "SeaweedFS is broken" when the truth is "we asked the wrong address".
podman exec -d "$container" sh -c \
  'weed server -dir=/seaweed -filer -ip=127.0.0.1 -ip.bind=0.0.0.0 -master.volumeSizeLimitMB=256 -volume.max=20 >/var/log/weed.log 2>&1'

# Wait for the filer to serve a real request rather than sleeping a fixed interval: on a cold volume
# store the master needs noticeably longer, and a fixed sleep would either flake or waste time.
# The path carries a query because the filer's bare "/" is not a reliable 2xx.
filer_up=false
for _ in $(count_to 60); do
  if podman exec "$container" wget -qO- 'http://127.0.0.1:8888/?limit=1' >/dev/null 2>&1; then filer_up=true; break; fi
  sleep 1
done
[ "$filer_up" = true ] || { echo "filer did not come up; see: podman exec $container cat /var/log/weed.log"; exit 1; }

podman exec "$container" mkdir -p /mnt/seaweed
podman exec -d "$container" sh -c \
  'weed mount -filer=127.0.0.1:8888 -dir=/mnt/seaweed -filer.path=/ >/var/log/weed-mount.log 2>&1'

mount_up=false
for _ in $(count_to 60); do
  if podman exec "$container" sh -c 'echo probe > /mnt/seaweed/.probe 2>/dev/null && rm -f /mnt/seaweed/.probe'; then
    mount_up=true; break
  fi
  sleep 1
done
[ "$mount_up" = true ] || { echo "weed mount not writable; see: podman exec $container cat /var/log/weed-mount.log"; exit 1; }
echo "   mounted."
echo

run_arm() { # run_arm <label> <target-dir>
  local label=$1 target=$2
  echo "-- arm: $label ($target)"
  podman exec "$container" bench-git-workload.sh \
    --target "$target" --label "$label" \
    --repeats "$repeats" --concurrency "$concurrency" --size-mb "$size_mb" \
    > "$out/$label.json"
  echo "   wrote $out/$label.json"
}

run_arm block /bench/block
run_arm seaweedfs-fuse /mnt/seaweed/bench

# --- durability across a remount ------------------------------------------------------------------
# The inner script verified fsync() returned success and the bytes read back. That passes even if the
# data is sitting in the FUSE client's buffer. Remounting forces it to come from the filer, which is
# the difference between "fsync returned 0" and "the push is durable".
echo
echo "-- remount durability check (FUSE arm)"
# Match the key, not a field position: the first attempt took field 4 of the fsync line and got the
# literal string "pass", which made the durability check compare garbage and report a false negative.
marker_payload=$(grep -o '"payload": *"[^"]*"' "$out/seaweedfs-fuse.json" | head -1 | sed 's/.*: *"//; s/"$//')
podman exec "$container" sh -c 'umount /mnt/seaweed' >/dev/null 2>&1 || true
podman exec -d "$container" sh -c \
  'weed mount -filer=127.0.0.1:8888 -dir=/mnt/seaweed -filer.path=/ >>/var/log/weed-mount.log 2>&1'
remount_ok=false
for _ in $(count_to 60); do
  if podman exec "$container" sh -c 'test -d /mnt/seaweed/bench' >/dev/null 2>&1; then remount_ok=true; break; fi
  sleep 1
done
after=""
if [ "$remount_ok" = true ]; then
  after=$(podman exec "$container" sh -c 'cat /mnt/seaweed/bench/probe-fsync.marker 2>/dev/null' || true)
fi
durable=false
[ -n "$marker_payload" ] && [ "$after" = "$marker_payload" ] && durable=true
cat > "$out/remount-durability.json" <<JSON
{
  "arm": "seaweedfs-fuse",
  "remounted": $remount_ok,
  "expected_payload": "$marker_payload",
  "observed_payload": "$after",
  "durable_across_remount": $durable
}
JSON
echo "   durable_across_remount=$durable → $out/remount-durability.json"

# --- summary --------------------------------------------------------------------------------------
echo
echo "== summary"
for f in "$out/block.json" "$out/seaweedfs-fuse.json"; do
  awk '
    /"label"/       { gsub(/[",]/, "", $2); label = $2 }
    /"push":/       { push = $0 }
    /"clone":/      { clone = $0 }
    /"gc":/         { gc = $0 }
    /"status":/     { status = $0 }
    /"push_mib_s"/  { gsub(/[",]/, "", $2); mib = $2 }
    /"o_excl_single_winner"/ { excl = $0 }
    /"rename_atomic"/        { ren = $0 }
    /"contended_push_single_winner"/ { cont = $0 }
    /"fsck_after_contention"/        { fsck = $0 }
    END {
      printf "  %s:\n", label
      printf "    push_mib_s=%s\n", mib
      printf "   %s\n   %s\n   %s\n   %s\n", push, clone, gc, status
      printf "   %s\n   %s\n   %s\n   %s\n", excl, ren, cont, fsck
    }
  ' "$f"
done
echo
echo "Raw JSON in $out/. Absolute latencies are workstation-directional; the correctness verdicts are not."

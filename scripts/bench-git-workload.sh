#!/usr/bin/env bash
# T-0007 inner workload: measure git on ONE storage backend and probe its POSIX semantics.
#
# Backend-agnostic on purpose. It takes a directory and knows nothing about how that directory is
# backed, so the same script runs on a FUSE mount, a block volume, a PVC in a pod, or a laptop disk.
# The driver (bench-storage.sh) provisions the arms and calls this twice; a future in-cluster run
# calls it from a Job without changing a line here. Reproducibility is the AC: the fixture is
# generated from a fixed seed, so two runs measure the same bytes.
#
# Emits one JSON object on stdout. Diagnostics go to stderr so the output stays machine-readable.
#
# The correctness probes matter more than the timings. Git's ref updates rely on three filesystem
# guarantees: O_CREAT|O_EXCL is atomic (that is what a .lock file *is*), rename() over an existing
# path is atomic, and fsync() means durable. A backend that misses any of them can lose or corrupt a
# ref under concurrent pushes no matter how fast it is — a verdict that does not depend on hardware,
# which is why it can be reached on a laptop while the latency numbers cannot.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: bench-git-workload.sh --target DIR --label NAME [--repeats N] [--concurrency N] [--size-mb N]
  --target       directory on the backend under test (created if absent)
  --label        name for this arm in the output, e.g. "block" or "seaweedfs-fuse"
  --repeats      timed samples per operation (default 3)
  --concurrency  parallel workers for the contention phases (default 4)
  --size-mb      approximate fixture payload size in MiB (default 24)
USAGE
  exit 2
}

target="" label="" repeats=3 concurrency=4 size_mb=24
while [ $# -gt 0 ]; do
  case "$1" in
    --target) target=${2:-}; shift 2 ;;
    --label) label=${2:-}; shift 2 ;;
    --repeats) repeats=${2:-}; shift 2 ;;
    --concurrency) concurrency=${2:-}; shift 2 ;;
    --size-mb) size_mb=${2:-}; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
if [ -z "$target" ] || [ -z "$label" ]; then usage; fi

command -v git >/dev/null || { echo "git not installed" >&2; exit 1; }
# busybox date has no %N, so a coreutils date is a hard requirement: without sub-second resolution
# every fast operation would round to 0 ms and the comparison would be silently meaningless.
date +%s.%N | grep -q '\.' || { echo "need a date(1) supporting %N (coreutils)" >&2; exit 1; }

now_ms() { date +%s.%N | awk '{printf "%.3f", $1 * 1000}'; }
elapsed_ms() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b - a}'; }

# JSON helpers. Hand-rolled because the bench image has no jq and adding one more dependency to a
# script whose whole job is to be runnable anywhere is a bad trade.
json_array() { # json_array 1.0 2.0 -> [1.0,2.0]
  local out="" v
  for v in "$@"; do out="${out:+$out,}$v"; done
  printf '[%s]' "$out"
}

work=$(mktemp -d)
cleanup() { rm -rf "$work" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$target"

# --- fixture -------------------------------------------------------------------------------------
# A deterministic repo: fixed file count and sizes, content from a fixed seed, fixed commit metadata
# so object IDs are identical across runs and arms. Without the fixed dates the same content would
# produce different commits and different pack sizes.
fixture="$work/src"
mkdir -p "$fixture"
git -C "$fixture" init -q -b main
git -C "$fixture" config user.email bench@gitfrok.test
git -C "$fixture" config user.name "T-0007 bench"

files=24
per_file_kb=$(( size_mb * 1024 / files ))
[ "$per_file_kb" -gt 0 ] || per_file_kb=1
commits=8
seed=20260806

echo "[$label] building fixture: ${files} files x ${per_file_kb}KB over ${commits} commits" >&2
for c in $(seq 1 "$commits"); do
  for f in $(seq 1 "$files"); do
    # Deterministic pseudo-random payload: awk PRNG with a per-(commit,file) seed. Compressible
    # enough to be realistic for source trees, varied enough that packs are not degenerate.
    awk -v s="$((seed + c * 100 + f))" -v kb="$per_file_kb" 'BEGIN{
      srand(s); n = kb * 1024 / 64;
      for (i = 0; i < n; i++) {
        line = "";
        for (j = 0; j < 8; j++) line = line sprintf("%08x", int(rand() * 4294967295));
        print line;
      }
    }' > "$fixture/file-$f.dat"
  done
  git -C "$fixture" add -A
  GIT_AUTHOR_DATE="@$((1780000000 + c * 3600)) +0000" \
  GIT_COMMITTER_DATE="@$((1780000000 + c * 3600)) +0000" \
    git -C "$fixture" commit -q -m "fixture commit $c"
done
fixture_bytes=$(du -sk "$fixture/.git" | awk '{print $1 * 1024}')

# --- timed phases --------------------------------------------------------------------------------
# Each phase is re-created from scratch per sample: a push into a warm repo measures something else
# entirely, and re-using one repo would let sample N inherit sample N-1's page cache and packfiles.
push_ms=() clone_ms=() gc_ms=() status_ms=()

for r in $(seq 1 "$repeats"); do
  bare="$target/bench-$r.git"
  rm -rf "$bare"
  git init -q --bare -b main "$bare"

  t0=$(now_ms)
  git -C "$fixture" push -q "$bare" main
  t1=$(now_ms)
  push_ms+=("$(elapsed_ms "$t0" "$t1")")

  t0=$(now_ms)
  git clone -q "$bare" "$work/clone-$r"
  t1=$(now_ms)
  clone_ms+=("$(elapsed_ms "$t0" "$t1")")

  t0=$(now_ms)
  git -C "$bare" gc -q --prune=now
  t1=$(now_ms)
  gc_ms+=("$(elapsed_ms "$t0" "$t1")")

  # status is a worktree operation, so it is measured on a worktree that lives on the backend —
  # measuring it on a bare repo would measure nothing.
  wt="$target/worktree-$r"
  rm -rf "$wt"
  git clone -q "$bare" "$wt"
  t0=$(now_ms)
  git -C "$wt" status --porcelain >/dev/null
  t1=$(now_ms)
  status_ms+=("$(elapsed_ms "$t0" "$t1")")

  rm -rf "$work/clone-$r" "$wt"
  [ "$r" -eq "$repeats" ] || rm -rf "$bare"
done

pack_bytes=$(du -sk "$target/bench-$repeats.git" | awk '{print $1 * 1024}')
push_mib_s=$(awk -v b="$fixture_bytes" -v arr="$(json_array "${push_ms[@]}")" 'BEGIN{
  gsub(/[\[\]]/, "", arr); n = split(arr, a, ","); s = 0;
  for (i = 1; i <= n; i++) s += a[i];
  ms = s / n; if (ms <= 0) { print "null"; exit }
  printf "%.2f", (b / 1048576) / (ms / 1000);
}')

# --- concurrent throughput -----------------------------------------------------------------------
# Distinct branches, so every push should succeed: this is the throughput number, uncontended by
# design. Contention is the next phase and is a correctness question, not a speed one.
conc_bare="$target/concurrent.git"
rm -rf "$conc_bare"
git init -q --bare -b main "$conc_bare"
git -C "$fixture" push -q "$conc_bare" main

t0=$(now_ms)
conc_pids=()
for w in $(seq 1 "$concurrency"); do
  (
    git -C "$fixture" push -q "$conc_bare" "main:refs/heads/worker-$w" 2>/dev/null
  ) &
  conc_pids+=("$!")
done
conc_ok=0
for p in "${conc_pids[@]}"; do
  if wait "$p"; then conc_ok=$((conc_ok + 1)); fi
done
t1=$(now_ms)
conc_ms=$(elapsed_ms "$t0" "$t1")
conc_ops_s=$(awk -v n="$conc_ok" -v ms="$conc_ms" 'BEGIN{ if (ms <= 0) print "null"; else printf "%.2f", n / (ms / 1000) }')

# --- correctness: O_CREAT|O_EXCL is atomic -------------------------------------------------------
# `set -C` makes `> file` use O_EXCL. This is exactly how git creates refs/heads/x.lock, and exactly
# what serialises two pushes racing for the same ref. If more than one racer wins, two pushes can
# hold the same lock and the last writer silently wins.
excl_dir="$target/probe-excl"
rm -rf "$excl_dir"; mkdir -p "$excl_dir"
excl_winners=0
excl_pids=()
for w in $(seq 1 "$concurrency"); do
  (
    set -C
    if : > "$excl_dir/the.lock" 2>/dev/null; then exit 0; else exit 1; fi
  ) &
  excl_pids+=("$!")
done
for p in "${excl_pids[@]}"; do
  if wait "$p"; then excl_winners=$((excl_winners + 1)); fi
done

# --- correctness: rename() over an existing path is atomic ---------------------------------------
# A reader must never observe a partial or empty target. Git commits a ref by renaming the .lock over
# the ref file; a non-atomic rename means a concurrent reader can see a torn ref.
ren_dir="$target/probe-rename"
rm -rf "$ren_dir"; mkdir -p "$ren_dir"
a_val="AAAAAAAAAAAAAAAA" b_val="BBBBBBBBBBBBBBBB"
printf '%s' "$a_val" > "$ren_dir/target"
(
  for _ in $(seq 1 60); do
    printf '%s' "$a_val" > "$ren_dir/tmp.a"; mv -f "$ren_dir/tmp.a" "$ren_dir/target"
    printf '%s' "$b_val" > "$ren_dir/tmp.b"; mv -f "$ren_dir/tmp.b" "$ren_dir/target"
  done
) &
ren_writer=$!
ren_torn=0 ren_failed=0 ren_reads=0
for _ in $(seq 1 200); do
  ren_reads=$((ren_reads + 1))
  got=$(cat "$ren_dir/target" 2>/dev/null || echo "READ_FAILED")
  case "$got" in
    "$a_val"|"$b_val") ;;
    READ_FAILED) ren_failed=$((ren_failed + 1)) ;;
    *) ren_torn=$((ren_torn + 1)) ;;
  esac
done
ren_anomalies=$((ren_torn + ren_failed))
wait "$ren_writer" 2>/dev/null || true

# --- correctness: git's OWN ref-update race -------------------------------------------------------
# The rename probe above uses mv(1), which is a proxy with a loophole: if rename(2) returns EXDEV,
# coreutils mv silently degrades to copy+unlink, and the ENOENT window would be mv's doing rather
# than the filesystem's. This probe removes the proxy. `git update-ref` performs the real thing —
# write refs/heads/race.lock, then rename(2) it over refs/heads/race — and reports an error if the
# rename fails. Readers run `git rev-parse --verify`, which is what a concurrent fetch, push
# fast-forward check or upload-pack ref advertisement does.
#
# Interpreting the two failure columns:
#   writer_errors > 0  -> rename(2) itself fails on this backend; git cannot update a ref at all
#   reader_misses > 0  -> rename(2) succeeds but is not atomic: a ref momentarily does not exist,
#                         so a concurrent reader concludes the branch is gone
ref_repo="$target/probe-refrace.git"
rm -rf "$ref_repo"
git init -q --bare -b main "$ref_repo"
git -C "$fixture" push -q "$ref_repo" main
sha1=$(git -C "$fixture" rev-parse HEAD)
sha2=$(git -C "$fixture" rev-parse HEAD~1)
git -C "$ref_repo" update-ref refs/heads/race "$sha1"

ref_writer_errors=0
(
  for _ in $(seq 1 80); do
    git -C "$ref_repo" update-ref refs/heads/race "$sha2" 2>>"$work/ref-writer.err" || echo x >> "$work/ref-writer.fail"
    git -C "$ref_repo" update-ref refs/heads/race "$sha1" 2>>"$work/ref-writer.err" || echo x >> "$work/ref-writer.fail"
  done
) &
ref_writer=$!
ref_reader_misses=0 ref_reads=0
while kill -0 "$ref_writer" 2>/dev/null; do
  ref_reads=$((ref_reads + 1))
  if ! git -C "$ref_repo" rev-parse --verify -q refs/heads/race >/dev/null 2>&1; then
    ref_reader_misses=$((ref_reader_misses + 1))
  fi
done
wait "$ref_writer" 2>/dev/null || true
[ -f "$work/ref-writer.fail" ] && ref_writer_errors=$(wc -l < "$work/ref-writer.fail" | tr -d ' ')

# --- correctness: fsync reports success and data reads back --------------------------------------
# True crash-durability needs a crash. What is testable here is that fsync() does not error and the
# bytes are visible afterwards; the driver re-checks the same marker after a remount, which is what
# catches a backend that acknowledges fsync while holding data in a client-side buffer.
fsync_marker="$target/probe-fsync.marker"
fsync_payload="t-0007-durability-$seed"
fsync_ok=true
printf '%s' "$fsync_payload" > "$work/marker"
if ! dd if="$work/marker" of="$fsync_marker" conv=fsync status=none 2>/dev/null; then
  fsync_ok=false
fi
[ "$(cat "$fsync_marker" 2>/dev/null || true)" = "$fsync_payload" ] || fsync_ok=false

# --- correctness: contended pushes to ONE ref, then fsck -----------------------------------------
# Each worker pushes a different commit to the same branch. Git must accept at most one and reject
# the rest as non-fast-forward; what must never happen is two winners or a corrupt repo.
same_bare="$target/contended.git"
rm -rf "$same_bare"
git init -q --bare -b main "$same_bare"
git -C "$fixture" push -q "$same_bare" main

same_ok=0 same_rejected=0
same_pids=()
for w in $(seq 1 "$concurrency"); do
  wt="$work/contend-$w"
  git clone -q "$same_bare" "$wt" 2>/dev/null
  git -C "$wt" config user.email bench@gitfrok.test
  git -C "$wt" config user.name "T-0007 bench"
  echo "worker $w divergent" > "$wt/contended-$w.txt"
  git -C "$wt" add -A
  GIT_AUTHOR_DATE="@$((1780000000 + w)) +0000" GIT_COMMITTER_DATE="@$((1780000000 + w)) +0000" \
    git -C "$wt" commit -q -m "contended $w"
done
for w in $(seq 1 "$concurrency"); do
  ( git -C "$work/contend-$w" push -q origin main 2>/dev/null ) &
  same_pids+=("$!")
done
for p in "${same_pids[@]}"; do
  if wait "$p"; then same_ok=$((same_ok + 1)); else same_rejected=$((same_rejected + 1)); fi
done

fsck_exit=0
git -C "$same_bare" fsck --strict >/dev/null 2>&1 || fsck_exit=$?

# --- output --------------------------------------------------------------------------------------
excl_pass=false; [ "$excl_winners" -eq 1 ] && excl_pass=true
ren_pass=false; [ "$ren_anomalies" -eq 0 ] && ren_pass=true
same_pass=false; [ "$same_ok" -eq 1 ] && same_pass=true
fsck_pass=false; [ "$fsck_exit" -eq 0 ] && fsck_pass=true
ref_pass=false; [ "$ref_reader_misses" -eq 0 ] && [ "$ref_writer_errors" -eq 0 ] && ref_pass=true

cat <<JSON
{
  "label": "$label",
  "target": "$target",
  "git_version": "$(git --version | awk '{print $3}')",
  "params": { "repeats": $repeats, "concurrency": $concurrency, "size_mb": $size_mb },
  "fixture": { "files": $files, "per_file_kb": $per_file_kb, "commits": $commits, "git_dir_bytes": $fixture_bytes, "packed_bare_bytes": $pack_bytes },
  "latency_ms": {
    "push": $(json_array "${push_ms[@]}"),
    "clone": $(json_array "${clone_ms[@]}"),
    "gc": $(json_array "${gc_ms[@]}"),
    "status": $(json_array "${status_ms[@]}")
  },
  "throughput": {
    "push_mib_s": $push_mib_s,
    "concurrent_push_ops_s": $conc_ops_s,
    "concurrent_push_ok": $conc_ok,
    "concurrent_push_total": $concurrency
  },
  "correctness": {
    "o_excl_single_winner": { "winners": $excl_winners, "expected": 1, "pass": $excl_pass },
    "rename_atomic": { "reads": $ren_reads, "torn_reads": $ren_torn, "failed_reads": $ren_failed, "anomalies": $ren_anomalies, "expected": 0, "pass": $ren_pass },
    "fsync_write_readback": { "pass": $fsync_ok, "marker": "$fsync_marker", "payload": "$fsync_payload" },
    "contended_push_single_winner": { "accepted": $same_ok, "rejected": $same_rejected, "expected_accepted": 1, "pass": $same_pass },
    "fsck_after_contention": { "exit": $fsck_exit, "pass": $fsck_pass },
    "git_ref_update_race": { "reads": $ref_reads, "reader_misses": $ref_reader_misses, "writer_errors": $ref_writer_errors, "expected": 0, "pass": $ref_pass }
  }
}
JSON

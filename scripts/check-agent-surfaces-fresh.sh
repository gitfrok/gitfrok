#!/usr/bin/env bash
# Super-repo fitness function: all sixteen agent surfaces match the canonical sources they are
# generated from. ADR-0037 decision 3.
#
# WHY THIS LIVES HERE and not in each repo: governance owns the canonical sources and gates its own
# three surfaces, but the other thirteen live in submodules a standalone governance run does not
# have. The composition is the only place all five repos exist at once — the same boundary
# check-codegen-fresh.sh documents for generated protobuf, and for the same reason.
#
# What drift means: someone hand-edited AGENTS.md, CLAUDE.md, opencode.json or the .cursor rule
# instead of editing governance/canonical/agent-surfaces/ and regenerating. That is how five
# CLAUDE.md files came to disagree with invariant 7 after ADR-0033 rewrote it, and it is why
# ADR-0037 exists. It can also mean a submodule pin moved without the surfaces being regenerated,
# which is the same defect the codegen check catches for contracts/.
set -euo pipefail
cd "$(dirname "$0")/.."

GEN=governance/scripts/gen-agent-surfaces.sh
CANON=governance/canonical/agent-surfaces

fail=0
report() { echo "AGENT SURFACE VIOLATION: $1"; fail=1; }

# A missing prerequisite is a hard failure, not a skip. A gate that quietly does nothing is worse
# than no gate: the green check then stands as evidence of something nobody verified.
missing=()
[ -x "$GEN" ] || missing+=("$GEN (git submodule update --init governance)")
[ -f "$CANON/manifest.tsv" ] || missing+=("$CANON/manifest.tsv")
if [ ${#missing[@]} -ne 0 ]; then
  echo "cannot check agent surfaces, missing: ${missing[*]}"
  exit 1
fi

# surface_paths <repo> — the destinations that repo's files.tsv declares, one per line.
surface_paths() {
  local repo=$1 template dest
  while IFS=$'\t' read -r template dest; do
    case "$template" in ''|\#*) continue ;; esac
    printf '%s\n' "$dest"
  done < "$CANON/repos/$repo/files.tsv"
}

repos=()
paths=()
while IFS=$'\t' read -r repo path _gov; do
  case "$repo" in ''|\#*) continue ;; esac

  files="$CANON/repos/$repo/files.tsv"
  [ -f "$files" ] || { report "$CANON/repos/$repo/files.tsv is missing but the manifest lists $repo"; continue; }

  # "." is the manifest's way of saying the super-repo itself.
  work=.
  [ "$path" = "." ] || work=$path

  if [ ! -e "$work/.git" ]; then
    report "$repo is not checked out — run 'git submodule update --init $path'"
    continue
  fi

  # A surface that is already dirty before generating is indistinguishable from drift afterwards.
  dirty=0
  while IFS= read -r dest; do
    if [ -n "$(git -C "$work" status --porcelain -- "$dest")" ]; then
      report "$path/$dest is already dirty before generating — commit or stash it first"
      dirty=1
    fi
  done < <(surface_paths "$repo")
  [ "$dirty" -eq 0 ] || continue

  repos+=("$repo")
  paths+=("$work")
done < "$CANON/manifest.tsv"

[ "$fail" -eq 0 ] || { echo; echo "agent surfaces: cannot verify (see above)"; exit 1; }

if ! out=$("$GEN" "$PWD" "${repos[@]}" 2>&1); then
  report "generator failed:"
  while IFS= read -r line; do printf '          %s\n' "$line"; done <<<"$out"
  exit 1
fi

checked=0
for i in "${!repos[@]}"; do
  repo=${repos[$i]}
  work=${paths[$i]}

  drift=""
  while IFS= read -r dest; do
    checked=$((checked + 1))
    d=$(git -C "$work" status --porcelain -- "$dest")
    [ -n "$d" ] && drift+="$dest"$'\n'
  done < <(surface_paths "$repo")

  if [ -n "$drift" ]; then
    report "$repo does not match $CANON:"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '          %s\n' "$line"
      git -C "$work" --no-pager diff -- "$line" | sed 's/^/            /'
    done <<<"$drift"
    echo "          fix: edit governance/canonical/agent-surfaces/, then run"
    echo "               ./governance/scripts/gen-agent-surfaces.sh . $repo"
    echo "               and commit the result in $repo — never hand-edit the output"
  else
    echo "  ok    $repo"
  fi

  # Leave the tree as it was, so a local run is a diagnosis and not an edit. The generator only
  # ever writes the declared destinations, so restoring those is enough.
  while IFS= read -r dest; do
    git -C "$work" checkout -- "$dest" 2>/dev/null || true
  done < <(surface_paths "$repo")
done

if [ "$fail" -ne 0 ]; then
  echo "agent surfaces: DRIFT (see above) — ADR-0037"
  exit 1
fi
echo "agent surfaces: OK ($checked files across ${#repos[@]} repos)"

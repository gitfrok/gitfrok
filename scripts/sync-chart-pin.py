#!/usr/bin/env python3
"""Point the BYO chart's image pins at the registry a publish just wrote to.

ADR-0098 decision 4 retires `docker.io/gitfrok/*` from the tree. The chart could not be
converted with the rest of it, because the replacement reference is not knowable until an
image is pushed and the registry returns its digest. This runs at that moment, from
`.github/workflows/image-publish.yml`, once per published component.

It matters beyond tidiness: `scripts/check-signed-releases.sh` cross-asserts that
values.yaml's operator pin equals the signed release manifest's `oci_ref` and `digest`, and
the publish workflow runs that gate on what it just wrote. Without this the run publishes and
signs six images, then fails its own gate on drift it created a step earlier.

Python rather than `sed -i -E` because BSD sed reads `-E` as `-i`'s backup suffix, so the
expression cannot be tested on a macOS workstation before it runs on a Linux runner — which is
the same portability rule `scripts/check-shell-portability.sh` enforces for shell.

Unknown components are a no-op: `git-storaged` and `controlplane-app` are not chart inputs.
"""
import re
import sys

VALUES = "deploy/helm/gitfrok-dataplane/values.yaml"
DIGEST_RE = re.compile(r'^(\s*digest:\s*")sha256:[0-9a-f]{64}(")\s*$')


def repo_re(component: str) -> re.Pattern:
    return re.compile(r"^(\s*repository:\s*)\S*" + re.escape(component) + r"\s*$")


def main(component: str, ref: str, digest: str) -> int:
    # Only these two are chart inputs; the operator additionally carries a digest pin.
    if component not in ("operator-app", "dataplane-app"):
        return 0
    with open(VALUES, encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    rre = repo_re(component)
    repo_hits = digest_hits = 0
    # The operator's digest is the line immediately following its repository line, and is the
    # only digest in the file — anchor on the repository match so a future second digest
    # elsewhere cannot be rewritten by accident.
    for i, line in enumerate(lines):
        if rre.match(line):
            lines[i] = rre.sub(r"\g<1>" + ref, line)
            repo_hits += 1
            if component == "operator-app":
                for j in range(i + 1, min(i + 4, len(lines))):
                    if DIGEST_RE.match(lines[j]):
                        lines[j] = DIGEST_RE.sub(r"\g<1>" + digest + r"\g<2>", lines[j])
                        digest_hits += 1
                        break

    if repo_hits != 1:
        print(f"sync-chart-pin: expected exactly 1 repository line for {component}, found {repo_hits}", file=sys.stderr)
        return 1
    if component == "operator-app" and digest_hits != 1:
        print("sync-chart-pin: operator repository matched but its digest pin did not", file=sys.stderr)
        return 1

    with open(VALUES, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    print(f"sync-chart-pin: {component} -> {ref}" + (f"@{digest}" if digest_hits else ""))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("usage: sync-chart-pin.py <component> <oci_ref> <digest>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1], sys.argv[2], sys.argv[3]))

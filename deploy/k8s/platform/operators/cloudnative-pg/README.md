# CloudNativePG, vendored

ADR-0099 decision 2 adopts CloudNativePG for Postgres and for Postgres only — the one component in
the stateful set whose failure is unrecoverable, and the one where a hand-written StatefulSet has no
backup story. It is the only operator in this tree.

## The pin

`cnpg-1.27.0.yaml` is the upstream release manifest, unmodified, fetched from

    https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.27/releases/cnpg-1.27.0.yaml

SHA-256:

    7be449085a4c5941ff05d2c4aca47d4f1c4c87698181fe2c19c47a9f6a43b268

`scripts/check-platform-kustomize.sh` asserts that digest on every build. Re-pinning is a
deliberate act: fetch the new release, record its digest here, and let the gate refuse the mismatch
until both agree.

## Why it is committed rather than fetched

SPEC-0069's non-functional section requires the manifest be vendored rather than fetched at apply
time, so an install is reproducible. Fetching at apply time would make a deployment depend on
GitHub's availability and on nobody having moved a tag.

**It is 1.1 MB across 25 documents, and that is not reviewable by reading.** Saying otherwise would
be a comfortable fiction: nobody audits a megabyte of generated CRDs line by line. What is genuinely
verified is the digest above — this is byte-for-byte the artifact upstream published — and what
ADR-0099 accepted is a controller with its own release cadence to own. Those are the honest terms.

## Upgrading

CNPG's own upgrade notes govern; a minor bump is not automatically safe for existing `Cluster`
resources. The obligation ADR-0099 accepted is this one, and it recurs.

# Phase 3.1 plan review — ADR-0062…0066 (+0067 filed in disposition), SPEC-0042…0046, T-0036…T-0044

**Reviewed at:** governance `2e4f744` (working tree; ahead of the super-repo pin `7b7115e` at super-repo
`4747ed8`). Backend `da45212`, bff `e2344de`, webfrontend `0e80261` — unchanged, no Phase 3.1 code exists yet.
**Scope:** planning artifacts only — the phase plan, five ADRs, five specs, nine task files and the
roadmap/backlog/index updates that accompany them.
**Gates:** `governance/scripts/check-docs.sh` → `docs: OK (198 files checked)`. Every finding below is
green under the current gates; none of them is caught by a check.

**Disposition (2026-08-15, same day).** All seven findings were acted on in governance (working tree,
uncommitted): H1 → SPEC-0043 AC6 + T-0038 (verified caller required, applying ADR-0045 — no new ADR);
H2 → SPEC-0042 AC5 (named, bounded token-hash exemption) + T-0036; M3 → SPEC-0044 AC5 + widened AC4,
T-0040 gains the deployment, the repo list and the gate rows; M4 → new SPEC-0042 AC6 + T-0036 AC6;
M5 → "release trust bundle" vs "CA trust bundle" named apart across SPEC-0044/0045, T-0040/0041 and
the plan spine; M6 → plan, roadmap and backlog carry ADR-0066 as the fifth decision and the KMS risk
is replaced by the custody service's real risks; L7 → spec `Task(s)` fields, task ADR headers and the
ADR index's follow-up table. The three ADR-consequence items stay record-only (Accepted ADRs are
superseded, never edited). `check-docs.sh` green after the amendment.

**Follow-on from H1 (same day).** The amendment's own question — *who* the verified caller is allowed
to be — turned out to be an unstated product decision, not a spec gap: bundle 0.9.0 grants
`residency.declaration.set` to the tenant's owner only, so a vendor-side operator cannot declare on a
tenant's behalf. It does **not** need a cross-tenant path: ADR-0046 already fixes a tenant-scoped
`platform_operator` principal with a platform-administered binding, so the tenant stays a property of
the verified principal and SPEC-0043 AC6's no-subject-fields rule survives intact. But ADR-0046
decision 4 confined that role to one action, so extending it is a decision, not a policy edit —
filed as **ADR-0067** — Proposed and then **Accepted the same day** — with SPEC-0043 **AC7** and
T-0038 carrying it, per ADR-0001 and invariant 12. The owner grant is unchanged, `platform_operator`
gains exactly one action, and the wire surface is untouched: no `tenant_id` field. The Rego grant and
its bundle-revision bump ship under T-0038, so bundle 0.9.0 stays owner-only in fact until then.

**Overall.** The plan is well-formed: each carried Phase-3 limit maps to an epic, each epic to a spec, each
spec AC to a task AC, and the backlog/roadmap reclassification is done without duplicating history. The
process was followed (Proposed → Accepted per ADR-0001, additive-only contract change). The findings are
about what the artifacts do not say, and two of them would produce wrong behaviour if implemented as written.

---

## HIGH

### H1 — SPEC-0043's Declare surface has no authenticated caller, and the spec does not say so

SPEC-0043 AC1 rests the entire authorization story on the PDP: *"the surface is a PEP: it asks the PDP action
`residency.declaration.set`, already owner-only and tenant-scoped in bundle 0.9.0."* Neither SPEC-0043,
T-0038 nor the plan mentions how the caller's identity is established.

The rest of the tree says it is not established. Phase 2's carried limit (d)
(`docs/plans/phase-2-ultimate-wedge.md:192`, restated in the roadmap and in SPEC-0002's open questions) records
that the gRPC door takes tenant, actor and roles off the wire with no verified caller, so the PDP decides
correctly about a caller-*asserted* subject. The control plane's own doors carry the same posture today —
`backend/cmd/controlplane-app/main.go:153-172` serves `UsageService` in plaintext with no interceptor
("Dev posture is plaintext"). The agent channel is the exception and not a precedent: it verifies client
certificates at the app layer so every refusal is audited (SPEC-0038 AC5/AC7) — the admin doors have no
analogue.

`residency/v1` is not a read surface. It **writes control state** — the pinning the PlacementGate enforces at
enrolment and the evidence pack cites. Over a caller-asserted subject, "owner-only" means owner-asserted:
anyone who can reach the port can claim to be a tenant owner and repin that tenant's residency, and every
audit record AC1 requires will faithfully name the actor the caller claimed to be.

**Fix:** SPEC-0043 must either require a verified caller for the admin surface (an authn interceptor as a
named AC), or explicitly record that Declare rides limit (d) with the network-isolation assumption stated —
the same way SPEC-0002 records it. Silence is the one option the house style forbids; the phase's own review
history (Phase-2 H1) is the precedent.

### H2 — SPEC-0042 AC5's "no un-tenant-scoped query path" is unimplementable for the token table

AC5: *"every new table carries RLS tenant scoping with no un-tenant-scoped query path (ADR-0003)."*

The enrolment-token port cannot honour that. `backend/modules/agent/internal/app/service.go:44-52`:

```go
TokenByHash(ctx context.Context, hash [32]byte) (domain.Token, bool, error)
ClaimToken(ctx context.Context, hash [32]byte, dataPlaneID string, now time.Time) (domain.Token, bool, error)
```

Both take a hash and no tenant — necessarily, because enrolment resolves the tenant *from* the token; the
presenter has no verified tenant identity yet. Under RLS with a tenant-scoped session variable, both lookups
return zero rows and enrolment breaks. The implementer's only options are a carve-out (a distinct DB role, a
`SECURITY DEFINER` lookup, or a policy predicate keyed on the hash) — and the spec names none, so the choice
gets invented inside a task, which is exactly what ADR-0001 forbids.

**Fix:** amend AC5 to name the exception and bound it: which path is exempt, what enforces the exemption's
narrowness (the lookup returns exactly one row by unique hash and the tenant is bound from that row onward),
and a test asserting no *other* path on that table is un-scoped.

---

## MEDIUM

### M3 — ADR-0066's OpenBao deployment is decided but unowned: no spec AC, no task, no chart

ADR-0066 is Accepted and adds a stateful control-plane dependency: three OpenBao nodes on Raft (decision 6),
Kubernetes auth (decision 5), Shamir quorum unseal (decision 4), an ADR-0034-pinned image (decision 7), and
seal-outage/quorum-unseal runbook procedures. None of that is owned:

- `deploy/` contains no reference to OpenBao or any secrets platform (grep over `deploy/`, `Makefile` — zero hits).
- SPEC-0044's out-of-scope still reads *"Choosing a concrete KMS provider — a deployment concern… (settled by
  ADR-0066)"*, and its ACs test the interface and posture, not a deployment.
- T-0040's notes say *"deploying it remains T-0040 scope"*, but T-0040's ACs are SPEC-0044 AC1–AC4 verbatim
  and its `Repo(s):` is backend plus a super-repo runbook commit — no chart, no deployment AC, no test-plan
  line covering unseal, HA or the image pin.

ADR-0066 also states it *"widens SPEC-0044 AC4's runbook scope at implementation time"* — an Accepted ADR
widening an Approved spec without amending it. In a repo where every AC becomes a test, unowned scope is
what the previous two review waves kept finding.

**Fix:** either amend SPEC-0044 with deployment/unseal ACs (and T-0040's repo list and gate matrix to match),
or file a separate task/spec for the custody service's deployment under EP-21 and say which one owns it.

### M4 — Durable token spend + remote custody signing burns enrolment tokens on an availability event

Enrolment claims the token before it issues the certificate — `service.go:294-306` (`ClaimToken`, commented
*"Spend first. From this line on the token is spent whatever happens next"*) then `service.go:319`
(`issuer.Issue`), whose failure branch states the intent outright: *"the token stays spent. An operator issues
a new token; nothing retries its way into a second identity for this one."* A spent token is then refused
unconditionally, regardless of the presenting data plane (`domain.go:70-80`). That is deliberate and correct
under SPEC-0038 AC1 — a retry after a partial enrolment must not mint a second identity.

The point is that Phase 3.1 changes what that choice costs, in two places at once. Today issuance is
in-process and near-infallible, and a control-plane restart wipes the spend, so a burnt token accidentally
self-heals. SPEC-0042 AC1 removes the restart cushion by design (its own text: refused when replayed after the
restart, *"including the retry-after-partial-enrolment case"*), and ADR-0066 makes issuance a network call to a
quorum-serialized transit endpoint that decision 6 explicitly permits to be unavailable. After both land, one
seal or quorum outage in the window between claim and sign permanently burns a customer's enrolment token,
with an operator minting a new one as the only recovery — an availability event turned into a customer-visible
dead credential. Neither spec says this is the intended trade.

SPEC-0044's assumption covers the *already-issued* case ("certificates already issued remain valid until
expiry"). First issuance is not covered anywhere.

**Fix:** decide it in the open, not inside a task — either record it in SPEC-0042/SPEC-0044 as an accepted
consequence with the operator recovery named in the runbook, or give it an AC (a claim reservation released on
issuance failure, or a same-token/same-data-plane retry bounded so it cannot mint a second identity, which is
the property SPEC-0038 AC1 actually protects).

### M5 — Two different artifacts are both called "the versioned trust bundle"

- ADR-0064 decision 4 / SPEC-0044 AC2 / T-0040: the **CA trust bundle** — agent identity roots, staged
  dual-validate rotation over the reconcile path.
- ADR-0065 decision 2 / SPEC-0045 AC2 / T-0041: the **release-signing (cosign) trust bundle** of ADR-0044,
  distributed across N planes, also over the reconcile path, also "staged dual-validate overlap".

Both claim no contract change and both ride the same channel; SPEC-0045 AC2 says only "the versioned trust
bundle", and T-0042 re-runs "the rotation procedure" per cloud without naming which. EP-21 (M2) and EP-22 (M3)
carry them with no declared dependency edge between the tasks.

**Fix:** name them distinctly in the specs (CA trust bundle vs release trust bundle), and state whether
T-0041's per-fleet distribution mechanism is the same code path T-0040 builds — if it is, M3 depends on M2 and
the spine should say so.

### M6 — The plan and the indexes were not updated when ADR-0066 was accepted

The plan (`docs/plans/phase-3-byo-v2.md`) still reads:

- header: *"ADR-0062…ADR-0065 Accepted"*;
- §What is already decided: *"all four decisions are Accepted"*;
- §What this phase must not do: *"No features needing architectural decisions beyond the four Accepted ADRs"*;
- §Risks: *"KMS provider selection is open by design. ADR-0064 keeps it a deployment concern"* — closed by
  ADR-0066 the same day, along with the risk it describes.

Same omission in `docs/roadmap/README.md` (Phase 3.1 section: "ADRs ADR-0062…ADR-0065 Accepted") and
`docs/backlog/README.md` ("under ADR-0062…ADR-0065 (Accepted)"). ADR-0066 is a real fifth architectural
decision for this phase, including a new control-plane dependency; the plan currently reads as if the phase
took four.

---

## LOW

### L7 — Traceability rot (bundled; all of it passes `check-docs.sh`)

- All five specs still carry `Task(s): — (Phase 3.1, epic EP-xx; task to be filed)` although T-0036…T-0044
  were filed in `0bd3a04` and `docs/specs/README.md` already lists the task mapping. Spec → task is broken in
  the direction a reader follows from the spec.
- SPEC-0044's `ADRs:` header omits 0066 even though its out-of-scope body cites it.
- T-0040's `ADRs:` header omits 0066 while its Notes cite it as settling the provider.
- ADR-0066's consequences say *"T-0040's implementation notes should reference this ADR — a wiring follow-up
  at acceptance time; the task doc is deliberately not edited now"*, but T-0040 does reference it. The
  consequence text is stale relative to its own commit.
- ADR-0064's consequences still say *"Runbook additions become the next spec's scope — SPEC-0044, to be
  filed"*, and ADR-0065's say *"SPEC-0045, to be filed"* — both are Approved.

**Fix:** one docs commit over the editable artifacts only — specs, tasks, the plan and the indexes. The three
ADR-consequence items (0064, 0065, 0066) are **record-only**: Accepted ADRs are superseded, never edited
(`governance/CLAUDE.md`, ADR-0001), and the text was true when accepted. Correct them only if the repo wants a
superseding note. Optionally extend `check-docs.sh` to fail a spec whose `Task(s):` says "to be filed" while
`specs/README.md` lists tasks for it — that would have caught the whole editable class.

---

## Checked and found sound

- Epic → spec → task AC decomposition: every SPEC-0042…0046 AC has a named owning task, and where an AC is
  shared the split is stated on both sides (SPEC-0042 AC5 agent-half/residency-half across T-0036/T-0037;
  SPEC-0046 AC5 owned by T-0043 with T-0044 carrying its pins on the surfaces it touches). No AC is orphaned.
- T-0035 is correctly kept on EP-18's books and not renumbered, and is named as T-0043's blocker in the task,
  the spec (AC3, "must not be claimed"), the roadmap and the backlog.
- The one contract change is a new versioned package (`residency/v1`), additive by construction, with
  `buf breaking` named as its gate and the ADR-0027 governance→backend order stated in T-0038.
- The no-inbound property is re-asserted for the multi-plane shape (SPEC-0045 AC5) rather than assumed.
- The conformance-matrix honesty rule ("never a silent not run") is carried into the plan's exit criteria,
  SPEC-0045 AC3 and T-0042's own dependency annotation.
- Phase-3 carries are reclassified in backlog and roadmap with the mapping stated once and pointed at, not
  duplicated.

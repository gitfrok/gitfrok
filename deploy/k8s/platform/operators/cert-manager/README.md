# cert-manager, vendored

ADR-0095 decision 7 puts ACME certificates at the origin so no third party sits in the TLS path.
This is the thing that issues them. It follows the shape `cloudnative-pg/` established: the upstream
release manifest, committed unmodified, pinned by digest and asserted on every build.

## The pin

`cert-manager-v1.21.2.yaml` is the upstream release manifest, unmodified, fetched from

    https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml

SHA-256:

    e03b668ec8675214af6b0a671699d088f2601fa3878e0dbe1b41d3feafd1879f

Re-pinning is a deliberate act: fetch the new release, record its digest here, and let the gate
refuse the mismatch until both agree.

## Two things this directory ADDS to upstream, and why neither is optional

Everything else here is a local addition. Both exist because the same defect took most of a day to
find on 2026-09-22, presenting as `gateway api is not enabled` on a controller that had, visibly,
Gateway API enabled.

### 1. `--enable-gateway-api` is a SECOND flag

`--feature-gates=ExperimentalGatewayAPISupport=true` alone has not been sufficient since
cert-manager **1.15**. The controller's own `--help` is the authority:

    --enable-gateway-api   Whether gateway API integration is enabled within cert-manager.
                           The ExperimentalGatewayAPISupport feature gate must also be enabled
                           (default as of 1.15).

With only the gate set, every ACME HTTP-01 challenge using a `gatewayHTTPRoute` solver **creates its
solver Pod and Service and then fails**. The deployment reads as configured, every pod is Ready, and
no certificate is ever issued. `patch-gateway-api.yaml` sets both.

### 2. Upstream ships NO Gateway API RBAC

The static release manifest contains no rule for `gateway.networking.k8s.io` anywhere. Only the Helm
chart renders those rules, and only when `config.enableGatewayAPI` is set — so an operator who
installs the static manifest and turns the feature on gets a controller that is configured for
Gateway API and forbidden from using it. `gateway-api-rbac.yaml` supplies the missing ClusterRole
and binding, scoped to reading Gateways and owning the ephemeral solver HTTPRoutes.

`kubectl auth can-i` is not a useful check for this: it answers for the *subject you ask about*, and
the permission that is missing is the one nobody thought to ask about.

## Proof it works, rather than the claim

On 2026-09-23, after both fixes, `letsencrypt-staging` issued a real certificate for
`app-gitfrok.7.solutions` through the `gatewayHTTPRoute` solver — `Ready=True`, issuer
`(STAGING) Dastardly Durum YR1`. Staging first on purpose: a production rate limit spent on a
misconfiguration is a week-long outage of your own making.

**One measured surprise worth carrying.** After the solver `HTTPRoute` is created and bound, the
GKE Gateway URL map is correct and the solver backend reports HEALTHY **several minutes before the
edge serves it** — the challenge path returns 404 the whole time. Nothing is wrong; it propagates.
Do not re-debug a correct URL map. The staging certificate above took roughly ten minutes from
`Certificate` created to `Ready`.

## What is NOT here

No `ClusterIssuer`. An issuer names an ACME server, an account key and a solver, and the solver
names a Gateway in a particular namespace — all environment facts. It belongs to whatever installs
the environment, not to the vendored operator.

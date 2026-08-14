// Command pepc drives the BFF's PEP against a running pdpd for the composition check.
//
// Copied into bff/cmd/<temp>/ by scripts/check-policy-composition.sh so it builds against the BFF's
// own go.mod and its own generated copy of the contract — which is the point. The two repos
// generate independently from governance/contracts, and nothing inside either one proves the
// results interoperate.
//
// Output is machine-readable so the shell script does the asserting:
//
//	CASE <name> ALLOW|DENY|ERROR
//	REVISION <bundle revision>
//	CACHED <entries>
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	policyv1 "github.com/gitfrok/bff/gen/proto/policy/v1"
	"github.com/gitfrok/bff/internal/aggregate"
	"github.com/gitfrok/bff/internal/pep"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// repos stands in for the Repository read API (T-0014). The check is about the authorization path
// in front of it, so what it returns does not matter — only whether it is reached.
type repos struct{ reads int }

func (r *repos) Read(_ context.Context, tenantID, repoID string) (aggregate.RepoView, error) {
	r.reads++
	return aggregate.RepoView{TenantID: tenantID, RepoID: repoID, Name: "infra"}, nil
}

func main() {
	addr := os.Getenv("PDP_ADDR")
	if addr == "" {
		fmt.Fprintln(os.Stderr, "PDP_ADDR must be set")
		os.Exit(1)
	}

	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fmt.Fprintf(os.Stderr, "dial %s: %v\n", addr, err)
		os.Exit(1)
	}
	defer func() { _ = conn.Close() }()

	enforcer := pep.New(policyv1.NewPolicyDecisionPointClient(conn), pep.Options{TTL: time.Minute})
	backing := &repos{}
	agg := aggregate.NewRepos(enforcer, backing)

	// The cases the script asserts on. Both outcomes must appear: a PDP that denied everything and
	// one that allowed everything would each satisfy half of this, and neither is the policy.
	cases := []struct {
		name    string
		subject pep.Subject
	}{
		{"reader-in-tenant", pep.Subject{ID: "u-1", TenantID: "acme", Roles: []string{"reader"}}},
		{"owner-in-tenant", pep.Subject{ID: "u-3", TenantID: "acme", Roles: []string{"owner"}}},
		{"reader-other-tenant", pep.Subject{ID: "u-1", TenantID: "globex", Roles: []string{"reader"}}},
		{"no-roles", pep.Subject{ID: "u-2", TenantID: "acme"}},
		{"anonymous", pep.Subject{TenantID: "acme"}},
		{"unknown-role", pep.Subject{ID: "u-4", TenantID: "acme", Roles: []string{"auditor"}}},
	}

	ctx := context.Background()
	for _, c := range cases {
		switch _, err := agg.Read(ctx, c.subject, "acme", "repo-1"); {
		case err == nil:
			fmt.Printf("CASE %s ALLOW\n", c.name)
		case errors.Is(err, aggregate.ErrDenied):
			fmt.Printf("CASE %s DENY\n", c.name)
		default:
			fmt.Printf("CASE %s ERROR %v\n", c.name, err)
		}
	}

	// The T-0025 security merge gate over the wire: one allow/deny pair straight from
	// SPEC-0029/SPEC-0030. The facts ride context exactly the way valid_approvals does; the pair
	// proves the severity rule allows a clean merge and fails CLOSED when the gate is engaged but
	// its findings facts did not assemble. Decide-only — the backing store is never touched, so
	// the READS assertion below is unaffected.
	owner := pep.Subject{ID: "u-3", TenantID: "acme", Roles: []string{"owner"}}
	mergeCases := []struct {
		name    string
		context map[string]string
	}{
		{"merge-findings-clean", map[string]string{
			"findings_gate":             "true",
			"findings_highest_severity": "MEDIUM",
			"valid_approvals":           "1",
			"required_approvals":        "1",
		}},
		{"merge-findings-missing-facts", map[string]string{
			"findings_gate":      "true",
			"valid_approvals":    "1",
			"required_approvals": "1",
		}},
	}
	for _, c := range mergeCases {
		decision, err := enforcer.Decide(ctx, pep.Request{
			TenantID: "acme",
			Subject:  owner,
			Action:   "merge_request.merge",
			Resource: pep.Resource{Type: "merge_request", ID: "mr-1"},
			Context:  c.context,
		})
		switch {
		case err != nil:
			fmt.Printf("CASE %s ERROR %v\n", c.name, err)
		case decision.Allowed:
			fmt.Printf("CASE %s ALLOW\n", c.name)
		default:
			fmt.Printf("CASE %s DENY\n", c.name)
		}
	}

	// The revision must survive the whole path — policy manifest, PDP, wire, PEP. It is what the
	// cache keys its invalidation on, so an empty one here would mean caching silently does not work.
	decision, err := enforcer.Decide(ctx, pep.Request{
		TenantID: "acme",
		Subject:  pep.Subject{ID: "u-1", TenantID: "acme", Roles: []string{"reader"}},
		Action:   aggregate.ActionRepoRead,
		Resource: pep.Resource{Type: aggregate.ResourceRepository, ID: "repo-1"},
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "decide: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("REVISION %s\n", decision.PolicyRevision)
	fmt.Printf("CACHED %d\n", enforcer.Len())
	// How many times the denials reached the data. Must be zero for every denied case.
	fmt.Printf("READS %d\n", backing.reads)
}

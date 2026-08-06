// Command pdpd serves the backend's PDP over contracts/proto/policy/v1 for the composition check.
//
// It is copied into backend/cmd/<temp>/ by scripts/check-policy-composition.sh, built there so it
// resolves against the backend's own go.mod, and deleted afterwards. It lives in the super-repo
// rather than in backend/ because it is not part of what backend ships — it exists only to be one
// half of a check that cannot run inside either repo alone.
//
// It binds :0 and writes the chosen address to $PDP_ADDR_FILE, so parallel CI jobs cannot collide
// on a hard-coded port.
package main

import (
	"fmt"
	"log"
	"net"
	"os"

	policyv1 "github.com/gitfrok/backend/gen/proto/policy/v1"
	"github.com/gitfrok/backend/modules/policy"
	"github.com/gitfrok/backend/platform/bus"
	"google.golang.org/grpc"
)

func main() {
	bundleDir := os.Getenv("GITFROK_POLICY_BUNDLE_DIR")
	addrFile := os.Getenv("PDP_ADDR_FILE")
	if bundleDir == "" || addrFile == "" {
		log.Fatal("GITFROK_POLICY_BUNDLE_DIR and PDP_ADDR_FILE must be set")
	}

	pdp, err := policy.NewOPADecisionPoint(bundleDir, bus.NewInProcess())
	if err != nil {
		log.Fatalf("loading %s: %v", bundleDir, err)
	}

	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	if err := os.WriteFile(addrFile, []byte(lis.Addr().String()), 0o600); err != nil {
		log.Fatalf("writing address file: %v", err)
	}
	fmt.Printf("pdpd listening on %s with bundle %s\n", lis.Addr(), bundleDir)

	s := grpc.NewServer()
	policyv1.RegisterPolicyDecisionPointServer(s, policy.NewGRPCServer(pdp))
	log.Fatal(s.Serve(lis))
}

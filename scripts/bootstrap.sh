#!/usr/bin/env bash
set -euo pipefail
git submodule update --init --recursive
echo "Submodules initialized."
echo "Toolchain floors (.tool-versions):"; cat .tool-versions
echo "Next: read governance/AGENTS.md, then pick a task in governance/docs/tasks/."

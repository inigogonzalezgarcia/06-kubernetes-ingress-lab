#!/usr/bin/env bash
# Deletes the lab cluster and everything in it.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/versions.env
source scripts/versions.env
kind delete cluster --name "${CLUSTER_NAME}"

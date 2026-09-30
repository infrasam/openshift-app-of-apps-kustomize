#!/usr/bin/env bash
# Configures the lab's OpenBao for the External Secrets Operator: KV v2, Kubernetes auth,
# policies and roles. Idempotent: safe to re-run.
# Production equivalent: the same configuration as code (Terraform/OpenTofu vault provider).
#
# Usage: scripts/openbao-configure.sh     (reads the root token from ~/openbao-init.json)
set -euo pipefail

INIT_FILE="${OPENBAO_INIT_FILE:-$HOME/openbao-init.json}"
[[ -r "$INIT_FILE" ]] || { echo "ERROR: cannot read $INIT_FILE" >&2; exit 1; }

# The token travels as the first line of stdin: never as an argument or in kubectl's environment
{
  jq -r .root_token "$INIT_FILE"
  cat <<'SCRIPT'
set -eu
enabled() { bao "$1" list -format=json | grep -q "\"$2/\""; }

# KV version 2 at secret/ (versioned secrets)
enabled secrets secret || bao secrets enable -path=secret -version=2 kv

# Kubernetes auth for this cluster: OpenBao validates service account tokens through
# the TokenReview API (the chart grants OpenBao system:auth-delegator)
enabled auth kubernetes || bao auth enable kubernetes
bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc

# ESO on the hub: read-only, shared secrets and the hub's own path
printf '%s\n' \
  'path "secret/data/shared/*"                  { capabilities = ["read"] }' \
  'path "secret/metadata/shared/*"              { capabilities = ["read", "list"] }' \
  'path "secret/data/clusters/k3d-hub-01/*"     { capabilities = ["read"] }' \
  'path "secret/metadata/clusters/k3d-hub-01/*" { capabilities = ["read", "list"] }' \
  | bao policy write eso-k3d-hub-01 -
bao write auth/kubernetes/role/eso-k3d-hub-01 \
  bound_service_account_names=openbao-auth \
  bound_service_account_namespaces=external-secrets \
  token_policies=eso-k3d-hub-01 \
  token_ttl=1h

# Human admins: userpass in the lab (production: OIDC against the corporate IdP)
printf '%s\n' 'path "*" { capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"] }' \
  | bao policy write admin -
enabled auth userpass || bao auth enable userpass

echo "OpenBao configured"
SCRIPT
} | kubectl -n openbao exec -i openbao-0 -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec sh -s'

#!/usr/bin/env bash
# Bootstrap a lab cluster from this repo:
#   k3d cluster -> OLM -> Argo CD operator + instance -> bootstrap chart (root app)
#
# OLM and the Argo CD operator are rendered from the exact sources and values that
# cluster/base/*.yaml gives Argo CD, so Argo CD adopts them without changing anything.
# Safe to re-run: every step is idempotent.
#
# Usage: scripts/bootstrap.sh <overlay>      e.g. scripts/bootstrap.sh k3d-hub-01
set -euo pipefail

OVERLAY="${1:?usage: $0 <overlay>  (e.g. k3d-hub-01)}"
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
BASE_DIR="$REPO_ROOT/cluster/base"
OVERLAY_DIR="$REPO_ROOT/cluster/overlays/$OVERLAY"
BOOTSTRAP_CHART="$OVERLAY_DIR/helm/bootstrap"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Retry a command until it succeeds; used where the object may not exist yet.
retry() {
  local timeout=$1; shift
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < end )) || die "timed out after ${timeout}s: $*"
    sleep 5
  done
}

# ---------------------------------------------------------------------------
log "Preflight"
for tool in k3d kubectl helm yq git; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done
[[ -f "$OVERLAY_DIR/k3d-cluster.yaml" ]] || die "no k3d-cluster.yaml in $OVERLAY_DIR"
[[ -d "$BOOTSTRAP_CHART" ]] || die "no bootstrap chart in $BOOTSTRAP_CHART"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
log "1/4 k3d cluster"
CLUSTER_NAME="$(yq '.metadata.name' "$OVERLAY_DIR/k3d-cluster.yaml")"
if k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
  echo "k3d cluster $CLUSTER_NAME already exists, skipping create"
else
  k3d cluster create --config "$OVERLAY_DIR/k3d-cluster.yaml"
fi
kubectl config use-context "k3d-$CLUSTER_NAME" >/dev/null

# Guard: never bootstrap a cluster whose context does not match the overlay name
[[ "$(kubectl config current-context)" == "$OVERLAY" ]] \
  || die "current context $(kubectl config current-context) does not match overlay $OVERLAY"

# ---------------------------------------------------------------------------
log "2/4 OLM (from $BASE_DIR/olm.yaml)"
OLM_APP="$BASE_DIR/olm.yaml"
OLM_REPO="$(yq '.spec.source.repoURL' "$OLM_APP")"
OLM_REF="$(yq '.spec.source.targetRevision' "$OLM_APP")"
OLM_CHART_PATH="$(yq '.spec.source.path' "$OLM_APP")"
OLM_RELEASE="$(yq '.spec.source.helm.releaseName // .metadata.name' "$OLM_APP")"

git clone -q --depth 1 --branch "$OLM_REF" "$OLM_REPO" "$WORK/olm-src"
yq '.spec.source.helm.valuesObject' "$OLM_APP" > "$WORK/olm-values.yaml"

# valueFiles are relative to the chart path, exactly like Argo CD resolves them
value_args=()
while IFS= read -r f; do
  value_args+=(-f "$WORK/olm-src/$OLM_CHART_PATH/$f")
done < <(yq '.spec.source.helm.valueFiles[]' "$OLM_APP")

helm template "$OLM_RELEASE" "$WORK/olm-src/$OLM_CHART_PATH" \
  "${value_args[@]}" -f "$WORK/olm-values.yaml" --include-crds > "$WORK/olm.yaml"

# CRDs first: the other objects are instances of these types
yq 'select(.kind == "CustomResourceDefinition")' "$WORK/olm.yaml" \
  | kubectl apply --server-side -f -
for crd in $(yq -N 'select(.kind == "CustomResourceDefinition") | .metadata.name' "$WORK/olm.yaml"); do
  kubectl wait --for=condition=Established "crd/$crd" --timeout=120s >/dev/null
done
yq 'select(.kind != "CustomResourceDefinition")' "$WORK/olm.yaml" \
  | kubectl apply --server-side -f -

kubectl -n olm rollout status deploy/olm-operator deploy/catalog-operator --timeout=300s
retry 300 kubectl -n olm wait csv/packageserver \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=5s

# ---------------------------------------------------------------------------
log "3/4 Argo CD operator and instance (from $BASE_DIR/argocd.yaml)"
ARGOCD_APP="$BASE_DIR/argocd.yaml"
ARGOCD_NS="$(yq '.spec.destination.namespace' "$ARGOCD_APP")"
ARGOCD_RELEASE="$(yq '.spec.source.helm.releaseName // .metadata.name' "$ARGOCD_APP")"
yq '.spec.source.helm.values' "$ARGOCD_APP" > "$WORK/argocd-values.yaml"

helm template "$ARGOCD_RELEASE" "$(yq '.spec.source.chart' "$ARGOCD_APP")" \
  --repo "$(yq '.spec.source.repoURL' "$ARGOCD_APP")" \
  --version "$(yq '.spec.source.targetRevision' "$ARGOCD_APP")" \
  -n "$ARGOCD_NS" -f "$WORK/argocd-values.yaml" > "$WORK/argocd.yaml"

# Operator coordinates and catalog come from the same values
OP_NAME="$(yq '.operator.name' "$WORK/argocd-values.yaml")"
OP_NS="$(yq '.operator.namespace' "$WORK/argocd-values.yaml")"
CATALOG="$(yq '.operator.sourceName' "$WORK/argocd-values.yaml")"
CATALOG_NS="$(yq '.operator.sourceNamespace' "$WORK/argocd-values.yaml")"

retry 300 kubectl -n "$CATALOG_NS" wait "catalogsource/$CATALOG" \
  --for=jsonpath='{.status.connectionState.lastObservedState}'=READY --timeout=5s

# Namespace with the labels Argo CD will manage (managedNamespaceMetadata)
kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply --server-side -f -
while IFS= read -r label; do
  kubectl label namespace "$ARGOCD_NS" "$label" --overwrite
done < <(yq '.spec.syncPolicy.managedNamespaceMetadata.labels // {} | to_entries | .[] | .key + "=" + .value' "$ARGOCD_APP")

# Phase 1: Subscription + RBAC; OLM installs the operator and its CRDs
yq 'select(.kind != "ArgoCD" and .kind != "AppProject")' "$WORK/argocd.yaml" \
  | kubectl apply --server-side -f -
retry 300 kubectl -n "$OP_NS" wait "subscription/$OP_NAME" \
  --for=jsonpath='{.status.state}'=AtLatestKnown --timeout=5s
CSV="$(kubectl -n "$OP_NS" get subscription "$OP_NAME" -o jsonpath='{.status.installedCSV}')"
retry 300 kubectl -n "$OP_NS" wait "csv/$CSV" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=5s
retry 120 kubectl wait --for=condition=Established \
  crd/argocds.argoproj.io crd/appprojects.argoproj.io crd/applications.argoproj.io --timeout=5s

# Phase 2: the Argo CD instance
yq 'select(.kind == "ArgoCD" or .kind == "AppProject")' "$WORK/argocd.yaml" \
  | kubectl apply --server-side -f -
ARGOCD_NAME="$(yq '.name' "$WORK/argocd-values.yaml")"
retry 300 kubectl -n "$ARGOCD_NS" rollout status "deploy/$ARGOCD_NAME-server" --timeout=5s
retry 300 kubectl -n "$ARGOCD_NS" rollout status "statefulset/$ARGOCD_NAME-application-controller" --timeout=5s

# ---------------------------------------------------------------------------
log "4/4 Bootstrap chart (root app) from $BOOTSTRAP_CHART"
# Optional, never committed: e.g. tlsCerts for a TLS-inspecting proxy
local_values=()
[[ -f "$BOOTSTRAP_CHART/values.local.yaml" ]] && local_values=(-f "$BOOTSTRAP_CHART/values.local.yaml")

helm upgrade --install bootstrap "$BOOTSTRAP_CHART" \
  -n "$ARGOCD_NS" --take-ownership "${local_values[@]}"

for app in root infra; do
  retry 300 kubectl -n "$ARGOCD_NS" wait "application/$app" \
    --for=jsonpath='{.status.health.status}'=Healthy --timeout=5s
  echo "application/$app Healthy"
done

log "Done. Git now owns $OVERLAY"
kubectl -n "$ARGOCD_NS" get applications
cat <<EOF

Argo CD UI:
  kubectl -n $ARGOCD_NS get secret $ARGOCD_NAME-cluster -o jsonpath='{.data.admin\.password}' | base64 -d; echo
  kubectl -n $ARGOCD_NS port-forward svc/$ARGOCD_NAME-server 8080:443   # https://localhost:8080 (admin)
EOF

# OpenShift fleet GitOps (app-of-apps + Kustomize)

A GitOps repository for running a **fleet of Kubernetes clusters from one hub**, in the same way
OpenShift, Red Hat Advanced Cluster Management (RHACM) and OpenShift GitOps do it in production.
The hub creates clusters from Git and registers them. Handing each cluster over to its own Argo CD
is the next phase (see [Status](#status)).

The repository runs as a **lab on a laptop** (k3d, no domain, no Red Hat subscription), using the
open-source upstream of every product. Every pattern maps one-to-one to real OpenShift + RHACM.
To create child clusters in vCenter from Git with an existing RHACM hub (proof of concept), see
[docs/openshift-implementation.md](docs/openshift-implementation.md).
To run the secret chain (OpenBao, External Secrets Operator, secrets for applications) on
OpenShift, see [docs/openshift-secrets-openbao-eso.md](docs/openshift-secrets-openbao-eso.md).

## How it works

```mermaid
flowchart LR
    git[(Git repo)] -->|root app| hubargo[Hub Argo CD]
    hubargo --> hubapps[Hub platform<br/>OLM, cert-manager,<br/>OCM hub, Cluster API]
    hubargo -->|ApplicationSet<br/>per managed-clusters/ folder| prov[Spoke provisioning<br/>Cluster + CNI +<br/>ManagedCluster]
    prov -->|Cluster API| spoke[Spoke cluster]
    prov -->|auto-import| ocm[OCM hub]
    ocm -->|klusterlet| spoke
```

1. **Bootstrap once.** `scripts/bootstrap.sh` creates the hub, installs OLM and the Argo CD
   operator, and installs a small Helm chart with a `root` Application. From then on, Git owns
   the cluster.
2. **App of apps.** `root` renders `helm/infra`, which creates the `infra` Application. `infra`
   points to the cluster's Kustomize overlay, and every entry in the overlay is itself an Argo CD
   Application. Sync waves order them.
3. **A new cluster is a new folder.** An ApplicationSet on the hub turns every folder in the
   hub's inventory, `cluster/overlays/<hub>/managed-clusters/<cluster>/`, into an Application. That
   Application creates the cluster, installs its network, and registers it in Open Cluster
   Management (OCM).
4. **Zero-touch join.** OCM imports the new cluster automatically, and it reports as
   `JOINED` / `AVAILABLE` on the hub.

## Repository layout

```
cluster/
├── base/                                  # Argo CD Applications every cluster gets
│   ├── kustomization.yaml
│   ├── olm.yaml                           # wave -10  OLM (built into OpenShift)
│   ├── argocd.yaml                        # wave  -5  Argo CD (= OpenShift GitOps)
│   └── cert-manager.yaml                  # wave  -3  cert-manager
├── applications/
│   └── ocm-hub/                           # OCM hub via OLM (= RHACM)
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       ├── operatorgroup.yaml
│       ├── subscription.yaml
│       ├── clustermanager.yaml
│       └── bootstrap-sa.yaml
└── overlays/
    └── k3d-hub-01/                        # the hub
        ├── k3d-cluster.yaml               # how the hub itself is created
        ├── kustomization.yaml             # ../../base + the files below
        ├── ocm-hub.yaml                   # Application: OCM hub
        ├── capi.yaml                      # Application: Cluster API (= Hive)
        ├── spoke-provisioning.yaml        # ApplicationSet over managed-clusters/*
        ├── patch/argocd-patch.yaml
        ├── managed-clusters/              # applied to the HUB: the clusters this hub owns
        │   └── k3d-spoke-01/              # how this spoke is created and registered
        │       ├── kustomization.yaml
        │       ├── namespace.yaml
        │       ├── cluster.yaml           # Cluster API Cluster (= Hive ClusterDeployment)
        │       ├── controlplane.yaml      # (= install-config / MachinePool)
        │       ├── cni.yaml
        │       ├── cni/kindnet.yaml       # pod network (= networkType in install-config)
        │       ├── managedcluster.yaml    # identical API in RHACM
        │       └── import-rbac.yaml
        └── helm/
            ├── bootstrap/                 # installed once with helm
            │   ├── Chart.yaml
            │   ├── values.yaml
            │   └── templates/
            │       ├── namespace.yaml
            │       ├── clusterrolebinding.yaml
            │       ├── appproject.yaml
            │       ├── application.yaml   # the root Application
            │       ├── argocd-tls-certs.yaml
            │       └── cluster-info.yaml
            └── infra/                     # creates the infra Application
                ├── Chart.yaml
                ├── values.yaml
                └── templates/application.yaml
docs/
├── openshift-implementation.md
└── openshift-secrets-openbao-eso.md
scripts/
└── bootstrap.sh
```

**A folder belongs to the cluster it is applied to.** How a spoke is created is applied to the
hub, so it lives in the hub's `managed-clusters/` inventory. What runs on the spoke will live in
the spoke's own overlay, `cluster/overlays/<cluster>/`, from the next phase (see Status). The
hub's ApplicationSet only reads its own inventory, so a second hub never picks up clusters it does
not own, and `managed-clusters/` is the one path to protect with review. Three kinds of
configuration are kept apart:

| What | Applied to | By |
|---|---|---|
| How the cluster is **created and registered** (`<hub>/managed-clusters/<cluster>/`) | The hub | The hub's Argo CD, through the ApplicationSet |
| What **runs inside** the cluster (`overlays/<cluster>/`, `base` + patches) | The cluster itself | The cluster's own Argo CD (next phase) |
| **Credentials** for creating clusters (vCenter, pull secret, install-config) | The hub, into the cluster's namespace | By hand for now, never in Git. Later from a secret store through External Secrets, with the same Secret names |

**`base` is what every cluster must have, not a menu.** Optional apps live in
`cluster/applications/`, and a cluster lists them in its own `kustomization.yaml`. If one cluster
needs to skip something from `base`, use a delete patch in that cluster's `patch/` folder, with a
comment that says why:

```yaml
# cluster/overlays/<cluster>/patch/remove-cert-manager.yaml
$patch: delete
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: openshift-gitops
```

Kustomize fails the build if the patch matches nothing, so a typo shows up in the pull request.
When many clusters skip the same app, move it out of `base` instead.

## Lab to production mapping

| Production (OpenShift + RHACM on vSphere) | This lab |
|---|---|
| OpenShift cluster | k3d (hub), Cluster API Docker clusters (spokes) |
| OLM (built in) | OLM installed as an Argo CD Application |
| OpenShift GitOps operator | Upstream Argo CD operator via the `gitops-operator` chart |
| cert-manager Operator for Red Hat OpenShift | Upstream cert-manager Helm chart |
| RHACM / MultiClusterHub | Open Cluster Management `ClusterManager` |
| Hive `ClusterDeployment` on vSphere | Cluster API `Cluster` + Docker provider |
| `networkType: OVNKubernetes` in install-config | kindnet via `ClusterResourceSet` |
| ACM import controller (built in) | OCM `ClusterImporter` feature gate |
| `ManagedCluster` | `ManagedCluster` (same API) |
| vCenter credentials, pull secret and install-config: Secrets created by hand in the cluster namespace | Not needed: Docker needs no credentials |
| Internal Git server | GitHub (public, so no environment data or secrets) |

## Safety rails

- **Clusters are never deleted by Git by accident.** The ApplicationSet uses
  `preserveResourcesOnDeletion`. Its Applications have no resources finalizer. `Cluster` and
  `ManagedCluster` carry `Prune=false,Delete=false`.
- **The infra layer is fenced.** The `infra` AppProject may only create `Application` and
  `ApplicationSet` objects. The project is installed by Helm, so Git cannot remove its own
  guardrails.
- **Pinned versions everywhere.** Charts, operators, Kubernetes and the CNI image all have fixed
  versions, so a rebuilt cluster is identical to the old one.
- **No secrets in Git.** Kubeconfigs, keys and local values files are ignored (see `.gitignore`).
  Local-only values use the `*.local.yaml` suffix.
- **Every change goes through a pull request.** Run `kubectl kustomize <path>` before committing.
  If it fails locally, it fails in Argo CD.

## Running the lab

**Requirements:** Docker, `k3d`, `kubectl`, `helm`, `yq`, `git`, and about 12 GB of free RAM.

Several clusters share the host kernel, so raise the inotify limits first. Without this,
kube-proxy on the spokes crashes with `too many open files`:

```bash
sudo tee /etc/sysctl.d/99-kubernetes-lab.conf <<'EOF'
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
EOF
sudo sysctl --system
```

**Create the hub:**

```bash
scripts/bootstrap.sh k3d-hub-01
kubectl -n openshift-gitops get applications
```

**Open the Argo CD UI:**

```bash
kubectl -n openshift-gitops port-forward svc/argocd-server 8080:443
kubectl -n openshift-gitops get secret argocd-cluster -o jsonpath='{.data.admin\.password}' | base64 -d; echo
```

Then go to <https://localhost:8080> and log in as `admin`.

**Follow a spoke being created:**

```bash
kubectl -n k3d-spoke-01 get cluster,kubeadmcontrolplane,machines
kubectl get managedclusters        # JOINED and AVAILABLE become True
```

**Reach the spoke.** The kubeconfig is an admin credential, so keep it outside the repo:

```bash
kubectl -n k3d-spoke-01 get secret k3d-spoke-01-kubeconfig -o jsonpath='{.data.value}' \
  | base64 -d > /tmp/k3d-spoke-01.kubeconfig
kubectl --kubeconfig /tmp/k3d-spoke-01.kubeconfig get nodes
```

## Status

| Phase | State |
|---|---|
| Hub: OLM, Argo CD, app of apps | Done |
| cert-manager | Done |
| OCM hub + Cluster API | Done |
| Spoke provisioning from Git, CNI, auto-import into OCM | Done |
| Argo CD + root app on the spoke, installed by the hub | Next |
| Internal CA, Gateway API ingress, OpenBao + External Secrets | Planned |
| vCenter credentials and pull secret from the secret store, replacing the manual step | Planned, together with External Secrets |
| Fleet governance with OCM policies | Planned |

**Known lab limitations:**
- Spokes are vanilla Kubernetes, so there are no Routes, SCCs or other OpenShift-only APIs.
- The Cluster API Docker load balancer listens on `0.0.0.0`.

# OpenShift fleet GitOps (app of apps)

A hub cluster that creates, registers and configures other clusters, all from this Git repository
with Argo CD. It runs on k3d (Kubernetes in Docker) and uses the same building blocks as an
OpenShift fleet: operators through OLM, Gateway API ingress, cert-manager, OpenBao with External
Secrets, Open Cluster Management (the upstream of RHACM), Prometheus/Thanos, Grafana and Loki.

| Cluster | Role |
|---|---|
| `k3d-hub-01` | Hub: Argo CD, secrets, cluster creation, metrics/logs/alerts for the fleet |
| `k3d-spoke-01` | Managed cluster, created by the hub; runs its own Argo CD |

## Layout

The repository has two halves: **what** gets installed (`apps/`) and **where** (`clusters/`).

```
apps/                         WHAT: the configuration of every app, one folder per app
  cert-manager/                 plain YAML + kustomization.yaml
  openbao/values.yaml           Helm values for an upstream chart
  secret-store/
    k3d-hub-01/                 a version for one cluster (only when clusters differ)
    k3d-spoke-01/
  ...

clusters/                     WHERE: one folder per cluster, one Application file per app
  k3d-hub-01/
    kustomization.yaml          the list of apps on this cluster, in install order
    cert-manager.yaml           Argo CD Application -> apps/cert-manager
    openbao.yaml                Argo CD Application -> chart + apps/openbao/values.yaml
    ...
  k3d-spoke-01/
    kustomization.yaml
    ...

bootstrap/                    one-time installation of the hub (k3d cluster, OLM, Argo CD, root app)
```

### The rule

1. **Every app has one folder in `apps/`.** All its configuration lives there, and nothing else does.
2. **Every cluster has one folder in `clusters/`.** It holds one Argo CD `Application` file per app
   that runs on that cluster, and a `kustomization.yaml` that lists them.
3. **When two clusters need different configuration for the same app**, the app folder gets one
   subfolder per cluster (`apps/<app>/<cluster>/`). When the configuration is the same, the
   clusters share the folder.

There are no patches, overlays or base layers: what you see in a file is what gets applied.

### How Argo CD reads it

```
root Application (created once by bootstrap/)
  └─ clusters/k3d-hub-01/kustomization.yaml       list of Application files
       ├─ cert-manager.yaml  ──>  apps/cert-manager/      the actual objects
       ├─ openbao.yaml       ──>  openbao chart + apps/openbao/values.yaml
       └─ ...
```

The root Application points at the cluster's folder. Every file listed there is an
`Application`, and each `Application` points at its configuration in `apps/`. A spoke works the
same way: the hub's `gitops` policy gives it Argo CD and a root Application that points at
`clusters/<spoke>/`.

**Order.** Each `Application` has a `sync-wave` annotation. Argo CD installs the lowest wave
first and waits until it is healthy before the next one. Operators come before the objects that
use them, for example cert-manager (`-3`) before the lab CA (`-2`).

## Adding something

### A new app from your own YAML

1. Create `apps/<app>/` with the YAML files and a `kustomization.yaml` that lists them.
2. Copy an `Application` file that uses plain YAML, for example `clusters/k3d-hub-01/thanos.yaml`,
   to `clusters/<cluster>/<app>.yaml`. Change `metadata.name`, `spec.source.path`, the
   destination namespace and the sync-wave.
3. Add `<app>.yaml` to `clusters/<cluster>/kustomization.yaml`.
4. Check it renders: `kubectl kustomize apps/<app>` and `kubectl kustomize clusters/<cluster>`.

### A new app from a Helm chart

1. Create `apps/<app>/values.yaml` with the chart's values.
2. Copy an `Application` file that uses a chart, for example `clusters/k3d-hub-01/seaweedfs.yaml`.
   Change the chart name, version, `releaseName`, the values file path and the namespace.
3. Add it to `clusters/<cluster>/kustomization.yaml`.

### An operator from OLM

Use the plain-YAML pattern with one `Subscription` in `apps/<operator>/subscription.yaml`, for
example `apps/grafana-operator/`. Operators that watch all namespaces go into the `operators`
namespace, which already has an `OperatorGroup`.

### The same app on another cluster

Add an `Application` file for it in `clusters/<other cluster>/` and list it there. If the other
cluster needs different configuration, move the existing files into `apps/<app>/<cluster>/` and
add a folder for the new cluster next to it.

### A new managed cluster

1. Copy `apps/cluster-provisioning/k3d-spoke-01/` to `apps/cluster-provisioning/<new cluster>/` and
   replace the cluster name and addresses. The hub's `spoke-provisioning` ApplicationSet creates an
   Application for every folder there, which creates and registers the cluster.
2. Create `clusters/<new cluster>/` with the apps the cluster should run (copy
   `clusters/k3d-spoke-01/`), and folders `apps/<app>/<new cluster>/` for the cluster-specific apps
   (`secret-store`, `prometheus`, `log-collector`).

## Safety rails

- **Clusters are never deleted by Git by accident.** The ApplicationSet keeps its resources when
  an Application is removed, and `Cluster` and `ManagedCluster` carry `Prune=false,Delete=false`.
- **The root Application is fenced.** Its AppProject (`infra`) may only create `Application` and
  `ApplicationSet` objects. The project is installed by Helm at bootstrap, so Git cannot remove it.
- **Pinned versions everywhere.** Charts, operators, images and Kubernetes have fixed versions, so
  a rebuilt cluster is identical to the old one.
- **No secrets in Git.** Passwords and keys live in OpenBao and reach the clusters through External
  Secrets. Kubeconfigs, keys and `*.local.yaml` files are ignored (see `.gitignore`).
- **Every change goes through a pull request.** CI renders every kustomization and validates it
  against the Kubernetes and CRD schemas (`.github/workflows/validate.yaml`).

## Running the lab

**Requirements:** Docker, `k3d`, `kubectl`, `helm`, `yq`, `git`, and about 12 GB of free RAM.

Several clusters share the host kernel, so raise the inotify limits first:

```bash
sudo tee /etc/sysctl.d/99-kubernetes-lab.conf <<'EOF'
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
EOF
sudo sysctl --system
```

**Create the hub.** This creates the k3d cluster, installs OLM and Argo CD, and creates the root
Application. From then on, Argo CD installs everything in `clusters/k3d-hub-01/`:

```bash
bootstrap/bootstrap.sh k3d-hub-01
kubectl -n openshift-gitops get applications
```

**Create OpenBao's unseal key** (once per hub, never in Git). OpenBao then initializes,
configures and unlocks itself (`apps/openbao/values.yaml`):

```bash
umask 077
openssl rand -out ~/openbao-unseal.key 32
kubectl -n openbao create secret generic openbao-unseal-key --from-file=unseal.key=$HOME/openbao-unseal.key
```

**Trust the lab CA** (once per hub rebuild), so the browser and `curl` accept the certificates.
Import `~/lab-root-ca.crt` in the browser as a certificate authority too:

```bash
kubectl -n operators get secret lab-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/lab-root-ca.crt
sudo cp ~/lab-root-ca.crt /usr/local/share/ca-certificates/lab-root-ca.crt && sudo update-ca-certificates
```

### What runs where

| UI | Address | Login |
|---|---|---|
| Argo CD | <https://argocd.apps.hub.172.19.0.3.nip.io> | `admin`, password below |
| OpenBao | <https://openbao.apps.hub.172.19.0.3.nip.io> | token below (method *Token*) |
| Grafana | <https://grafana.apps.hub.172.19.0.3.nip.io> | `admin`, password below |
| Thanos Query | `kubectl -n thanos port-forward svc/thanos-query 9090` | none |
| Alertmanager | `kubectl -n thanos port-forward svc/alertmanager-operated 9093` | none |

```bash
# Argo CD
kubectl -n openshift-gitops get secret argocd-cluster -o jsonpath='{.data.admin\.password}' | base64 -d; echo
# OpenBao admin token (valid for one hour)
kubectl -n openbao create token openbao-admin | jq -Rc '{role: "admin", jwt: .}' \
  | curl -s -X POST --data @- https://openbao.apps.hub.172.19.0.3.nip.io/v1/auth/kubernetes/login \
  | jq -r .auth.client_token
# Grafana
kubectl -n grafana get secret grafana-admin-credentials -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 -d; echo
```

**Metrics and logs.** Every spoke runs Prometheus and a log collector and sends to the hub:
metrics to Thanos (`https://thanos-receive.apps.hub...`), logs to Loki
(`https://loki.apps.hub...`). Both are stored in S3 (SeaweedFS). In Grafana, the dashboard
*Fleet overview* shows every cluster; the data source *Loki* has the logs, labelled
`k8s_cluster_name`, `k8s_namespace_name` and `k8s_pod_name`.

### The spoke

```bash
kubectl -n k3d-spoke-01 get cluster,kubeadmcontrolplane,machines    # being created
kubectl get managedclusters                                         # JOINED and AVAILABLE
# Its kubeconfig is an admin credential: keep it outside the repo
kubectl -n k3d-spoke-01 get secret k3d-spoke-01-kubeconfig -o jsonpath='{.data.value}' \
  | base64 -d > /tmp/k3d-spoke-01.kubeconfig
kubectl --kubeconfig /tmp/k3d-spoke-01.kubeconfig get nodes
```

## Lab limitations

- Clusters are vanilla Kubernetes: there are no Routes, SCCs or other OpenShift-only APIs. Ingress
  uses the Gateway API, which OpenShift supports too.
- The hub's apps domain is `*.apps.hub.172.19.0.3.nip.io`. `172.19.0.3` is the hub's fixed address
  on the Docker network `kind`, so the names work from the laptop and from inside the spokes. All
  lab containers have fixed addresses (hub 172.19.0.3 and .5, spoke 172.19.0.2 and .4).
- **After a reboot**, the spoke's network plugin (kindnet) can keep the addresses of pods that no
  longer exist. When new pods hang in `ContainerCreating` with `no IPs available`, the reservations
  in `/var/lib/cni-kindnet/cni.db` on the spoke node must be cleared and the stuck pods restarted.

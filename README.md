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
apps/                         WHAT: one folder per app, with everything that belongs to it
  grafana/
    kustomization.yaml          lists the files below
    subscription.yaml           the operator (OLM)
    grafana.yaml                the instance
    datasources.yaml            ...and its configuration
    httproute.yaml
  openbao/
    values.yaml                 settings for the upstream Helm chart
    certificate.yaml            ...plus the app's own YAML next to it
  prometheus/
    k3d-spoke-01/               a version for one cluster (only when clusters differ)
  ...

clusters/                     WHERE: one folder per cluster, one Application file per app
  k3d-hub-01/
    kustomization.yaml          the list of apps on this cluster, in install order
    grafana.yaml                Argo CD Application -> apps/grafana/
    openbao.yaml                Argo CD Application -> openbao chart + apps/openbao/
    ...
  k3d-spoke-01/
    ...

bootstrap/                    one-time installation of the hub (k3d cluster, OLM, Argo CD, root app)
```

### The rule

1. **One app = one folder in `apps/`** with everything that belongs to it: the operator, the
   instance, its routes, certificates and configuration. Nothing of the app lives anywhere else.
2. **One app = one Application file in `clusters/<cluster>/`**, listed in that folder's
   `kustomization.yaml`. A cluster runs exactly the apps listed there.
3. **When two clusters need different configuration for the same app**, the app folder gets one
   subfolder per cluster (`apps/<app>/<cluster>/`). When it is the same, the clusters share it.

There are no patches, overlays or base layers: what you see in a file is what gets applied.

### How Argo CD reads it

```
root Application (created once by bootstrap/)
  └─ clusters/k3d-hub-01/kustomization.yaml       list of Application files
       ├─ grafana.yaml   ──>  apps/grafana/                 operator + instance + config
       ├─ openbao.yaml   ──>  openbao chart (apps/openbao/values.yaml) + apps/openbao/
       └─ ...
```

The root Application points at the cluster's folder. Every file listed there is an
`Application`, and each `Application` points at its folder in `apps/`. A spoke works the same
way: the hub's `gitops` policy gives it Argo CD and a root Application that points at
`clusters/<spoke>/`.

**Order between apps.** Each `Application` has a `sync-wave` annotation. Argo CD installs the
lowest wave first and waits until it is healthy before the next one: cert-manager (`-3`) before
ingress (`-2`) before OpenBao (`0`), and so on.

**Order inside an app.** The files in an app folder have their own `sync-wave` too: namespace and
operator first (`-1`), then the instance (`0`), then what needs the running instance (`1`). Until
the operator has installed its types, the instance waits and retries
(`SkipDryRunOnMissingResource` and `retry` in every Application).

## Adding something

### A new app

1. Create `apps/<app>/` with the YAML files and a `kustomization.yaml` that lists them. For an
   operator from OLM, add its `Subscription` there too (wave `-1`); operators that watch all
   namespaces go into the `operators` namespace, which already has an `OperatorGroup`. Example:
   `apps/grafana/`.
2. Copy an `Application` file, for example `clusters/k3d-hub-01/grafana.yaml`, to
   `clusters/<cluster>/<app>.yaml`. Change `metadata.name`, the path, the namespace and the wave.
3. Add `<app>.yaml` to `clusters/<cluster>/kustomization.yaml`.
4. Check it renders: `kubectl kustomize apps/<app>` and `kubectl kustomize clusters/<cluster>`.

### A new app from a Helm chart

Put the chart's settings in `apps/<app>/values.yaml` (and any extra YAML of the app next to it).
Copy an `Application` file that uses a chart, for example `clusters/k3d-hub-01/object-storage.yaml`,
and change the chart name, version, `releaseName` and paths.

### The same app on another cluster

Add an `Application` file for it in `clusters/<other cluster>/` and list it there. If the other
cluster needs different configuration, move the existing files into `apps/<app>/<cluster>/` and
add a folder for the new cluster next to it.

### A new managed cluster

1. Copy `apps/cluster-provisioning/clusters/k3d-spoke-01/` to
   `apps/cluster-provisioning/clusters/<new cluster>/` and replace the cluster name and addresses.
   The hub creates an Application for every folder there, which creates and registers the cluster.
2. Create `clusters/<new cluster>/` with the apps the cluster should run (copy
   `clusters/k3d-spoke-01/`), and a folder `apps/<app>/<new cluster>/` for each app that has
   cluster-specific configuration (`external-secrets`, `prometheus`, `opentelemetry-collector`).

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
| Alertmanager | `kubectl -n alertmanager port-forward svc/alertmanager-operated 9093` | none |

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

**Metrics.** Every spoke runs Prometheus and sends its metrics to Thanos on the hub
(`https://thanos-receive.apps.hub...`), stored in S3 (SeaweedFS). In Grafana, the dashboard
*Fleet overview* shows every cluster. Thanos Ruler evaluates the alert rules in
`apps/thanos/rules/` and sends firing alerts to Alertmanager.

### Disabled apps

Some apps are in the repository but commented out in `clusters/<cluster>/kustomization.yaml`,
because the lab does not have enough RAM for them. To turn one on, remove the `#` in front of its
line and merge.

| App | Lines | What it does |
|---|---|---|
| Logs | hub: `loki.yaml`; spoke: `opentelemetry-collector.yaml` | Every pod's logs from the spokes into Loki on the hub, searchable in Grafana (data source *Loki*) |
| Trivy Operator | hub: `trivy-operator.yaml` | Scans every running image for known vulnerabilities (`kubectl get vulnerabilityreports -A`) and checks workload settings (`kubectl get configauditreports -A`) |

Commenting a line out again does not remove what the app installed: Argo CD only deletes the
`Application`. Remove the app's objects by hand afterwards (its custom resources first, then its
namespace and `Subscription`).

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

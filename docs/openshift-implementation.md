# Implementing the fleet pattern on OpenShift + RHACM (vSphere)

This guide translates the lab in this repository, **file by file and in the order it was built**,
into a real OpenShift **hub** running Red Hat Advanced Cluster Management (RHACM) and OpenShift
GitOps. The hub creates OpenShift **spoke** clusters in vCenter from Git and imports them
automatically.

The guide covers exactly what the lab does today, nothing more. Phases the lab has not built yet
are listed under [Next steps](#11-next-steps) and are added here when they are done.

> **Versions change.** API fields for Hive's vSphere platform, operator channels and release
> images differ between RHACM and OpenShift versions. Before you write a manifest, run the
> commands in [1.1 Look up what your hub runs](#11-look-up-what-your-hub-runs) and use their
> output instead of the example values.

## Contents

1. [Prerequisites](#1-prerequisites)
   - [1.1 Look up what your hub runs](#11-look-up-what-your-hub-runs)
2. [Lab file to OpenShift file](#2-lab-file-to-openshift-file)
3. [Bootstrap the hub (one time)](#3-bootstrap-the-hub-one-time)
4. [cert-manager](#4-cert-manager)
5. [RHACM](#5-rhacm)
6. [Cluster provisioning engine and release images](#6-cluster-provisioning-engine-and-release-images)
7. [The provisioning ApplicationSet](#7-the-provisioning-applicationset)
8. [Define a spoke cluster in vCenter](#8-define-a-spoke-cluster-in-vcenter)
9. [Verify](#9-verify)
10. [Operational guardrails](#10-operational-guardrails)
11. [Next steps](#11-next-steps)

---

## 1. Prerequisites

| Need | Notes |
|---|---|
| A hub OpenShift cluster | Installed with the OpenShift installer. 3 control-plane nodes. RHACM sizing depends on the number of clusters. |
| An internal Git server | GitLab or Gitea inside your security boundary. The repository describes your network (VIPs, machine networks, vCenter), so it must not be public. |
| vCenter access for the installer | A service account with the [vSphere privileges OpenShift needs](https://docs.openshift.com/container-platform/latest/installing/installing_vsphere/ipi/ipi-vsphere-installation-reqs.html), a VM folder, a datastore, a port group, and the vCenter CA certificate. |
| Network from the hub | The installer runs in a pod **on the hub**. The hub needs HTTPS to vCenter **and** to the ESXi hosts (the RHCOS image is uploaded through them), and later to the new cluster's API VIP on port 6443. |
| Red Hat pull secret | From console.redhat.com, or your mirror registry's credentials in a disconnected environment. |
| DNS and IPs per spoke | `api.<cluster>.<domain>` and `*.apps.<cluster>.<domain>`, pointing at two free VIPs in the machine network. |
| Disconnected only | Mirrored operator catalogs (`CatalogSource`), mirrored release images, and `ImageDigestMirrorSet`. |

### 1.1 Look up what your hub runs

The manifests in this guide contain values that depend on your versions and your environment. Run
these commands on the hub and use their output instead of the example values. None of them change
anything. The step column says where each value is used.

**Versions and catalogs**

```bash
oc get clusterversion                                     # OpenShift version of the hub
oc get catalogsource -n openshift-marketplace             # source: in every Subscription (3.3, 4, 5)

# Channels and the default channel of each operator this guide installs (3.3, 4, 5)
for p in openshift-gitops-operator openshift-cert-manager-operator advanced-cluster-management multicluster-engine; do
  echo "== $p"
  oc get packagemanifest "$p" -n openshift-marketplace \
    -o jsonpath='default: {.status.defaultChannel}{"\n"}{range .status.channels[*]}{.name}{"  "}{.currentCSV}{"\n"}{end}'
done
```

**Operators that are already installed.** If someone installed an operator through the console,
don't install it a second time. Export what is there and use it as the base for the file in Git.
Remove `status`, `uid`, `resourceVersion`, `creationTimestamp` and `managedFields` before you
commit it.

```bash
oc get subscriptions.operators.coreos.com -A              # what is installed, from which channel
oc get csv -A | grep -Ei 'gitops|cert-manager|advanced-cluster|multicluster'
oc get operatorgroup -A
oc -n open-cluster-management get subscriptions.operators.coreos.com -o yaml
oc -n open-cluster-management get multiclusterhub -o yaml
```

**OpenShift GitOps (3.3, 3.4)**

```bash
oc get argocd -A                                          # instance name, normally openshift-gitops
oc api-resources --api-group=argoproj.io                  # apiVersion of ArgoCD (v1beta1 or v1alpha1)
oc -n openshift-gitops get sa | grep application-controller   # ServiceAccount for clusterrolebinding.yaml
oc -n openshift-gitops get argocd openshift-gitops -o yaml    # see what the operator already sets
```

**RHACM, MCE and Hive (5, 6, 8)**

```bash
oc -n open-cluster-management get multiclusterhub -o jsonpath='{.items[0].status.currentVersion}{"\n"}'
oc get multiclusterengine -o jsonpath='{.items[0].status.currentVersion}{"\n"}'

# API versions of every kind in step 6 and 8
oc api-resources | grep -Ei 'clusterdeployment|machinepool|clusterimageset|managedcluster |klusterletaddonconfig|multiclusterhub'

# Fields: use these instead of the examples, and skip anything marked deprecated
oc explain clusterdeployment.spec.platform.vsphere --recursive
oc explain clusterdeployment.spec.provisioning
oc explain machinepool.spec.platform.vsphere --recursive
oc explain klusterletaddonconfig.spec
oc explain multiclusterhub.spec

oc get clusterimagesets                                   # releases RHACM already offers (6)
oc get hiveconfig hive -o yaml                            # proxy and other global Hive settings
```

**vCenter values for the install-config (8.2, 8.3).** If the hub itself runs on the same vCenter,
it already holds most of the values the spoke needs: vCenter, datacenter, cluster, datastore,
network and folder.

```bash
# 1. vCenter and topology (failure domains). Empty on hubs that were upgraded from before 4.13:
#    then use 2 and 3.
oc get infrastructure cluster -o jsonpath='{.spec.platformSpec.vsphere}' | jq

# 2. The hub's own install-config, as it was installed. Passwords are removed from the output.
oc -n kube-system get cm cluster-config-v1 -o jsonpath='{.data.install-config}' \
  | grep -vi -e password -e pullSecret

# 3. Where the hub's machines really are: folder, datastore, resource pool, port group, template
oc -n openshift-machine-api get machinesets \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{.spec.template.spec.providerSpec.value.workspace}{"\n"}{.spec.template.spec.providerSpec.value.network}{"\n"}{end}'

# 4. The hub's network CIDRs: the spoke's must not overlap them
oc get network.config cluster -o jsonpath='{.spec}' | jq

# 5. The hub's VIPs: the spoke needs two NEW free addresses, never these
oc get infrastructure cluster -o jsonpath='{.status.platformStatus.vsphere}' | jq
```

What to take from the hub, and what must be new for the spoke:

| Spoke field | Where the value comes from | Reuse or new |
|---|---|---|
| `platform.vsphere.vcenters[].server`, `ClusterDeployment` `vCenter` | 1 `vcenters[].server`, or 3 `workspace.server` | Reuse |
| `vcenters[].datacenters`, `topology.datacenter`, `ClusterDeployment` `datacenter` | 1 `failureDomains[].topology.datacenter`, or 3 `workspace.datacenter` | Reuse |
| `topology.computeCluster`, `ClusterDeployment` `cluster` | 1 `topology.computeCluster`, or 2 `platform.vsphere` | Reuse. `ClusterDeployment` takes the last part of the path only. |
| `topology.datastore`, `ClusterDeployment` `defaultDatastore` | 1 `topology.datastore`, or 3 `workspace.datastore` | Reuse, or ask the vSphere team for a separate one. `defaultDatastore` takes the last part only. |
| `topology.networks`, `ClusterDeployment` `network` | 1 `topology.networks`, or 3 `network.devices[].networkName` | Reuse if the spoke lives in the same network. A new port group means new VIPs and a new CIDR. |
| `topology.folder`, `ClusterDeployment` `folder` | 3 `workspace.folder` shows the pattern, e.g. `/dc1/vm/<hub>` | **New**: `/<datacenter>/vm/<spoke>`. Ask the vSphere team to create it, or check that the installer account may create folders. |
| `topology.resourcePool` | 1 or 3 `workspace.resourcePool` | Reuse, if your hub uses one |
| `networking.machineNetwork` | 2 `networking.machineNetwork` | Same CIDR if the spoke uses the same port group |
| `networking.clusterNetwork`, `serviceNetwork` | 4 | Can be the same as the hub's. These are internal to each cluster. |
| `apiVIPs`, `ingressVIPs` | 5 shows the hub's | **New**: two free IPs in the machine network, from the network team |
| `baseDomain` | 2 `baseDomain` | Usually reuse. The spoke becomes `api.<spoke>.<baseDomain>`, so DNS records are **new**. |
| `vsphere-certs` (`.cacert`) | `oc -n openshift-config get cm kube-cloud-config -o jsonpath='{.data.ca-bundle\.pem}'`, or download from `https://<vcenter>/certs/download.zip` | Reuse |
| `vsphere-creds` | The account the hub uses: `oc -n kube-system get secret vsphere-creds -o jsonpath='{.data}' \| jq 'keys'` shows the key names only | Use a separate installer account for spokes if you can, so the hub's account can be rotated on its own |
| `imageDigestSources` (disconnected) | `oc get imagedigestmirrorset -o yaml` | Reuse |
| `sshKey` | 2 `sshKey` | Reuse, or your team's own key |

If a vSphere credential was created in the RHACM console (**Credentials**), it holds the same
values. Print it **without** the password, pull secret and SSH key:

```bash
oc get secret -A -l cluster.open-cluster-management.io/type=vmw
oc -n <namespace> get secret <name> -o json \
  | jq '.data | map_values(@base64d) | del(.password, .pullSecret, .sshPrivatekey)'
```

**Pull secret and mirrors (8.2)**

```bash
# The hub's own pull secret. In a disconnected environment it also holds the mirror registry login.
oc -n openshift-config extract secret/pull-secret --keys=.dockerconfigjson --to=- > pull-secret.json

# Disconnected: the mirrors the spoke's install-config needs under imageDigestSources
oc get imagedigestmirrorset -o yaml
oc get imagecontentsourcepolicy -o yaml                   # older clusters
```

**The install-config schema of the exact release you install (8.2).** `openshift-install explain`
shows every field, and comes from the release image itself:

```bash
oc adm release extract --command=openshift-install --to=. \
  quay.io/openshift-release-dev/ocp-release:4.19.10-x86_64   # the releaseImage from your ClusterImageSet
./openshift-install explain installconfig.platform.vsphere
./openshift-install explain installconfig.platform.vsphere.failureDomains
```

`pull-secret.json` and `openshift-install` are only for your workstation. Never commit them.

## 2. Lab file to OpenShift file

Every file in the lab, and what it becomes. **Same** means the file is copied as it is, apart from
the Git URL and the hub name.

| Lab file | Built in | On OpenShift + RHACM | Step |
|---|---|---|---|
| `overlays/k3d-hub-01/k3d-cluster.yaml` | PR #9 | Removed: the hub is installed with the OpenShift installer | 3.1 |
| `scripts/bootstrap.sh` | PR #11 | Two commands by hand: install the GitOps operator, `helm install` the bootstrap chart | 3.3, 3.4 |
| `base/olm.yaml` | | Removed: OLM is built in | 3.2 |
| `base/argocd.yaml` (upstream operator chart) | | Application for `applications/openshift-gitops/` | 3.3 |
| `base/cert-manager.yaml` (upstream chart) | PR #13 | Application for `applications/cert-manager/` (Red Hat operator) | 4 |
| `applications/ocm-hub/` | PR #12 | `applications/rhacm/` | 5 |
| `applications/ocm-hub/bootstrap-sa.yaml` | PR #20 | Removed: RHACM's import controller handles it | 5 |
| `overlays/k3d-hub-01/ocm-hub.yaml` | PR #12 | `overlays/<hub>/rhacm.yaml` | 5 |
| `overlays/k3d-hub-01/capi.yaml` | PR #14 | Removed: Hive ships with RHACM | 6 |
| (none: the Kubernetes version is in `controlplane.yaml`) | | New: `applications/cluster-imagesets/` + `overlays/<hub>/cluster-imagesets.yaml` | 6 |
| `helm/bootstrap/templates/appproject.yaml` | PR #16 | Same | 3.4 |
| `helm/bootstrap/templates/application.yaml` | | Same | 3.4 |
| `helm/bootstrap/templates/argocd-tls-certs.yaml` | | Same | 3.4 |
| `helm/bootstrap/templates/clusterrolebinding.yaml` | | Same, but a different ServiceAccount name | 3.4 |
| `helm/bootstrap/templates/namespace.yaml` | | Removed: the operator owns `openshift-gitops` | 3.4 |
| `helm/bootstrap/templates/cluster-info.yaml` | PR #20 | Removed: RHACM knows the hub's API address | 3.4 |
| `helm/infra/` | | Same | 3.4 |
| `overlays/k3d-hub-01/spoke-provisioning.yaml` | PR #17, #27 | Same | 7 |
| `managed-clusters/<cluster>/namespace.yaml` | PR #15 | Same | 8.1 |
| (none: Docker needs no credentials) | | Four Secrets created **by hand** on the hub, never in Git | 8.2 |
| `managed-clusters/<cluster>/cluster.yaml` | PR #15 | `clusterdeployment.yaml` | 8.3 |
| `managed-clusters/<cluster>/controlplane.yaml` | PR #15 | Control plane: `install-config` (8.2). Workers: `machinepool.yaml` | 8.2, 8.4 |
| `managed-clusters/<cluster>/cni.yaml` + `cni/kindnet.yaml` | PR #19 | Removed: `networkType: OVNKubernetes` in `install-config` | 8.2 |
| `managed-clusters/<cluster>/managedcluster.yaml` | PR #21 | Same, plus a `KlusterletAddonConfig` | 8.5 |
| `managed-clusters/<cluster>/import-rbac.yaml` | PR #22 | Removed: RHACM already reads Hive's kubeconfig Secrets | 8.5 |
| `managed-clusters/<cluster>/kustomization.yaml` | PR #15 | New resource list, no `configMapGenerator` | 8.6 |
| `ClusterManager` feature gates (`ClusterImporter`, auto-approval) | PR #20 | Removed: built into RHACM | 5 |
| Host inotify limits (`/etc/sysctl.d/`) | | Removed: every cluster has its own nodes | |

The result, in your work repository:

```
cluster/
├── base/
│   ├── kustomization.yaml               # 3.2  argocd.yaml + cert-manager.yaml
│   ├── argocd.yaml                      # 3.3  wave -5
│   └── cert-manager.yaml                # 4    wave -3
├── applications/
│   ├── openshift-gitops/                # 3.3
│   │   ├── kustomization.yaml
│   │   ├── subscription.yaml
│   │   └── argocd.yaml
│   ├── cert-manager/                    # 4
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── operatorgroup.yaml
│   │   └── subscription.yaml
│   ├── rhacm/                           # 5
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── operatorgroup.yaml
│   │   ├── subscription.yaml
│   │   └── multiclusterhub.yaml
│   └── cluster-imagesets/               # 6
│       ├── kustomization.yaml
│       └── img4.19.10-x86-64.yaml
└── overlays/
    └── <hub>/
        ├── kustomization.yaml           # ../../base + the files below
        ├── rhacm.yaml                   # 5  wave 0
        ├── cluster-imagesets.yaml       # 6  wave 1
        ├── spoke-provisioning.yaml      # 7  wave 2
        ├── managed-clusters/            # 8  applied to the HUB: the clusters this hub owns
        │   └── ocp-prod-01/
        │       ├── kustomization.yaml
        │       ├── namespace.yaml
        │       ├── clusterdeployment.yaml
        │       ├── machinepool.yaml
        │       └── managedcluster.yaml
        └── helm/
            ├── bootstrap/               # 3.4  installed once with helm
            │   ├── Chart.yaml
            │   ├── values.yaml
            │   └── templates/
            │       ├── clusterrolebinding.yaml
            │       ├── appproject.yaml
            │       ├── application.yaml
            │       └── argocd-tls-certs.yaml
            └── infra/                   # 3.4  same as the lab
                ├── Chart.yaml
                ├── values.yaml
                └── templates/application.yaml
```

Protect `main` before the first cluster depends on it:

- Require a pull request before merging, and do not allow anyone to bypass it.
- Require at least one approval for anything under `cluster/overlays/<hub>/managed-clusters/`
  (for example with a `CODEOWNERS` entry). A merge there creates or changes a whole cluster.
- Run `kustomize build` on every overlay in CI. A folder that does not render stops Argo CD from
  syncing everything in it.

## 3. Bootstrap the hub (one time)

### 3.1 The hub itself

Lab: `k3d-cluster.yaml` and the first step of `bootstrap.sh`. On OpenShift, the hub is installed
with the OpenShift installer. There is nothing to put in Git for this step.

### 3.2 `base/kustomization.yaml`: remove OLM

OLM is built into OpenShift. Delete `base/olm.yaml`, and remove it from the list:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - argocd.yaml
  - cert-manager.yaml
```

### 3.3 OpenShift GitOps

Lab: `base/argocd.yaml` installs the upstream Argo CD operator from `operatorhubio-catalog` in the
`olm` namespace, which does not exist on OpenShift. It also creates its own Argo CD instance
called `argocd`. On OpenShift you use the **default instance**, `openshift-gitops`, which the
operator creates by itself.

The lab keeps the operator and the instance in Git, installs them once by hand from the same
source (`bootstrap.sh`), and lets Argo CD adopt them. Do the same here.

`cluster/applications/openshift-gitops/subscription.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-gitops-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  name: openshift-gitops-operator
  channel: gitops-1.x                # pin the channel you have validated
  source: redhat-operators           # your mirrored CatalogSource if disconnected
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual        # upgrades are deliberate: approve the InstallPlan
```

`cluster/applications/openshift-gitops/argocd.yaml`: only the fields the lab adds. Argo CD
applies it with server-side apply, so every other field of the default instance stays as the
operator set it. That includes OpenShift login (SSO) and the RBAC that makes `cluster-admins`
Argo CD admins. Do **not** copy the lab's `rbac` or `sso: null`: on OpenShift that would lock you
out.

```yaml
# The default instance, created by the operator. Only the fields below are managed from Git.
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: openshift-gitops
  namespace: openshift-gitops
spec:
  resourceHealthChecks:
    # Required for sync waves between Applications (app of apps ordering)
    - group: argoproj.io
      kind: Application
      check: |
        hs = {}
        hs.status = "Progressing"
        hs.message = ""
        if obj.status ~= nil and obj.status.health ~= nil then
          hs.status = obj.status.health.status
          if obj.status.health.message ~= nil then
            hs.message = obj.status.health.message
          end
        end
        return hs
```

`cluster/applications/openshift-gitops/kustomization.yaml` lists both files.

`cluster/base/argocd.yaml` now points at that folder instead of a Helm chart:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "-5"
spec:
  project: default
  source:
    repoURL: https://git.example.internal/platform/fleet.git
    targetRevision: main
    path: cluster/applications/openshift-gitops
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

**Install it once by hand** (this is what `bootstrap.sh` does in the lab). With
`installPlanApproval: Manual`, even the **first** install waits for approval:

```bash
oc apply -f cluster/applications/openshift-gitops/subscription.yaml
oc -n openshift-gitops-operator get installplan              # APPROVED false
oc -n openshift-gitops-operator patch installplan <name> --type merge -p '{"spec":{"approved":true}}'
oc -n openshift-gitops get argocd openshift-gitops           # wait until it exists
oc apply --server-side -f cluster/applications/openshift-gitops/argocd.yaml
```

### 3.4 The bootstrap chart

Copy `cluster/overlays/k3d-hub-01/helm/bootstrap/` and `helm/infra/` to `cluster/overlays/<hub>/`
and change these things:

| File | Change |
|---|---|
| `templates/namespace.yaml` | **Delete.** The operator already created `openshift-gitops`, and Helm fails on a namespace it does not own. |
| `templates/cluster-info.yaml` | **Delete.** Only the lab's OCM needed it. |
| `templates/clusterrolebinding.yaml` | ServiceAccount `argocd-argocd-application-controller` becomes `openshift-gitops-argocd-application-controller`, because the instance is called `openshift-gitops`. |
| `values.yaml` | `cluster: <hub>`, `repoURL:` your internal Git server. Remove `hubApiServerURL`. `argocdNamespace` stays `openshift-gitops`. |
| `templates/appproject.yaml` | Same as the lab: `Application` and `ApplicationSet` only. |
| `templates/application.yaml`, `templates/argocd-tls-certs.yaml` | Same as the lab. |
| `helm/infra/values.yaml` | `repoURL:` and `path: cluster/overlays/<hub>`. |

`argocd-tls-certs.yaml` is how Argo CD trusts your corporate CA for the Git server. Put the CA in
a local values file that is never committed, exactly like in the lab:

```bash
helm upgrade --install bootstrap cluster/overlays/<hub>/helm/bootstrap \
  -n openshift-gitops -f bootstrap.local.yaml
```

### 3.5 Verify

```bash
oc -n openshift-gitops get applications       # root, infra, argocd, cert-manager, ...
oc -n openshift-gitops get route openshift-gitops-server
```

Log in through the route with your OpenShift account.

## 4. cert-manager

Lab: `base/cert-manager.yaml` installs the upstream Helm chart. On OpenShift, use the **cert-manager
Operator for Red Hat OpenShift**. The `Certificate` and `ClusterIssuer` APIs are the same.

`cluster/applications/cert-manager/` (`namespace.yaml`, `operatorgroup.yaml`, `subscription.yaml`
and a `kustomization.yaml` that lists them):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
    - cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  name: openshift-cert-manager-operator
  channel: stable-v1
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
```

`cluster/base/cert-manager.yaml` points at the folder, in the same wave as in the lab:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  project: default
  source:
    repoURL: https://git.example.internal/platform/fleet.git
    targetRevision: main
    path: cluster/applications/cert-manager
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

Approve the first InstallPlan, then check that cert-manager runs:

```bash
oc -n cert-manager-operator get installplan
oc -n cert-manager-operator patch installplan <name> --type merge -p '{"spec":{"approved":true}}'
oc -n cert-manager get pods
```

## 5. RHACM

Lab: `applications/ocm-hub/` and `overlays/k3d-hub-01/ocm-hub.yaml`. RHACM belongs in the **hub
overlay only**.

`cluster/applications/rhacm/`: the same four files as `ocm-hub/` (`namespace.yaml`,
`operatorgroup.yaml`, `subscription.yaml`, and the hub CR). `clustermanager.yaml` becomes
`multiclusterhub.yaml`. `bootstrap-sa.yaml` is not needed.

```yaml
# namespace.yaml: same name as in the lab
apiVersion: v1
kind: Namespace
metadata:
  name: open-cluster-management
---
# operatorgroup.yaml: same as the lab
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: open-cluster-management
  namespace: open-cluster-management
spec:
  targetNamespaces:
    - open-cluster-management
---
# subscription.yaml: the lab's comment already names these values
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: open-cluster-management
spec:
  name: advanced-cluster-management
  channel: release-2.x             # pin the minor you have validated, e.g. release-2.14
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
---
# multiclusterhub.yaml: replaces clustermanager.yaml, with the same annotations.
# None of the lab's feature gates are needed: import and approval are built in.
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec: {}
```

`cluster/overlays/<hub>/rhacm.yaml` is the lab's `ocm-hub.yaml` with a new name and path. Keep
the `retry` block: the first sync runs before the `MultiClusterHub` CRD exists.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rhacm
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://git.example.internal/platform/fleet.git
    targetRevision: main
    path: cluster/applications/rhacm
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
    retry:
      limit: 10
      backoff:
        duration: 15s
        factor: 2
        maxDuration: 3m
```

Approve the InstallPlan. RHACM then installs the multicluster engine (MCE), which may create a
second InstallPlan:

```bash
oc -n open-cluster-management get installplan
oc -n open-cluster-management patch installplan <name> --type merge -p '{"spec":{"approved":true}}'
oc -n multicluster-engine get installplan                 # approve here too if it waits
oc -n open-cluster-management get multiclusterhub         # STATUS Running (takes 10+ minutes)
oc get managedclusters                                    # local-cluster: the hub itself
```

## 6. Cluster provisioning engine and release images

Lab: `overlays/k3d-hub-01/capi.yaml` installs Cluster API. On OpenShift, **Hive** does that job,
and MCE installs it together with RHACM. Delete `capi.yaml`, and add nothing in its place.

In the lab, the Kubernetes version of a spoke is set in `controlplane.yaml`. Hive instead refers
to a cluster-scoped **`ClusterImageSet`** that names the OpenShift release. Several spokes share
it, so it lives on the hub and not in a spoke folder. This is the only new file that has no lab
counterpart.

`cluster/applications/cluster-imagesets/img4.19.10-x86-64.yaml`:

```yaml
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: img4.19.10-x86-64
spec:
  # Disconnected: your mirror registry, by digest
  releaseImage: quay.io/openshift-release-dev/ocp-release:4.19.10-x86_64
```

`cluster/overlays/<hub>/cluster-imagesets.yaml` is an Application for that folder in **wave 1**,
the wave `capi.yaml` had. Hive's CRD must exist before it syncs, so give it the same `retry` block
as `rhacm.yaml`.

In a connected environment, RHACM may already create ClusterImageSets by itself. Check with
`oc get clusterimagesets` before you add your own.

## 7. The provisioning ApplicationSet

Lab: PR #16 (`appproject.yaml`), PR #17 and PR #27 (`spoke-provisioning.yaml`). Both are **the
same** on OpenShift. `appproject.yaml` already allows `ApplicationSet` since step 3.4.

`cluster/overlays/<hub>/spoke-provisioning.yaml`: copy the lab's file and change only the Git URL
and the hub name in the path.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: spoke-provisioning
  namespace: openshift-gitops
  annotations:
    # After Hive's CRDs exist (RHACM wave 0, cluster-imagesets wave 1)
    argocd.argoproj.io/sync-wave: "2"
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://git.example.internal/platform/fleet.git
        revision: main
        directories:
          - path: cluster/overlays/<hub>/managed-clusters/*
  template:
    metadata:
      name: '{{ .path.basename }}-provisioning'
    spec:
      project: default
      source:
        repoURL: https://git.example.internal/platform/fleet.git
        targetRevision: main
        path: '{{ .path.path }}'
      destination:
        server: https://kubernetes.default.svc
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - ServerSideApply=true
  syncPolicy:
    # Deleting the ApplicationSet, or a folder, must never delete a running cluster
    preserveResourcesOnDeletion: true
```

The hub overlay's `kustomization.yaml` is the lab's list with `ocm-hub.yaml` and `capi.yaml`
replaced. Like in the lab, it does **not** list `managed-clusters/`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - rhacm.yaml
  - cluster-imagesets.yaml
  - spoke-provisioning.yaml
```

## 8. Define a spoke cluster in vCenter

Everything in Git goes in `cluster/overlays/<hub>/managed-clusters/<spoke>/`, just like
`k3d-spoke-01`. The examples use the spoke name `ocp-prod-01`. The **namespace name must equal
the cluster name**, as in the lab.

### 8.1 `namespace.yaml`: same as the lab

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ocp-prod-01
```

### 8.2 Secrets, created by hand (not in Git)

The lab needed no credentials, because Docker creates the "machines". vCenter does. Until a
secret store and the External Secrets Operator are in place, create these four Secrets **by hand**
in the cluster's namespace on the hub. Do it **before** you merge the pull request, so Hive finds
them on its first attempt. Argo CD then takes over the existing namespace from `namespace.yaml`.

| Secret | Keys | Used by |
|---|---|---|
| `vsphere-creds` | `username`, `password` | Hive: provisioning, MachinePools, deprovisioning |
| `vsphere-certs` | `.cacert` | Hive: trusting vCenter's TLS certificate |
| `pull-secret` | `.dockerconfigjson` | Hive: the installer's pull secret |
| `ocp-prod-01-install-config` | `install-config.yaml` | Hive: the cluster's installation parameters |

The names are the contract with `clusterdeployment.yaml`. Later, `ExternalSecret` objects create
Secrets with **the same names**, and nothing in Git has to change (see step 11).

First write the `install-config.yaml`. It replaces the lab's `controlplane.yaml` (the control
plane) and `cni/kindnet.yaml` (`networkType`). Keep it **outside the repository**: it contains the
vCenter password, like the install-config that the RHACM console generates. A minimal example
for vSphere IPI on OpenShift 4.13+:

```yaml
apiVersion: v1
metadata:
  name: ocp-prod-01
baseDomain: example.internal
controlPlane:                         # lab: controlplane.yaml
  name: master
  replicas: 3
  platform:
    vsphere:
      cpus: 4
      coresPerSocket: 2
      memoryMB: 16384
      osDisk:
        diskSizeGB: 120
compute:
  - name: worker
    replicas: 3
networking:
  networkType: OVNKubernetes          # lab: cni/kindnet.yaml
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  serviceNetwork:
    - 172.30.0.0/16
  machineNetwork:
    - cidr: 10.10.20.0/24
platform:
  vsphere:
    apiVIPs: [10.10.20.10]
    ingressVIPs: [10.10.20.11]
    vcenters:
      - server: vcenter.example.internal
        datacenters: [dc1]
        user: svc-ocp-installer@vsphere.local
        password: <password>
    failureDomains:
      - name: fd1
        region: region1
        zone: zone1
        server: vcenter.example.internal
        topology:
          datacenter: dc1
          computeCluster: /dc1/host/cluster1
          datastore: /dc1/datastore/ds1
          networks: [ocp-prod-01-pg]
          folder: /dc1/vm/ocp-prod-01
sshKey: ssh-ed25519 AAAA... ops@example.internal
# pullSecret is left out: Hive adds it from pull-secret
```

Then create the namespace and the Secrets:

```bash
oc create namespace ocp-prod-01

# Read the password without echoing it or saving it in the shell history
read -rsp 'vCenter password: ' VC_PASS; echo
oc -n ocp-prod-01 create secret generic vsphere-creds \
  --from-literal=username='svc-ocp-installer@vsphere.local' \
  --from-literal=password="$VC_PASS"
unset VC_PASS

oc -n ocp-prod-01 create secret generic vsphere-certs \
  --from-file=.cacert=vcenter-ca.pem

oc -n ocp-prod-01 create secret generic pull-secret \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=pull-secret.json

oc -n ocp-prod-01 create secret generic ocp-prod-01-install-config \
  --from-file=install-config.yaml=install-config.yaml
```

Delete the local `install-config.yaml` and `pull-secret.json` afterwards, or keep them in your
password manager. Never commit them.

### 8.3 `clusterdeployment.yaml`: replaces `cluster.yaml`

The lab's `Cluster` + `DevCluster` become one `ClusterDeployment`. The vSphere fields replace the
`DevCluster` (the lab's "infrastructure"). The annotation is the same as in the lab.

```yaml
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: ocp-prod-01
  namespace: ocp-prod-01
  labels:
    cloud: vSphere
    vendor: OpenShift
  annotations:
    # Never let Argo CD delete a cluster (same as the lab's cluster.yaml)
    argocd.argoproj.io/sync-options: Prune=false,Delete=false
spec:
  clusterName: ocp-prod-01
  baseDomain: example.internal
  # Keep the VMs if this object is ever deleted
  preserveOnDelete: true
  platform:
    vsphere:
      # CHECK against your Hive version before you commit (see the box below)
      vCenter: vcenter.example.internal
      datacenter: dc1
      defaultDatastore: ds1
      cluster: cluster1
      network: ocp-prod-01-pg
      folder: /dc1/vm/ocp-prod-01
      credentialsSecretRef:
        name: vsphere-creds
      certificatesSecretRef:
        name: vsphere-certs
  provisioning:
    installConfigSecretRef:
      name: ocp-prod-01-install-config
    imageSetRef:
      name: img4.19.10-x86-64
  pullSecretRef:
    name: pull-secret
```

> **You must check the `platform.vsphere` fields against your hub before the first commit.**
> Hive has changed this section between versions: newer versions can take the vSphere settings
> in another shape, and the flat fields above may be deprecated. Do both checks:
>
> 1. `oc explain clusterdeployment.spec.platform.vsphere --recursive` on your hub. Use the fields
>    it lists, and move away from any field it marks as deprecated.
> 2. Start **Create cluster → VMware vSphere** in the RHACM console, fill in the form, and turn
>    on the **YAML** view before you click Create. Compare the `ClusterDeployment`,
>    `MachinePool`, `ManagedCluster` and `KlusterletAddonConfig` it generates with the files in
>    this step, and use its field names where they differ. Then cancel: Git creates the cluster,
>    not the console.

### 8.4 `machinepool.yaml`: the worker nodes

The lab spoke has no workers. On OpenShift, Hive manages the workers through a `MachinePool`.
Keep `replicas` the same as `compute` in the install-config.

```yaml
apiVersion: hive.openshift.io/v1
kind: MachinePool
metadata:
  name: ocp-prod-01-worker
  namespace: ocp-prod-01
spec:
  clusterDeploymentRef:
    name: ocp-prod-01
  name: worker
  replicas: 3
  platform:
    vsphere:
      cpus: 4
      coresPerSocket: 2
      memoryMB: 16384
      osDisk:
        diskSizeGB: 120
```

### 8.5 `managedcluster.yaml`: same as the lab, plus add-ons

The `ManagedCluster` is the same API as in the lab. RHACM imports the cluster as soon as Hive has
installed it. That is why `import-rbac.yaml` is not needed. Add a `KlusterletAddonConfig` so the
RHACM add-ons (policies, search, applications) are installed on the spoke. It is still required:
the RHACM console's **Create cluster** wizard generates it for every new cluster. Compare its
`spec` with what the console generates for your version (see the box in step 8.3).

```yaml
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ocp-prod-01
  labels:
    cloud: vSphere
    vendor: OpenShift
  annotations:
    # Never let Argo CD remove the registration (for a Hive cluster this can tear it down)
    argocd.argoproj.io/sync-options: Prune=false,Delete=false
spec:
  hubAcceptsClient: true
---
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: ocp-prod-01
  namespace: ocp-prod-01
spec:
  clusterName: ocp-prod-01
  clusterNamespace: ocp-prod-01
  applicationManager:
    enabled: true
  policyController:
    enabled: true
  searchCollector:
    enabled: true
  certPolicyController:
    enabled: true
```

### 8.6 `kustomization.yaml`

The lab's list without `controlplane.yaml`, `cni.yaml`, `import-rbac.yaml` and the
`configMapGenerator`:

```yaml
# Applied to the HUB: how ocp-prod-01 is created and registered.
# The Secrets it uses are created by hand (step 8.2), not from Git.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - clusterdeployment.yaml
  - machinepool.yaml
  - managedcluster.yaml
```

Render it before you commit:

```bash
kustomize build cluster/overlays/<hub>/managed-clusters/ocp-prod-01
```

## 9. Verify

After the pull request is merged, the ApplicationSet creates `ocp-prod-01-provisioning`.
Installation takes 40–60 minutes.

```bash
oc -n openshift-gitops get applications ocp-prod-01-provisioning
oc -n ocp-prod-01 get clusterdeployment                      # INSTALLED becomes true
oc -n ocp-prod-01 get pods                                   # the *-provision-* pod runs the installer
oc -n ocp-prod-01 logs -f -l hive.openshift.io/job-type=provision -c hive
oc get managedclusters ocp-prod-01                           # JOINED and AVAILABLE True
```

If the provision pod fails, the log usually names the cause: a missing vSphere privilege, an
untrusted vCenter certificate (`vsphere-certs`), or no network path from the hub to the ESXi
hosts.

Hive stores the admin credentials in the cluster namespace. Treat them as break-glass access:

```bash
oc -n ocp-prod-01 get clusterdeployment ocp-prod-01 \
  -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}'
```

## 10. Operational guardrails

| Guardrail | Where |
|---|---|
| Pull requests and review for every change, no direct pushes to `main` | Git server |
| `kustomize build` of every overlay in CI | Git server |
| `installPlanApproval: Manual` on every Subscription | `cluster/applications/*/subscription.yaml` |
| Pinned channels and release images | Everywhere |
| `preserveResourcesOnDeletion` on the ApplicationSet, and no finalizer in its template | `spoke-provisioning.yaml` |
| `Prune=false,Delete=false` on `ClusterDeployment` and `ManagedCluster` | `managed-clusters/<spoke>/` |
| `preserveOnDelete: true` on `ClusterDeployment` | `managed-clusters/<spoke>/clusterdeployment.yaml` |
| Review required for the hub's cluster inventory | `CODEOWNERS` on `cluster/overlays/<hub>/managed-clusters/` |
| AppProject limits set by Helm, not by Git | Bootstrap chart |
| No credentials, kubeconfigs, install-configs or keys in Git | Everywhere |
| Do not use **Replace**, **Force** or **Prune** on manual syncs of the hub's platform Applications. They delete and recreate resources, which briefly removes webhooks for the whole fleet. | Argo CD UI, runbook |

## 11. Next steps

These are the lab's next phases. Each one is added to this guide when the lab has built it.

- **Hand the spoke to its own Argo CD.** The hub installs OpenShift GitOps and a `root`
  Application on each new spoke. From then on the spoke's own Argo CD owns `base` and the spoke's
  overlay, `cluster/overlays/<spoke>/`.
- **Secrets from a secret store** (OpenBao or Vault, plus the External Secrets Operator). This
  replaces the manual step 8.2: `ExternalSecret` objects create the same four Secrets with the
  same names, so `clusterdeployment.yaml` does not change. The vCenter credentials and pull secret
  can then be defined once per vCenter on the hub.
- **Internal CA and ingress certificates** on every spoke, issued through cert-manager.
- **Fleet governance** with RHACM policies.

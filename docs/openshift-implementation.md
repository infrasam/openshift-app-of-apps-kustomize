# Implementing the fleet pattern on OpenShift + RHACM (vSphere)

This guide builds the same thing as the lab in this repository, on real infrastructure: an
OpenShift **hub** running Red Hat Advanced Cluster Management (RHACM) and OpenShift GitOps. The
hub creates OpenShift **spoke** clusters on vSphere from Git and registers them automatically.

It covers everything the lab does today. It leaves out the workarounds the lab needed because it
runs on k3d instead of OpenShift (see [Lab-only parts you can skip](#lab-only-parts-you-can-skip)).

> **Versions change.** API fields for Hive's vSphere platform, operator channels and release
> images differ between RHACM and OpenShift versions. Before writing a manifest, check the fields
> against your cluster with `oc explain <kind>.spec` and use the channels in your catalog
> (`oc get packagemanifests -n openshift-marketplace`).

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Git repository and branch protection](#2-git-repository-and-branch-protection)
3. [Bootstrap OpenShift GitOps on the hub (one time)](#3-bootstrap-openshift-gitops-on-the-hub-one-time)
4. [App of apps and the base layer](#4-app-of-apps-and-the-base-layer)
5. [Install RHACM through GitOps](#5-install-rhacm-through-gitops)
6. [The provisioning ApplicationSet](#6-the-provisioning-applicationset)
7. [Define a spoke cluster](#7-define-a-spoke-cluster)
8. [Verify](#8-verify)
9. [Operational guardrails](#9-operational-guardrails)
10. [Next steps](#10-next-steps)

---

## 1. Prerequisites

| Need | Notes |
|---|---|
| A hub OpenShift cluster | 3 control-plane nodes. RHACM sizing depends on the number of clusters. |
| An internal Git server | GitLab or Gitea inside your security boundary. The repository describes your network (VIPs, machine networks, vCenter), so it must not be public. |
| vCenter access for the installer | A service account with the [vSphere privileges OpenShift needs](https://docs.openshift.com/container-platform/latest/installing/installing_vsphere/ipi/ipi-vsphere-installation-reqs.html), a folder, a datastore, a port group, and the vCenter CA certificate. |
| Red Hat pull secret | From console.redhat.com, or your mirror registry's credentials in a disconnected environment. |
| A secret store | Vault, OpenBao or similar, plus the External Secrets Operator. Credentials never go into Git. |
| DNS and IPs per spoke | `api.<cluster>.<domain>` and `*.apps.<cluster>.<domain>`, pointing at two free VIPs in the machine network. |
| Disconnected only | Mirrored operator catalogs (`CatalogSource`), mirrored release images, and `ImageDigestMirrorSet`. |

## 2. Git repository and branch protection

Use the same layout as this repository:

```
cluster/
├── base/                     # Applications every cluster gets
├── applications/<name>/      # Manifests an Application points to (Namespace, OperatorGroup, Subscription, CR)
└── overlays/
    ├── <hub>/                # base + hub-only Applications, bootstrap and infra charts
    └── <spoke>/
        ├── kustomization.yaml    # what runs ON the spoke
        └── provisioning/         # applied to the HUB: how the spoke is created and registered
```

Protect `main` before the first cluster depends on it:

- Require a pull request before merging, and do not allow anyone to bypass it.
- Require at least one approval for anything under `*/provisioning/`. A merge there creates, or
  changes, a whole cluster.
- Run `kustomize build` on every overlay in CI. A folder that does not render stops Argo CD from
  syncing everything in it.

## 3. Bootstrap OpenShift GitOps on the hub (one time)

OLM is built into OpenShift, so nothing like the lab's `olm.yaml` is needed. Only two things are
done by hand, and both are one-time steps. Everything after this comes from Git.

**3.1 Install the operator** (`oc apply`, or through the console):

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
  channel: latest                  # or a pinned gitops-1.x channel
  source: redhat-operators         # your mirrored CatalogSource if disconnected
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual      # upgrades are deliberate: approve the InstallPlan
```

The operator creates an Argo CD instance in `openshift-gitops`.

**3.2 Install the bootstrap chart** with Helm, the same way as `scripts/bootstrap.sh` step 4.
It contains four things:

| Template | Purpose |
|---|---|
| `clusterrolebinding.yaml` | Gives the application controller (`openshift-gitops-argocd-application-controller`) the rights to manage cluster-scoped resources. Scope this down to what the hub's Applications need if your security policy requires it. |
| `appproject.yaml` | The `infra` project. It may only create `Application` and `ApplicationSet` objects in `openshift-gitops`, from your repository only. |
| `application.yaml` | The `root` Application, pointing at `cluster/overlays/<hub>/helm/infra`. |
| `argocd-tls-certs.yaml` | Optional: trust your corporate CA for the Git server, from a values file that is never committed. |

```bash
helm upgrade --install bootstrap cluster/overlays/<hub>/helm/bootstrap -n openshift-gitops
```

The AppProject is installed by Helm, not by Argo CD, on purpose. A broken or malicious commit
cannot widen the project's own permissions.

## 4. App of apps and the base layer

`root` renders `helm/infra`, which creates one Application, `infra`, pointing at the hub's
overlay. Each file in the overlay is itself an Argo CD Application. **Sync waves** order them:

| Wave | Application | Why this order |
|---|---|---|
| -5 | OpenShift GitOps configuration (the `ArgoCD` CR, RBAC, health checks) | Everything else is deployed by it |
| -3 | cert-manager | Webhooks of later operators need certificates |
| 0 | RHACM (hub only) | Needs OLM and certificates |
| 2 | Spoke provisioning ApplicationSet (hub only) | Needs the Hive and ACM CRDs |

Argo CD must wait for a child Application to be healthy before it moves to the next wave. Add the
`Application` health check to the `ArgoCD` CR (see `cluster/base/argocd.yaml`):

```yaml
spec:
  resourceHealthChecks:
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

**cert-manager.** Use the Red Hat operator instead of the upstream chart. The `Certificate` and
`ClusterIssuer` APIs are the same.
`cluster/applications/cert-manager/`:

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

Add a `ClusterIssuer` for your internal PKI (for example ADCS or Vault PKI) in a later wave. Public
ACME does not work for internal-only names.

## 5. Install RHACM through GitOps

RHACM belongs in the **hub layer only**. Spoke overlays never include it.

`cluster/applications/rhacm/`: Namespace, OperatorGroup, Subscription and the hub CR.

```yaml
# Same namespace name as the OCM upstream in the lab
apiVersion: v1
kind: Namespace
metadata:
  name: open-cluster-management
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: open-cluster-management
  namespace: open-cluster-management
spec:
  targetNamespaces:
    - open-cluster-management
---
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
# The hub itself. Its CRD appears only after OLM has installed the operator.
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

The hub overlay's Application for it (`cluster/overlays/<hub>/rhacm.yaml`) must **retry**,
because the first sync runs before the `MultiClusterHub` CRD exists:

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

RHACM includes the multicluster engine (MCE). The engine brings **Hive**, which provisions
clusters, and the **import controller**, which joins them automatically. Nothing extra is needed
for zero-touch import.

Verify:

```bash
oc get multiclusterhub -n open-cluster-management      # STATUS Running
oc get managedclusters                                 # local-cluster (the hub itself)
```

## 6. The provisioning ApplicationSet

**6.1 Allow ApplicationSets in the `infra` project.** Add this to the bootstrap chart's
`appproject.yaml` and run `helm upgrade` again:

```yaml
  namespaceResourceWhitelist:
    - group: argoproj.io
      kind: Application
    - group: argoproj.io
      kind: ApplicationSet
```

**6.2 Add the ApplicationSet** to the hub overlay (`cluster/overlays/<hub>/spoke-provisioning.yaml`).
It creates one Application per `cluster/overlays/*/provisioning` folder. A new cluster is a new
folder in a pull request, and nothing on the hub has to change.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: spoke-provisioning
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://git.example.internal/platform/fleet.git
        revision: main
        directories:
          - path: cluster/overlays/*/provisioning
  template:
    metadata:
      name: '{{ index .path.segments 2 }}-provisioning'
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

The template has no `resources-finalizer`, so deleting a generated Application leaves the
cluster's objects in place. Consider a dedicated AppProject, for example `cluster-provisioning`,
that may only create the kinds listed in the next step.

## 7. Define a spoke cluster

Everything below goes in `cluster/overlays/<spoke>/provisioning/`, with a `kustomization.yaml`
listing each file. The examples use the spoke name `ocp-prod-01`. The **namespace name must equal
the cluster name**, which is an RHACM convention.

**7.1 `namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ocp-prod-01
```

**7.2 `externalsecrets.yaml`: credentials from the secret store.** Three Secrets are needed: the
pull secret, the vCenter credentials, and the vCenter CA certificate. The store name
`vault` and the key paths below are examples.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: pull-secret
  namespace: ocp-prod-01
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault
  target:
    name: pull-secret
    template:
      type: kubernetes.io/dockerconfigjson
  data:
    - secretKey: .dockerconfigjson
      remoteRef:
        key: openshift/pull-secret
        property: dockerconfigjson
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: vsphere-creds
  namespace: ocp-prod-01
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault
  target:
    name: vsphere-creds
  data:
    - secretKey: username
      remoteRef: { key: vsphere/ocp-installer, property: username }
    - secretKey: password
      remoteRef: { key: vsphere/ocp-installer, property: password }
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: vsphere-certs
  namespace: ocp-prod-01
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault
  target:
    name: vsphere-certs
  data:
    - secretKey: .cacert
      remoteRef: { key: vsphere/vcenter-ca, property: cert }
```

Check the `external-secrets.io` API version your operator serves (`oc api-resources | grep
externalsecret`).

**7.3 `install-config`: the cluster's installation parameters.** Hive reads it from a Secret.
It describes the network (machine CIDR, VIPs) and vCenter, so keep it in the secret store and
deliver it with an `ExternalSecret`, the same way as 7.2. A minimal example of the content for
vSphere IPI on OpenShift 4.13+:

```yaml
apiVersion: v1
metadata:
  name: ocp-prod-01
baseDomain: example.internal
controlPlane:
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
  networkType: OVNKubernetes          # the pod network is installed by the installer, day 0
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
        user: ""                      # injected by Hive from vsphere-creds
        password: ""
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
pullSecret: ""                        # injected by Hive from pull-secret
sshKey: ssh-ed25519 AAAA... ops@example.internal
```

Store it in the secret store. Then add a fourth `ExternalSecret` to `externalsecrets.yaml` that
creates a Secret named `ocp-prod-01-install-config`, with the content under the key
`install-config.yaml`.

**7.4 `clusterimageset.yaml`: which OpenShift release to install.** This object is
cluster-scoped, so it can be shared between spokes, for example from the hub overlay. RHACM can
also sync a curated list of them for you.

```yaml
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: img4.19.10-x86-64
spec:
  releaseImage: quay.io/openshift-release-dev/ocp-release:4.19.10-x86_64
```

**7.5 `clusterdeployment.yaml`: the cluster itself.** This is the object that replaces the lab's
Cluster API `Cluster`.

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
    # Never let Argo CD delete a cluster
    argocd.argoproj.io/sync-options: Prune=false,Delete=false
spec:
  clusterName: ocp-prod-01
  baseDomain: example.internal
  # Keep the VMs if this object is ever deleted
  preserveOnDelete: true
  platform:
    vsphere:
      # Field names differ between versions: run `oc explain clusterdeployment.spec.platform.vsphere`
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

**7.6 `machinepool.yaml`: the worker nodes.**

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

**7.7 `managedcluster.yaml`: registration in RHACM.** This is the same API as in the lab. Together
with `KlusterletAddonConfig`, it makes RHACM import the cluster as soon as Hive has installed it.

```yaml
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ocp-prod-01
  labels:
    cloud: vSphere
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: default
  annotations:
    # Deleting the ManagedCluster of a Hive cluster can tear the cluster down
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

**7.8 `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - externalsecrets.yaml
  - clusterdeployment.yaml
  - machinepool.yaml
  - managedcluster.yaml
```

Render it before you commit:

```bash
kustomize build cluster/overlays/ocp-prod-01/provisioning
```

## 8. Verify

After the pull request is merged, the ApplicationSet creates `ocp-prod-01-provisioning`.
Installation takes 40–60 minutes.

```bash
oc -n openshift-gitops get applications ocp-prod-01-provisioning
oc -n ocp-prod-01 get externalsecrets                        # SecretSynced
oc -n ocp-prod-01 get clusterdeployment                      # INSTALLED becomes true
oc -n ocp-prod-01 get pods                                   # the *-provision-* pod runs the installer
oc -n ocp-prod-01 logs -f -l hive.openshift.io/job-type=provision -c hive
oc get managedclusters ocp-prod-01                           # JOINED and AVAILABLE True
```

Hive stores the admin credentials in the cluster namespace. Treat them as break-glass access:

```bash
oc -n ocp-prod-01 get clusterdeployment ocp-prod-01 \
  -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}'
```

## 9. Operational guardrails

| Guardrail | Where |
|---|---|
| Pull requests and review for every change, no direct pushes to `main` | Git server |
| `kustomize build` of every overlay in CI | Git server |
| `installPlanApproval: Manual` on every Subscription | `cluster/applications/*/subscription.yaml` |
| Pinned channels, chart versions and release images | Everywhere |
| `preserveResourcesOnDeletion` on the ApplicationSet, and no finalizer in its template | `spoke-provisioning.yaml` |
| `Prune=false,Delete=false` on `ClusterDeployment` and `ManagedCluster` | `provisioning/` |
| `preserveOnDelete: true` on `ClusterDeployment` | `provisioning/clusterdeployment.yaml` |
| AppProject limits set by Helm, not by Git | Bootstrap chart |
| No credentials, kubeconfigs or keys in Git, only `ExternalSecret` references | Everywhere |
| Do not use **Replace**, **Force** or **Prune** on manual syncs of the hub's platform Applications. They delete and recreate resources, which briefly removes webhooks for the whole fleet. | Argo CD UI, runbook |

## 10. Next steps

These are the next phases of the lab. Add them here as they are completed.

- **Hand the spoke to its own Argo CD.** RHACM installs OpenShift GitOps and a `root` Application
  on each new spoke, through a `Policy` with a `Placement`. From then on the spoke's Argo CD owns
  `base` and the spoke's overlay.
- **Internal CA and ingress certificates** on every spoke, issued through cert-manager.
- **Secrets on the spokes** through the External Secrets Operator and your secret store.
- **Fleet governance** with RHACM policies.

## Lab-only parts you can skip

The lab needed these because it runs on k3d instead of OpenShift. **None of them apply to
OpenShift + RHACM:**

| Lab part | Why it is not needed |
|---|---|
| `cluster/base/olm.yaml` | OLM is built into OpenShift |
| `k3d-cluster.yaml` and the k3d steps in `bootstrap.sh` | The hub is installed with the OpenShift installer |
| Cluster API and its Docker provider (`capi.yaml`) | Hive, from RHACM/MCE, provisions clusters |
| `ClusterResourceSet` with kindnet | The installer sets up OVN-Kubernetes (`networkType` in install-config) |
| `cluster-info` ConfigMap from the bootstrap chart | The RHACM import controller knows the hub's API address |
| Bootstrap ServiceAccount, `ClusterImporter` and auto-approval in `ClusterManager` | Import and approval are built into RHACM |
| `import-rbac.yaml` | The RHACM import controller already reads Hive's kubeconfig Secrets |
| Host inotify limits (`/etc/sysctl.d/`) | Every cluster runs on its own nodes |
| Port-forward to Argo CD | OpenShift GitOps is exposed through a Route with SSO |

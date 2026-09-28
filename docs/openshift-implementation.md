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
7. [Shared credentials for all clusters](#7-shared-credentials-for-all-clusters)
8. [Define a spoke cluster](#8-define-a-spoke-cluster)
9. [Verify](#9-verify)
10. [Operational guardrails](#10-operational-guardrails)
11. [Next steps](#11-next-steps)

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

Use the same layout as this repository. These are all the files this guide creates, with the step
that describes each one:

```
cluster/
├── base/                                # Applications every cluster gets
│   ├── kustomization.yaml
│   ├── argocd.yaml                      # 4  OpenShift GitOps settings
│   └── cert-manager.yaml                # 4  Application -> applications/cert-manager
├── applications/
│   ├── cert-manager/                    # 4
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── operatorgroup.yaml
│   │   └── subscription.yaml
│   ├── rhacm/                           # 5  hub only
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── operatorgroup.yaml
│   │   ├── subscription.yaml
│   │   └── multiclusterhub.yaml
│   ├── cluster-credentials/             # 7  hub only: shared secrets every spoke uses
│   │   ├── kustomization.yaml
│   │   ├── vsphere-vc01.yaml            #    vsphere-creds + vsphere-certs for vCenter vc01
│   │   └── pull-secret.yaml
│   └── cluster-imagesets/               # 8.3 hub only
│       ├── kustomization.yaml
│       └── img4.19.10-x86-64.yaml
└── overlays/
    ├── <hub>/
    │   ├── kustomization.yaml           # ../../base + the Applications below
    │   ├── rhacm.yaml                   # 5  Application
    │   ├── cluster-credentials.yaml     # 7  Application
    │   ├── cluster-imagesets.yaml       # 8.3 Application
    │   ├── spoke-provisioning.yaml      # 6  ApplicationSet
    │   └── helm/
    │       ├── bootstrap/               # 3.2 installed once with helm
    │       │   ├── Chart.yaml
    │       │   ├── values.yaml
    │       │   └── templates/
    │       │       ├── clusterrolebinding.yaml
    │       │       ├── appproject.yaml
    │       │       ├── application.yaml
    │       │       └── argocd-tls-certs.yaml
    │       └── infra/                   # 4  creates the infra Application
    │           ├── Chart.yaml
    │           ├── values.yaml
    │           └── templates/application.yaml
    └── ocp-prod-01/
        └── provisioning/                # 8  applied to the HUB: how the spoke is created
            ├── kustomization.yaml
            ├── namespace.yaml
            ├── install-config-externalsecret.yaml
            ├── clusterdeployment.yaml
            ├── machinepool.yaml
            └── managedcluster.yaml
```

The spoke's own `kustomization.yaml` (what runs **on** the spoke) comes with the next phase, see
step 11.

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
that may only create the kinds listed in step 8.

## 7. Shared credentials for all clusters

Every `ClusterDeployment` needs the same three Secrets **in its own namespace**: the vCenter
credentials, the vCenter CA certificate and the pull secret. You could repeat an `ExternalSecret`
for each of them in every spoke folder. The cleaner way is to define each one **once**, in the hub
layer, with a `ClusterExternalSecret`. The External Secrets Operator then creates the
`ExternalSecret` in every namespace that opts in with a label.

- **One place per vCenter.** Rotate the installer account's password in the secret store, and
  every cluster namespace on the hub picks it up.
- **Several vCenters.** Add one definition per vCenter, and move a cluster by changing its label.
- **Small spoke folders.** They only hold what is unique to the cluster.

Don't use the RHACM console's **Credentials** page (a Secret labelled
`cluster.open-cluster-management.io/type: vmw`) for this. That Secret only feeds the console's
"Create cluster" wizard, and Hive never reads it. With GitOps it would just be a second copy of the
vCenter password to keep in sync.

Put the definitions in `cluster/applications/cluster-credentials/`, and add an Application for them
to the **hub overlay only**, in a wave after the External Secrets Operator. The store name `vault`
and the key paths below are examples.

```yaml
# vCenter vc01: installer account. One definition per vCenter.
apiVersion: external-secrets.io/v1
kind: ClusterExternalSecret
metadata:
  name: vsphere-creds-vc01
spec:
  externalSecretName: vsphere-creds
  namespaceSelectors:
    - matchLabels:
        platform.example.internal/vcenter: vc01
  refreshTime: 1h
  externalSecretSpec:
    secretStoreRef:
      kind: ClusterSecretStore
      name: vault
    target:
      name: vsphere-creds
    data:
      - secretKey: username
        remoteRef: { key: vsphere/vc01/ocp-installer, property: username }
      - secretKey: password
        remoteRef: { key: vsphere/vc01/ocp-installer, property: password }
---
# vCenter vc01: CA certificate, so the installer trusts vCenter's TLS certificate
apiVersion: external-secrets.io/v1
kind: ClusterExternalSecret
metadata:
  name: vsphere-certs-vc01
spec:
  externalSecretName: vsphere-certs
  namespaceSelectors:
    - matchLabels:
        platform.example.internal/vcenter: vc01
  externalSecretSpec:
    secretStoreRef:
      kind: ClusterSecretStore
      name: vault
    target:
      name: vsphere-certs
    data:
      - secretKey: .cacert
        remoteRef: { key: vsphere/vc01/ca, property: cert }
---
# Red Hat pull secret (or mirror registry credentials): the same for every cluster
apiVersion: external-secrets.io/v1
kind: ClusterExternalSecret
metadata:
  name: pull-secret
spec:
  externalSecretName: pull-secret
  namespaceSelectors:
    - matchLabels:
        platform.example.internal/managed-cluster: "true"
  externalSecretSpec:
    secretStoreRef:
      kind: ClusterSecretStore
      name: vault
    target:
      name: pull-secret
      template:
        type: kubernetes.io/dockerconfigjson
    data:
      - secretKey: .dockerconfigjson
        remoteRef: { key: openshift/pull-secret, property: dockerconfigjson }
```

Check the `external-secrets.io` API version your operator serves
(`oc api-resources | grep -i externalsecret`).

**Rotation caveat.** An installed OpenShift cluster keeps its **own** copy of the vSphere
credentials in `kube-system/vsphere-creds`, which the Machine API and the vSphere CSI driver use.
Rotating the credential on the hub updates what Hive uses for new installs and MachinePools. Don't
assume it reaches spokes that are already running: check how your RHACM/Hive version handles it
before you plan a rotation.

## 8. Define a spoke cluster

Everything below goes in `cluster/overlays/<spoke>/provisioning/`, with a `kustomization.yaml`
listing each file. The examples use the spoke name `ocp-prod-01`. The **namespace name must equal
the cluster name**, which is an RHACM convention.

**8.1 `namespace.yaml`**: the labels opt the namespace in to the shared credentials from step 7.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ocp-prod-01
  labels:
    # vsphere-creds + vsphere-certs for the vCenter this cluster runs on
    platform.example.internal/vcenter: vc01
    # pull-secret
    platform.example.internal/managed-cluster: "true"
```

**8.2 `install-config`: the cluster's installation parameters.** This is the only credential-like
object that is unique to the cluster. Hive reads it from a Secret. It describes the network
(machine CIDR, VIPs) and vCenter, so keep it in the secret store, not in Git. A minimal example of
the content for vSphere IPI on OpenShift 4.13+:

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

Store it in the secret store, and deliver it to the cluster namespace in
`install-config-externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ocp-prod-01-install-config
  namespace: ocp-prod-01
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault
  target:
    name: ocp-prod-01-install-config
  data:
    - secretKey: install-config.yaml
      remoteRef: { key: clusters/ocp-prod-01/install-config, property: install-config.yaml }
```

**8.3 `ClusterImageSet`: which OpenShift release to install.** This object is cluster-scoped and
shared by all spokes, so it lives on the hub in `cluster/applications/cluster-imagesets/`, not in
the spoke's folder.

```yaml
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: img4.19.10-x86-64
spec:
  releaseImage: quay.io/openshift-release-dev/ocp-release:4.19.10-x86_64
```

**8.4 `clusterdeployment.yaml`: the cluster itself.** This is the object that replaces the lab's
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

**8.5 `machinepool.yaml`: the worker nodes.**

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

**8.6 `managedcluster.yaml`: registration in RHACM.** This is the same API as in the lab. Together
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

**8.7 `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - install-config-externalsecret.yaml
  - clusterdeployment.yaml
  - machinepool.yaml
  - managedcluster.yaml
```

Render it before you commit:

```bash
kustomize build cluster/overlays/ocp-prod-01/provisioning
```

## 9. Verify

After the pull request is merged, the ApplicationSet creates `ocp-prod-01-provisioning`.
Installation takes 40–60 minutes.

```bash
oc -n openshift-gitops get applications ocp-prod-01-provisioning
oc get clusterexternalsecrets                                # the shared definitions from step 7
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

## 10. Operational guardrails

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
| Shared credentials (vCenter, pull secret) defined once per vCenter in the hub layer; cluster namespaces opt in by label | `cluster/applications/cluster-credentials/` |
| Do not use **Replace**, **Force** or **Prune** on manual syncs of the hub's platform Applications. They delete and recreate resources, which briefly removes webhooks for the whole fleet. | Argo CD UI, runbook |

## 11. Next steps

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

# Implementing the fleet pattern on OpenShift + RHACM (vSphere)

This guide builds the same thing as the lab in this repository, on real infrastructure: an
OpenShift **hub** running Red Hat Advanced Cluster Management (RHACM) and OpenShift GitOps. The
hub creates OpenShift **spoke** clusters on vSphere from Git and registers them automatically.

It covers everything the lab does today, plus two production pieces the lab only adds later: the
External Secrets Operator and shared credentials for all clusters (step 7). It leaves out the
workarounds the lab needed because it runs on k3d instead of OpenShift (see
[Lab-only parts you can skip](#lab-only-parts-you-can-skip)).

> **Versions change.** API fields for Hive's vSphere platform, operator channels and release
> images differ between RHACM and OpenShift versions. Before writing a manifest, check the fields
> against your cluster with `oc explain <kind>.spec` and use the channels in your catalog
> (`oc get packagemanifests -n openshift-marketplace`).

## Before you start: choose a provisioning method

`cluster/overlays/<cluster>/provisioning/` is the contract between "how a cluster comes to exist"
and the rest of the platform. Whatever creates the machines, the folder always ends with a
`ManagedCluster`. Everything after that is identical: import into RHACM, the hand-over to the
spoke's own Argo CD, `base` and overlays. Only the contents of `provisioning/` change.

| Method | Who creates the VMs | `provisioning/` contains | Choose it when |
|---|---|---|---|
| **A. IPI through Hive** (this guide) | `openshift-install`, run by Hive on the hub, through the vCenter API | `ClusterDeployment`, install-config, `MachinePool`, `ManagedCluster` | The hub may hold a vCenter account with the installer's privileges |
| **B. UPI, then import** | Terraform or Ansible, in a pipeline | `ManagedCluster`, `KlusterletAddonConfig` and an `auto-import-secret` (an `ExternalSecret` holding the new cluster's kubeconfig or token) | The installer may not have vCenter privileges, or VM placement is controlled elsewhere |
| **C. Agent-based / `ClusterInstance`** | The agent-based installer, booting VMs that your automation creates | `ClusterInstance` and its templates instead of `ClusterDeployment` | Static IPs without DHCP, or you already use SiteConfig |

Answer these before building the first spoke:

1. May the hub hold a vCenter account with the [IPI privileges](https://docs.openshift.com/container-platform/latest/installing/installing_vsphere/ipi/ipi-vsphere-installation-reqs.html)?
2. DHCP or static IPs on the machine networks? Check what your OpenShift version's IPI supports.
3. Who owns DNS and IP reservations (IPAM), and can records be created automatically?

Steps 1 to 7 and 9 to 11 apply to every method. Step 8 shows method A.

Regardless of the method, Terraform or Ansible usually still creates the **prerequisites** once per
environment: vCenter folders, roles and port groups, DNS records and IP reservations, and the
secret store entries.

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

Use the same layout as this repository. This is every file the guide creates, with the step
that describes it. `<hub>` is your hub's name (for example `ocp-hub-01`), and the spoke is
`ocp-prod-01`.

```
cluster/
├── base/                                   # Applications EVERY cluster gets
│   ├── kustomization.yaml                  # 4.1  lists the files below
│   ├── openshift-gitops.yaml               # 4.2  Application, wave -5
│   ├── cert-manager.yaml                   # 4.2  Application, wave -3
│   └── external-secrets.yaml               # 4.2  Application, wave -2
├── applications/                           # the manifests those Applications point to
│   ├── openshift-gitops/                   # 3.1 + 4.3  (applied by hand once, then owned by Git)
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── operatorgroup.yaml
│   │   ├── subscription.yaml
│   │   └── argocd.yaml                     # settings on the default ArgoCD instance
│   ├── cert-manager/                       # 4.4
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── operatorgroup.yaml
│   │   └── subscription.yaml
│   ├── external-secrets/                   # 4.5
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── operatorgroup.yaml
│   │   ├── subscription.yaml
│   │   └── externalsecretsconfig.yaml
│   ├── rhacm/                              # 5    hub only
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── operatorgroup.yaml
│   │   ├── subscription.yaml
│   │   └── multiclusterhub.yaml
│   ├── cluster-credentials/                # 7    hub only
│   │   ├── kustomization.yaml
│   │   ├── vsphere-vc01.yaml               # vsphere-creds + vsphere-certs for vCenter vc01
│   │   └── pull-secret.yaml
│   └── cluster-imagesets/                  # 8.3  hub only
│       ├── kustomization.yaml
│       └── img4.19.10-x86-64.yaml
└── overlays/
    ├── <hub>/
    │   ├── kustomization.yaml              # 4.1  ../../base + the hub-only Applications below
    │   ├── secret-store.yaml               # 4.6  Application, wave -1
    │   ├── secret-store/                   # 4.6  this cluster's connection to the secret store
    │   │   ├── kustomization.yaml
    │   │   └── clustersecretstore.yaml
    │   ├── rhacm.yaml                      # 5    Application, wave 0
    │   ├── cluster-credentials.yaml        # 7    Application, wave 1
    │   ├── cluster-imagesets.yaml          # 8.3  Application, wave 1
    │   ├── spoke-provisioning.yaml         # 6.2  ApplicationSet, wave 2
    │   └── helm/
    │       ├── bootstrap/                  # 3.2  installed once with helm, never by Argo CD
    │       │   ├── Chart.yaml
    │       │   ├── values.yaml
    │       │   └── templates/
    │       │       ├── clusterrolebinding.yaml
    │       │       ├── appproject.yaml     # 3.2 + 6.1
    │       │       ├── application.yaml    # the root Application
    │       │       └── argocd-tls-certs.yaml
    │       └── infra/                      # 4.1  rendered by root: creates the infra Application
    │           ├── Chart.yaml
    │           ├── values.yaml
    │           └── templates/application.yaml
    └── ocp-prod-01/
        ├── provisioning/                   # 8    applied to the HUB: how the spoke is created
        │   ├── kustomization.yaml          # 8.7
        │   ├── namespace.yaml              # 8.1
        │   ├── install-config-externalsecret.yaml   # 8.2
        │   ├── clusterdeployment.yaml      # 8.4
        │   ├── machinepool.yaml            # 8.5
        │   └── managedcluster.yaml         # 8.6
        └── (kustomization.yaml, helm/)     # 11   what runs ON the spoke, read by its own Argo CD
```

Every folder under `applications/` and every `secret-store/` or `provisioning/` folder has a
`kustomization.yaml` that lists its files:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - operatorgroup.yaml
  - subscription.yaml
```

In the steps below, a YAML block with several objects separated by `---` is split into the files
shown in the tree, one object per file.

Protect `main` before the first cluster depends on it:

- Require a pull request before merging, and do not allow anyone to bypass it.
- Require at least one approval for anything under `*/provisioning/`. A merge there creates, or
  changes, a whole cluster.
- Run `kustomize build` on every overlay in CI. A folder that does not render stops Argo CD from
  syncing everything in it.

## 3. Bootstrap OpenShift GitOps on the hub (one time)

OLM is built into OpenShift, so nothing like the lab's `olm.yaml` is needed. Only two things are
done by hand, and both are one-time steps. Everything after this comes from Git.

**3.1 Install the operator.** Write the files in `cluster/applications/openshift-gitops/` and apply
them once by hand. In step 4, `cluster/base/openshift-gitops.yaml` points Argo CD at the same
folder, so Argo CD adopts the operator without changing it, and upgrades go through Git from then
on.

`namespace.yaml`, `operatorgroup.yaml`, `subscription.yaml`:

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

```bash
oc apply -f cluster/applications/openshift-gitops/namespace.yaml \
         -f cluster/applications/openshift-gitops/operatorgroup.yaml \
         -f cluster/applications/openshift-gitops/subscription.yaml
```

Approve the first InstallPlan (`oc get installplan -n openshift-gitops-operator`). The operator
then creates an Argo CD instance in `openshift-gitops`.

**3.2 Install the bootstrap chart** in `cluster/overlays/<hub>/helm/bootstrap/`, with Helm, the
same way as `scripts/bootstrap.sh` step 4.
This guide uses the operator's default instance, `openshift-gitops`. (The lab runs its own
instance named `argocd` instead, so its chart binds `argocd-argocd-application-controller`.) On
OpenShift the chart needs these templates; the lab's `namespace.yaml` and `cluster-info.yaml` are
not needed:

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

**4.1 The app-of-apps chain.** `root` renders `cluster/overlays/<hub>/helm/infra/`, which creates
one Application, `infra`, pointing at `cluster/overlays/<hub>/`. That folder's
`kustomization.yaml` pulls in `base` plus the hub-only Applications:

```yaml
# cluster/overlays/<hub>/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - secret-store.yaml
  - rhacm.yaml
  - cluster-credentials.yaml
  - cluster-imagesets.yaml
  - spoke-provisioning.yaml
```

```yaml
# cluster/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - openshift-gitops.yaml
  - cert-manager.yaml
  - external-secrets.yaml
```

Add each file to the list in the same pull request that creates it. Each file in these lists is
itself an Argo CD Application. **Sync waves** order them:

| Wave | Application | Why this order |
|---|---|---|
| -5 | OpenShift GitOps configuration: settings on the default `openshift-gitops` `ArgoCD` CR (health checks, RBAC) | Everything else is deployed by it |
| -3 | cert-manager | Webhooks of later operators need certificates |
| -2 | External Secrets Operator | Everything that needs a credential depends on it |
| -1 | `ClusterSecretStore` (the connection to the secret store) | Needs the ESO CRDs |
| 0 | RHACM (hub only) | Needs OLM and certificates |
| 1 | Shared cluster credentials (hub only, step 7) | Needs the store and the operator |
| 1 | `ClusterImageSet`s (hub only, step 8.3) | Needs the Hive CRDs from RHACM |
| 2 | Spoke provisioning ApplicationSet (hub only) | Needs the Hive and ACM CRDs, and the credentials |

**4.2 One Application per component.** Every file in `cluster/base/` and every hub-only file in
`cluster/overlays/<hub>/` (except the ApplicationSet) follows the same template. Only the name,
the wave and the path change:

```yaml
# cluster/base/cert-manager.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager                       # openshift-gitops | external-secrets | secret-store | ...
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "-3"     # from the table above
spec:
  project: default
  source:
    repoURL: https://git.example.internal/platform/fleet.git
    targetRevision: main
    path: cluster/applications/cert-manager   # secret-store: cluster/overlays/<hub>/secret-store
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
    retry:                                 # CRDs from OLM appear after the first sync
      limit: 10
      backoff:
        duration: 15s
        factor: 2
        maxDuration: 3m
```

For `openshift-gitops.yaml` and anything that manages CRDs, set `prune: false`. Argo CD must never
remove its own operator or a CRD with objects in it.

**4.3 Argo CD settings** in `cluster/applications/openshift-gitops/argocd.yaml`. Argo CD must wait
for a child Application to be healthy before it moves to the next wave, so add the `Application`
health check to the default instance. With `ServerSideApply=true`, Argo CD only owns the fields
written here and leaves the operator's defaults alone:

```yaml
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: openshift-gitops
  namespace: openshift-gitops
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

**4.4 cert-manager.** Use the Red Hat operator instead of the upstream chart. The `Certificate` and
`ClusterIssuer` APIs are the same. `cluster/applications/cert-manager/`: `namespace.yaml`,
`operatorgroup.yaml`, `subscription.yaml`:

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

**4.5 External Secrets Operator.** Use the Red Hat operator (OpenShift 4.20 and later). It supports
only the AllNamespaces install mode, so its OperatorGroup has no `targetNamespaces`.
`cluster/applications/external-secrets/`: `namespace.yaml`, `operatorgroup.yaml`,
`subscription.yaml`, `externalsecretsconfig.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: external-secrets-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: external-secrets-operator
  namespace: external-secrets-operator
spec: {}                           # AllNamespaces
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-external-secrets-operator
  namespace: external-secrets-operator
spec:
  name: openshift-external-secrets-operator
  channel: stable-v1
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
---
# The operand: tells the operator to deploy external-secrets. Its CRD appears after install.
apiVersion: operator.openshift.io/v1alpha1
kind: ExternalSecretsConfig
metadata:
  name: cluster
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec: {}
```

**4.6 The connection to the secret store.** This is per cluster (each cluster authenticates to
Vault with its own auth mount), so it lives in the hub's overlay, in
`cluster/overlays/<hub>/secret-store/clustersecretstore.yaml`, with the Application
`cluster/overlays/<hub>/secret-store.yaml` at wave -1. An example for Vault with Kubernetes
authentication, where Vault has a role `external-secrets` bound to the service account below:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault
spec:
  provider:
    vault:
      server: https://vault.example.internal:8200
      path: secret                 # KV mount
      version: v2
      caProvider:                  # trust the corporate CA that signed Vault's certificate
        type: ConfigMap
        name: corporate-ca
        namespace: external-secrets
        key: ca.crt
      auth:
        kubernetes:
          mountPath: kubernetes-hub
          role: external-secrets
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

Check the service account and namespace the operand runs as in your version
(`oc get sa -A | grep external-secrets`), and the `external-secrets.io` API version it serves
(`oc api-resources | grep -i externalsecret`).

## 5. Install RHACM through GitOps

RHACM belongs in the **hub layer only**. Spoke overlays never include it.

`cluster/applications/rhacm/`: `namespace.yaml`, `operatorgroup.yaml`, `subscription.yaml`,
`multiclusterhub.yaml`:

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

The Application for it, `cluster/overlays/<hub>/rhacm.yaml`, follows the template from 4.2 at
wave 0. The `retry` block matters here, because the first sync runs before the `MultiClusterHub`
CRD exists:

```yaml
# cluster/overlays/<hub>/rhacm.yaml
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

**6.1 Allow ApplicationSets in the `infra` project.** Add this to
`cluster/overlays/<hub>/helm/bootstrap/templates/appproject.yaml` and run `helm upgrade` again:

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
# cluster/overlays/<hub>/spoke-provisioning.yaml
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

Put the definitions in `cluster/applications/cluster-credentials/`: the two vCenter objects in
`vsphere-vc01.yaml` and the pull secret in `pull-secret.yaml`. Add the Application
`cluster/overlays/<hub>/cluster-credentials.yaml` (template from 4.2) to the **hub overlay only**,
at wave 1, after the operator and the `ClusterSecretStore` from step 4. The store name `vault` and
the key paths below are examples.

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

This is method A (IPI through Hive). For method B or C, replace 8.2 to 8.5 with the objects from
the table in [Before you start](#before-you-start-choose-a-provisioning-method); 8.1, 8.6 and 8.7
stay the same.

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
`cluster/overlays/ocp-prod-01/provisioning/install-config-externalsecret.yaml`:

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
shared by all spokes, so it lives on the hub, not in the spoke's folder:
`cluster/applications/cluster-imagesets/img4.19.10-x86-64.yaml`, with the Application
`cluster/overlays/<hub>/cluster-imagesets.yaml` (template from 4.2, wave 1). RHACM can also sync a
curated list of them for you.

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

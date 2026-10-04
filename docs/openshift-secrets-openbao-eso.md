# Secrets on OpenShift with OpenBao and External Secrets

When you are done:

- **OpenBao** stores your secrets (it is the open-source version of Vault).
- **External Secrets Operator (ESO)** copies them from OpenBao into normal Kubernetes Secrets.
- Git only contains *where* a secret is, never the value.

Run every command from the root of the Git repository. Each step ends with a **Check**. Do not
start the next step until the check passes.

---

## Step 1: Fill in your values

OpenBao gets its TLS certificate from cert-manager. Set that up first with
[openshift-cert-manager-adcs.md](openshift-cert-manager-adcs.md).

Change the values to match your environment, then paste the block into your terminal. Every
later step uses these variables.

```bash
export HUB=ocp-hub-01                                   # folder name under cluster/overlays/
export APPS_DOMAIN=apps.ocp-hub-01.example.internal     # oc get ingresses.config cluster -o jsonpath='{.spec.domain}'
export REGISTRY=registry.example.internal               # internal image registry
export CHART_REPO=https://charts.example.internal/repository/helm   # internal Helm repo
export GIT_REPO=https://git.example.internal/platform/fleet.git
# The cert-manager issuer from openshift-cert-manager-adcs.md (ADCS). For another issuer type,
# use its group, kind and name instead (e.g. cert-manager.io / ClusterIssuer / <name>).
export ISSUER_GROUP=adcs.certmanager.csf.nokia.com
export ISSUER_KIND=ClusterAdcsIssuer
export ISSUER=adcs
```

**Check:** the OpenBao image and chart are in your internal registry and Helm repo:

```bash
oc image info $REGISTRY/openbao/openbao:2.7.0 --filter-by-os=linux/amd64 | head -3
helm show chart openbao --repo $CHART_REPO --version 0.30.0 | grep version
```

If they are missing, ask whoever runs your mirror to add `quay.io/openbao/openbao:2.7.0` and the
chart `openbao` 0.30.0 from `https://openbao.github.io/openbao-helm`.

**Check:** the cluster already trusts your corporate CA (needed in step 3):

```bash
oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}{"\n"}'
```

A name is printed: good. Nothing is printed: read "If the cluster does not trust the corporate
CA" at the end of step 3 before you continue.

---

## Step 2: Install the External Secrets Operator

This installs Red Hat's operator from OperatorHub, and lets it talk to OpenBao.

```bash
mkdir -p cluster/applications/external-secrets-operator

cat > cluster/applications/external-secrets-operator/operator.yaml <<'EOF'
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
spec: {}
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
# Starts ESO. The network rule lets ESO reach OpenBao (blocked by default).
apiVersion: operator.openshift.io/v1alpha1
kind: ExternalSecretsConfig
metadata:
  name: cluster
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  controllerConfig:
    networkPolicies:
      - name: allow-openbao
        componentName: ExternalSecretsCoreController
        egress:
          - to:
              - namespaceSelector:
                  matchLabels:
                    kubernetes.io/metadata.name: openbao
            ports:
              - protocol: TCP
                port: 8200
EOF

cat > cluster/applications/external-secrets-operator/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - operator.yaml
EOF

cat > cluster/base/external-secrets.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: external-secrets
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  source:
    repoURL: $GIT_REPO
    targetRevision: main
    path: cluster/applications/external-secrets-operator
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
    retry:
      limit: 10
EOF
```

Add `- external-secrets.yaml` to the list in `cluster/base/kustomization.yaml`. Then commit,
open a pull request and merge it.

After the merge, approve the installation (it waits for you because of `Manual`):

```bash
oc -n external-secrets-operator get installplan
oc -n external-secrets-operator patch installplan <NAME> --type merge -p '{"spec":{"approved":true}}'
```

**Check** (it can take a few minutes):

```bash
oc -n external-secrets get pods
```

Three pods `Running`: `external-secrets`, `external-secrets-webhook` and
`external-secrets-cert-controller`.

---

## Step 3: Install OpenBao

OpenBao is installed with a small chart of our own that wraps the official chart. All settings
are in one file, `values.yaml`.

```bash
mkdir -p cluster/applications/openbao/templates

cat > cluster/applications/openbao/Chart.yaml <<EOF
apiVersion: v2
name: openbao
version: 1.0.0
dependencies:
  - name: openbao
    version: 0.30.0
    repository: $CHART_REPO
EOF

cat > cluster/applications/openbao/values.yaml <<EOF
global:
  openshift: true
  tlsDisable: false

openbao:
  injector:
    enabled: false
  server:
    image:
      registry: $REGISTRY
      repository: openbao/openbao
      tag: "2.7.0"
    route:
      enabled: true
      host: openbao.$APPS_DOMAIN
      tls:
        termination: passthrough
    # Counts as ready while sealed, so Argo CD does not wait for the manual unseal
    readinessProbe:
      path: /v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204
    volumes:
      - name: tls
        secret:
          secretName: openbao-tls
      - name: ca
        configMap:
          name: openbao-ca
    volumeMounts:
      - name: tls
        mountPath: /openbao/tls
      - name: ca
        mountPath: /openbao/ca
    extraEnvironmentVars:
      BAO_CACERT: /openbao/ca/ca-bundle.crt
    ha:
      enabled: true
      replicas: 3
      raft:
        enabled: true
        setNodeId: true
        config: |
          ui = true
          listener "tcp" {
            address         = "[::]:8200"
            cluster_address = "[::]:8201"
            tls_cert_file   = "/openbao/tls/tls.crt"
            tls_key_file    = "/openbao/tls/tls.key"
          }
          storage "raft" {
            path = "/openbao/data"
            retry_join {
              leader_api_addr     = "https://openbao-0.openbao-internal:8200"
              leader_ca_cert_file = "/openbao/ca/ca-bundle.crt"
            }
            retry_join {
              leader_api_addr     = "https://openbao-1.openbao-internal:8200"
              leader_ca_cert_file = "/openbao/ca/ca-bundle.crt"
            }
            retry_join {
              leader_api_addr     = "https://openbao-2.openbao-internal:8200"
              leader_ca_cert_file = "/openbao/ca/ca-bundle.crt"
            }
          }
          service_registration "kubernetes" {}
  ui:
    enabled: true
EOF
```

Three small extra files: the TLS certificate, the CA that ESO trusts, and the connection from ESO
to OpenBao (`ClusterSecretStore`).

```bash
cat > cluster/applications/openbao/templates/certificate.yaml <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openbao-tls
  namespace: openbao
spec:
  secretName: openbao-tls
  dnsNames:
    - openbao-active.openbao.svc
    - "*.openbao-internal"
    - openbao.$APPS_DOMAIN
  ipAddresses:
    - 127.0.0.1
  issuerRef:
    group: $ISSUER_GROUP
    kind: $ISSUER_KIND
    name: $ISSUER
EOF

cat > cluster/applications/openbao/templates/ca.yaml <<'EOF'
# OpenShift fills this ConfigMap with the CAs the cluster trusts
apiVersion: v1
kind: ConfigMap
metadata:
  name: openbao-ca
  namespace: openbao
  labels:
    config.openshift.io/inject-trusted-cabundle: "true"
EOF

cat > cluster/applications/openbao/templates/secretstore.yaml <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-auth
  namespace: openbao
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  provider:
    vault:
      server: https://openbao-active.openbao.svc:8200
      path: secret
      version: v2
      caProvider:
        type: ConfigMap
        name: openbao-ca
        namespace: openbao
        key: ca-bundle.crt
      auth:
        kubernetes:
          mountPath: kubernetes
          role: eso
          serviceAccountRef:
            name: eso-auth
            namespace: openbao
EOF

cat > cluster/overlays/$HUB/openbao.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openbao
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: $GIT_REPO
    targetRevision: main
    path: cluster/applications/openbao
  destination:
    server: https://kubernetes.default.svc
    namespace: openbao
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF

helm dependency update cluster/applications/openbao
```

> **ADCS and certificate names.** Some ADCS templates refuse wildcard names (`*.openbao-internal`)
> or short internal names. If the certificate in `openbao` never becomes ready, look at
> `oc -n openbao get adcsrequest` (see the cert-manager guide). Instead of the wildcard you can list
> the three pods: `openbao-0.openbao-internal`, `openbao-1.openbao-internal`, `openbao-2.openbao-internal`.

Add `- openbao.yaml` to the list in `cluster/overlays/$HUB/kustomization.yaml`.

**Check** before you commit (only your registry may appear):

```bash
helm template openbao cluster/applications/openbao -n openbao | grep 'image:' | sort -u
```

Commit everything **except** the folder `cluster/applications/openbao/charts/`. Open a pull
request and merge it.

If your Helm repo needs a login, Argo CD must know it: in the Argo CD UI go to
**Settings → Repositories → Connect Repo**, choose type **Helm**, and enter `$CHART_REPO` with a
read-only user.

**Check** after the merge:

```bash
oc -n openbao get pods
```

Three pods `openbao-0/1/2`, `Running`. They are still locked ("sealed"). That is expected.

### About the certificate

**Why it is needed.** Everything that talks to OpenBao uses HTTPS: ESO when it fetches secrets,
the three OpenBao pods when they talk to each other, and your browser. Each of them checks that
OpenBao's certificate was signed by a CA it trusts. If not, it stops with
`x509: certificate signed by unknown authority`. Never turn the check off: then anyone on the
network could pretend to be your secret store.

**How it works in this guide.** cert-manager gets OpenBao's certificate from your corporate CA
(`certificate.yaml`). OpenShift fills the ConfigMap `openbao-ca` (`ca.yaml`) with every CA the
cluster trusts, which includes your corporate CA. ESO and the OpenBao pods read the CA from there.

### If the cluster does not trust the corporate CA

The check in step 1 printed nothing. You have two options.

**Option 1 (recommended): put the corporate root certificate in Git.** A CA certificate is
public, so it is safe to commit. Get it as a PEM file (`corporate-root.pem`) in one of these
ways:

```bash
# From an internal website signed by the corporate CA: keep the last certificate of the chain
openssl s_client -connect <internal-site>:443 -showcerts </dev/null 2>/dev/null \
  | awk '/BEGIN CERT/{c=""} {c=c $0 "\n"} /END CERT/{last=c} END{printf "%s", last}' > corporate-root.pem
# ... or ask the PKI team for "the root CA certificate in PEM format"
```

Check that it is the root: subject and issuer must be the same. If they differ, the website did
not send the root, so ask the PKI team.

```bash
openssl x509 -in corporate-root.pem -noout -subject -issuer
```

Then replace `ca.yaml` with a ConfigMap that contains it, commit and merge:

```bash
oc create configmap openbao-ca -n openbao --from-file=ca-bundle.crt=corporate-root.pem \
  --dry-run=client -o yaml > cluster/applications/openbao/templates/ca.yaml
```

**Option 2: let OpenShift issue the certificate instead (service CA).** OpenShift has a built-in
CA for traffic inside the cluster. It needs no corporate CA, and it rotates certificates by
itself. The downside is that it only covers names inside the cluster: browsers and other
clusters do not trust it, so the Route must change from `passthrough` to `reencrypt`. This works
fine for the hub alone. When other clusters fetch secrets from this OpenBao later, you need the
corporate CA anyway. Use it only if option 1 is not possible today.

---

## Step 4: Unlock OpenBao (first time)

`init` creates **5 keys**. Any **3** of them unlock OpenBao. It also creates a **root token**
(the admin password). Everything goes into a file that only you can read.

```bash
umask 077
oc -n openbao exec openbao-0 -- bao operator init -format=json > ~/openbao-init.json

for pod in openbao-0 openbao-1 openbao-2; do
  for i in 0 1 2; do
    jq -j ".unseal_keys_b64[$i]" ~/openbao-init.json \
      | oc -n openbao exec -i $pod -- bao write -format=json sys/unseal key=- | jq -c '{sealed: .data.sealed}'
  done
done
```

**Check:** the last line for each pod says `{"sealed":false}`.

Then move the 5 keys and the root token from `~/openbao-init.json` into your password manager
(or to 5 different people). Never put them in Git, a ticket or a chat.

---

## Step 5: Let ESO log in to OpenBao

This turns on secret storage, and allows ESO to read secrets (but never write them).

```bash
{ jq -r .root_token ~/openbao-init.json; cat <<'SCRIPT'
bao secrets enable -path=secret -version=2 kv
bao auth enable kubernetes
bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc
echo 'path "secret/data/*" { capabilities = ["read"] }' | bao policy write eso -
bao write auth/kubernetes/role/eso \
  bound_service_account_names=eso-auth \
  bound_service_account_namespaces=openbao \
  token_policies=eso
bao audit enable file file_path=stdout
SCRIPT
} | oc -n openbao exec -i openbao-0 -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; sh -s'
```

**Check:**

```bash
oc get clustersecretstore openbao
```

`STATUS Valid`, `READY True`. If it says something else, wait a minute and check again.

---

## Step 6: Give an application a secret

Two things: put the value in OpenBao, and add an `ExternalSecret` next to the application in Git.

**1. Put the value in OpenBao.** Open `https://openbao.$APPS_DOMAIN`, log in with the root token,
choose **secret → Create secret**, and enter:

- Path: `myapp/db`
- Keys and values, for example `username` = `myapp` and `password` = `...`

**2. Add this file to the application's folder in Git** (change `myapp` and `db-credentials`):

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: myapp
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: db-credentials      # the Secret your application uses
  dataFrom:
    - extract:
        key: myapp/db         # every key in OpenBao becomes a key in the Secret
```

Commit and merge.

**Check:**

```bash
oc -n myapp get externalsecret db-credentials     # STATUS SecretSynced
oc -n myapp get secret db-credentials
```

To change the password later, change it in OpenBao. The Secret is updated within
`refreshInterval`.

---

## Step 7: Move a secret that already exists

For applications that already run with a Secret that was created by hand.

> **Important:** ESO replaces the *whole* Secret. Copy **all** keys to OpenBao first, or the
> missing ones disappear.

**1. Copy the existing Secret into OpenBao** (change the three values):

```bash
NS=myapp; SECRET=db-credentials; BAO_PATH=myapp/db

{ jq -r .root_token ~/openbao-init.json
  oc -n $NS get secret $SECRET -o json | jq -c '.data | map_values(@base64d)'
} | oc -n openbao exec -i openbao-0 -- sh -c \
  "read -r BAO_TOKEN; export BAO_TOKEN; bao kv put -mount=secret $BAO_PATH -"
```

**2. Add the `ExternalSecret` from step 6** with `target.name` = the existing Secret's name and
`key` = the same `BAO_PATH`. Commit and merge.

**3. Restart the application** so it is sure to use the Secret:

```bash
oc -n $NS rollout restart deployment/<APP>
```

**Check:** the same keys as before, and ESO owns the Secret now:

```bash
oc -n $NS get secret $SECRET -o json | jq -c '{keys: (.data | keys), owner: .metadata.ownerReferences[0].kind}'
```

`owner` should be `ExternalSecret`.

> If the Secret came from a Helm chart or from Git, first stop that source from creating it
> (most charts have an `existingSecret` setting). Otherwise it and ESO overwrite each other.

---

## If something does not work

| What you see | What to do |
|---|---|
| `ClusterSecretStore` not `Valid` | Check that step 2's network rule exists: `oc -n external-secrets get networkpolicy` should list `eso-user-allow-openbao` |
| `x509: certificate signed by unknown authority` | See "If the cluster does not trust the corporate CA" in step 3 |
| `ExternalSecret` says `Secret does not exist` | The path in OpenBao does not match `key:` in the `ExternalSecret` |
| You fixed the problem but the error stays | `oc -n <ns> annotate externalsecret <name> force-sync=$(date +%s) --overwrite` |
| OpenBao pods restarted and nothing works | They are sealed again: run the unseal loop from step 4 |

## Before real production use

- Unlock with keys held by different people, and remove `~/openbao-init.json`.
- Create personal admin logins and revoke the root token (`bao token revoke -self`).
- Take backups: `bao operator raft snapshot save`.

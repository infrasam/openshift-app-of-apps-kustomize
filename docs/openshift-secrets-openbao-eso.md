# Secrets on OpenShift with OpenBao and External Secrets

When you are done:

- **OpenBao** stores your secrets (it is the open-source version of Vault). It sets itself up
  and unlocks itself from Git: no scripts, no manual configuration, no root token lying around.
- **External Secrets Operator (ESO)** copies secrets from OpenBao into normal Kubernetes Secrets.
- Git only contains *where* a secret is, never the value.

Run every command from the root of the Git repository. Each step ends with a **Check**. Do not
start the next step until the check passes.

---

## How the pieces fit together

Each part is its own Argo CD Application: one small file in Git that points at a folder or a
Helm chart. The **sync wave** decides the order. Argo CD only starts a wave when everything in
the waves before it is healthy, so each part comes after what it depends on.

| Wave | Application file | Points at | Why this order |
|---|---|---|---|
| -1 | `cluster/base/external-secrets.yaml` | `applications/external-secrets-operator/` | ESO must exist before anything uses it |
| 0 | `cluster/overlays/<hub>/openbao-config.yaml` | `applications/openbao-config/` | What OpenBao **needs** before it starts: namespace, certificate, CA bundle |
| 1 | `cluster/overlays/<hub>/openbao.yaml` | The OpenBao Helm chart, settings written in the file | OpenBao itself |
| 2 | `cluster/overlays/<hub>/secret-store.yaml` | `applications/secret-store/` | What **uses** OpenBao: the ESO connection. It can only become healthy once OpenBao runs. |

ESO goes in `cluster/base/` because every cluster needs it. OpenBao goes in the hub's overlay,
because there is one secret store for the whole fleet.

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

## Step 3: What OpenBao needs before it starts (wave 0)

Four small files, one per thing:

| File | What | Why |
|---|---|---|
| `namespace.yaml` | The namespace `openbao` | Created first, so the certificate and the unseal key (step 4) can exist before OpenBao starts |
| `certificate.yaml` | OpenBao's TLS certificate from your corporate CA | Everything talks HTTPS to OpenBao |
| `ca.yaml` | A ConfigMap that OpenShift fills with the CAs the cluster trusts | So the OpenBao pods and ESO trust OpenBao's certificate |
| `serviceaccount-admin.yaml` | The identity administrators log in with | Instead of a root token (step 6) |

```bash
mkdir -p cluster/applications/openbao-config

cat > cluster/applications/openbao-config/namespace.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openbao
EOF

cat > cluster/applications/openbao-config/certificate.yaml <<EOF
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
  privateKey:
    algorithm: RSA
    size: 2048
  issuerRef:
    group: $ISSUER_GROUP
    kind: $ISSUER_KIND
    name: $ISSUER
EOF

cat > cluster/applications/openbao-config/ca.yaml <<'EOF'
# OpenShift fills this ConfigMap with the CAs the cluster trusts
apiVersion: v1
kind: ConfigMap
metadata:
  name: openbao-ca
  namespace: openbao
  labels:
    config.openshift.io/inject-trusted-cabundle: "true"
EOF

cat > cluster/applications/openbao-config/serviceaccount-admin.yaml <<'EOF'
# Administrators log in to OpenBao with a short-lived token for this ServiceAccount.
# Who may create that token is decided by OpenShift RBAC.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: openbao-admin
  namespace: openbao
EOF

cat > cluster/applications/openbao-config/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - certificate.yaml
  - ca.yaml
  - serviceaccount-admin.yaml
EOF

cat > cluster/overlays/$HUB/openbao-config.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openbao-config
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: $GIT_REPO
    targetRevision: main
    path: cluster/applications/openbao-config
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
EOF
```

Add `- openbao-config.yaml` to the list in `cluster/overlays/$HUB/kustomization.yaml`. Commit,
open a pull request and merge it.

**Check:**

```bash
oc -n openbao get certificate openbao-tls        # READY True
oc -n openbao get configmap openbao-ca -o jsonpath='{.data.ca-bundle\.crt}' | grep -c 'BEGIN CERTIFICATE'   # more than 0
```

> **ADCS and certificate names.** Some ADCS templates refuse wildcard names (`*.openbao-internal`).
> If the certificate never becomes ready, replace that line with the three pod names:
> `openbao-0.openbao-internal`, `openbao-1.openbao-internal`, `openbao-2.openbao-internal`.

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
  --dry-run=client -o yaml > cluster/applications/openbao-config/ca.yaml
```

**Option 2: let OpenShift issue the certificate instead (service CA).** OpenShift has a built-in
CA for traffic inside the cluster. It needs no corporate CA, and it rotates certificates by
itself. The downside is that it only covers names inside the cluster: browsers and other
clusters do not trust it, so the Route must change from `passthrough` to `reencrypt`. This works
fine for the hub alone. When other clusters fetch secrets from this OpenBao later, you need the
corporate CA anyway. Use it only if option 1 is not possible today.

---

## Step 4: Create the unseal key (once, by hand)

**What:** a random 32-byte key in a Secret.

**Why:** OpenBao encrypts everything it stores. This key lets it unlock itself every time it
starts, so nobody has to type unseal keys after a restart. It is the one thing you create by
hand, because key material never goes into Git.

```bash
umask 077
openssl rand -out ~/openbao-unseal.key 32
oc -n openbao create secret generic openbao-unseal-key --from-file=unseal.key=$HOME/openbao-unseal.key
```

Store `~/openbao-unseal.key` in your password manager (or your organisation's key safe), then
delete the local file. **Without this key, OpenBao's data cannot be read again** if the Secret is
lost.

**Check:**

```bash
oc -n openbao get secret openbao-unseal-key      # DATA 1
```

---

## Step 5: Install OpenBao (wave 1)

**What:** the official OpenBao Helm chart from your internal Helm repo. All its settings are
written directly in the Application file, under `helm.valuesObject`.

**Why it needs no script:** the OpenBao configuration contains `initialize` blocks. On its very
first start, OpenBao carries them out by itself: it turns on secret storage, lets ESO log in, and
creates the admin role. The temporary root token it uses for that is revoked straight away.

> The `initialize` blocks run **once**, on the first start of an empty OpenBao. Changing them
> later has no effect on a running OpenBao. Later changes (for example a new policy) are made by
> an administrator (step 6).

```bash
cat > cluster/overlays/$HUB/openbao.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openbao
  namespace: openshift-gitops
  annotations:
    # After openbao-config (0): the namespace, certificate and CA bundle must exist
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: $CHART_REPO
    chart: openbao
    targetRevision: 0.30.0
    helm:
      releaseName: openbao
      valuesObject:
        global:
          openshift: true
          tlsDisable: false

        # Secrets reach applications through ESO, not through sidecars
        injector:
          enabled: false

        server:
          image:
            registry: $REGISTRY
            repository: openbao/openbao
            tag: "2.7.0"

          # OpenShift Route, TLS passthrough: OpenBao shows its own certificate
          route:
            enabled: true
            host: openbao.$APPS_DOMAIN
            tls:
              termination: passthrough

          # "Ready" also while starting or sealed, so Argo CD never waits on OpenBao's state
          readinessProbe:
            path: /v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204

          volumes:
            - name: tls
              secret:
                secretName: openbao-tls
            - name: ca
              configMap:
                name: openbao-ca
            - name: unseal-key
              secret:
                secretName: openbao-unseal-key
          volumeMounts:
            - name: tls
              mountPath: /openbao/tls
            - name: ca
              mountPath: /openbao/ca
            - name: unseal-key
              mountPath: /openbao/unseal
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

                # Unlock automatically with the key from step 4
                seal "static" {
                  current_key_id = "key-1"
                  current_key    = "file:///openbao/unseal/unseal.key"
                }

                # Every request is logged to the pods' output (collected by OpenShift logging)
                audit "file" "stdout" {
                  options {
                    file_path = "stdout"
                  }
                }

                # First start only: secret storage at secret/ (key/value, version 2)
                initialize "secrets" {
                  request "kv" {
                    operation = "update"
                    path      = "sys/mounts/secret"
                    data = {
                      type    = "kv"
                      options = { version = "2" }
                    }
                  }
                }

                # First start only: OpenShift ServiceAccounts may log in
                initialize "auth" {
                  request "enable-kubernetes" {
                    operation = "update"
                    path      = "sys/auth/kubernetes"
                    data      = { type = "kubernetes" }
                  }
                  request "config-kubernetes" {
                    operation = "update"
                    path      = "auth/kubernetes/config"
                    data      = { kubernetes_host = "https://kubernetes.default.svc" }
                  }
                }

                # First start only: what ESO and administrators may do
                initialize "policies" {
                  request "eso" {
                    operation = "update"
                    path      = "sys/policies/acl/eso"
                    data = {
                      policy = <<-EOT
                        path "secret/data/*"     { capabilities = ["read"] }
                        path "secret/metadata/*" { capabilities = ["read", "list"] }
                      EOT
                    }
                  }
                  request "admin" {
                    operation = "update"
                    path      = "sys/policies/acl/admin"
                    data = {
                      policy = <<-EOT
                        path "*" { capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"] }
                      EOT
                    }
                  }
                }

                # First start only: who gets which policy
                initialize "roles" {
                  request "eso" {
                    operation = "update"
                    path      = "auth/kubernetes/role/eso"
                    data = {
                      bound_service_account_names      = ["eso-auth"]
                      bound_service_account_namespaces = ["openbao"]
                      token_policies                   = ["eso"]
                      token_ttl                        = "1h"
                    }
                  }
                  request "admin" {
                    operation = "update"
                    path      = "auth/kubernetes/role/admin"
                    data = {
                      bound_service_account_names      = ["openbao-admin"]
                      bound_service_account_namespaces = ["openbao"]
                      token_policies                   = ["admin"]
                      token_ttl                        = "1h"
                    }
                  }
                }

        ui:
          enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: openbao
  syncPolicy:
    automated:
      # Never prune anything of the secret store automatically
      prune: false
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
EOF
```

Add `- openbao.yaml` to `cluster/overlays/$HUB/kustomization.yaml`. Commit, open a pull request
and merge it.

If your Helm repo needs a login, Argo CD must know it: in the Argo CD UI go to
**Settings → Repositories → Connect Repo**, choose type **Helm**, and enter `$CHART_REPO` with a
read-only user.

**Check** (a few minutes after the merge):

```bash
oc -n openbao get pods
for pod in openbao-0 openbao-1 openbao-2; do
  oc -n openbao exec $pod -- bao status -format=json | jq -c --arg pod $pod '{pod: $pod, initialized, sealed}'
done
```

Three pods `Running`, and every line says `"initialized":true,"sealed":false`. Nobody unlocked
anything: OpenBao did it with the key from step 4.

---

## Step 6: Connect ESO to OpenBao (wave 2)

**What:** the ServiceAccount that ESO logs in with, and the `ClusterSecretStore` that tells ESO
where OpenBao is.

**Why a separate wave:** the store can only become healthy once OpenBao runs. In an earlier wave
it would block everything after it.

```bash
mkdir -p cluster/applications/secret-store

cat > cluster/applications/secret-store/serviceaccount.yaml <<'EOF'
# ESO logs in to OpenBao with a token for this ServiceAccount (role "eso" in openbao.yaml)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-auth
  namespace: openbao
EOF

cat > cluster/applications/secret-store/clustersecretstore.yaml <<'EOF'
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao
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

cat > cluster/applications/secret-store/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - serviceaccount.yaml
  - clustersecretstore.yaml
EOF

cat > cluster/overlays/$HUB/secret-store.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: secret-store
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    repoURL: $GIT_REPO
    targetRevision: main
    path: cluster/applications/secret-store
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
EOF
```

Add `- secret-store.yaml` to `cluster/overlays/$HUB/kustomization.yaml`. Commit, open a pull
request and merge it.

**Check:**

```bash
oc get clustersecretstore openbao
```

`STATUS Valid`, `READY True`. If it says something else, wait a minute and check again.

---

## Step 7: Log in as administrator

There is no root token and no password. You log in with a short-lived token for the
ServiceAccount `openbao-admin`. Only people with the right to create tokens in the `openbao`
namespace (cluster administrators) can do this.

```bash
oc -n openbao create token openbao-admin | jq -Rc '{role: "admin", jwt: .}' \
  | curl -s -X POST --data @- https://openbao.$APPS_DOMAIN/v1/auth/kubernetes/login \
  | jq -r .auth.client_token
```

Open `https://openbao.$APPS_DOMAIN`, choose the method **Token**, and paste it. The token is valid
for one hour.

---

## Step 8: Give an application a secret

Two things: put the value in OpenBao, and add an `ExternalSecret` next to the application in Git.

**1. Put the value in OpenBao.** Log in (step 7), choose **secret → Create secret**, and enter:

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

## Step 9: Move a secret that already exists

For applications that already run with a Secret that was created by hand.

> **Important:** ESO replaces the *whole* Secret. Copy **all** keys to OpenBao first, or the
> missing ones disappear.

**1. Copy the existing Secret into OpenBao** (change the three values):

```bash
NS=myapp; SECRET=db-credentials; BAO_PATH=myapp/db

TOKEN=$(oc -n openbao create token openbao-admin | jq -Rc '{role: "admin", jwt: .}' \
  | curl -s -X POST --data @- https://openbao.$APPS_DOMAIN/v1/auth/kubernetes/login | jq -r .auth.client_token)

{ printf '%s\n' "$TOKEN"
  oc -n $NS get secret $SECRET -o json | jq -c '.data | map_values(@base64d)'
} | oc -n openbao exec -i openbao-0 -- sh -c \
  "read -r BAO_TOKEN; export BAO_TOKEN; bao kv put -mount=secret $BAO_PATH -"
unset TOKEN
```

**2. Add the `ExternalSecret` from step 8** with `target.name` = the existing Secret's name and
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
| `openbao` stays `Progressing`, pods in `ContainerCreating` | A volume is missing: `oc -n openbao describe pod openbao-0`. Usually the certificate (step 3) is not ready, or the unseal key Secret (step 4) does not exist. |
| A pod says `sealed: true` | It cannot read the unseal key: check the Secret from step 4 and the pod's log |
| Pod log: `failed to initialize` | An `initialize` block was rejected. The log names the block. Fix it, then start over with an empty OpenBao (delete the pods **and** their PVCs). |
| `openbao-1` or `openbao-2` does not join | TLS name or CA problem: the certificate must cover `*.openbao-internal` (or the pod names), and `openbao-ca` must contain the CA that signed it |
| `ClusterSecretStore` not `Valid` | Check that step 2's network rule exists: `oc -n external-secrets get networkpolicy` should list `eso-user-allow-openbao` |
| `x509: certificate signed by unknown authority` | See "If the cluster does not trust the corporate CA" in step 3 |
| `ExternalSecret` says `Secret does not exist` | The path in OpenBao does not match `key:` in the `ExternalSecret` |
| You fixed the problem but the error stays | `oc -n <ns> annotate externalsecret <name> force-sync=$(date +%s) --overwrite` |

## Before real production use

- **Protect the unseal key better.** A static key in a Secret is simple, but anyone who can read
  that Secret can unlock OpenBao. Replace `seal "static"` with an HSM (`seal "pkcs11"`) or another
  Vault (`seal "transit"`) when you can.
- **Personal logins.** Replace the shared `openbao-admin` login with OIDC against your identity
  provider, so every action in the audit log has a name.
- **Backups.** Take regular Raft snapshots (`bao operator raft snapshot save`) and test a restore.

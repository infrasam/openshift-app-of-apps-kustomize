# Certificates on OpenShift with cert-manager and Active Directory Certificate Services

When you are done, any application on the cluster can get a TLS certificate signed by your own
company CA (Active Directory Certificate Services, ADCS) just by adding a small `Certificate` file
to Git. Certificates are renewed automatically before they expire, and nobody has to request
them by hand.

This guide is written for a **disconnected cluster**: a new OpenShift cluster created by RHACM,
in its own network and vCenter, with **no internet access**. Everything it needs comes from
internal services: the mirror registry, the internal Helm repository, the internal Git server and
ADCS.

Run every command from the root of the Git repository, logged in (`oc login`) to the **new
cluster** unless a step says otherwise. Each step explains **what** you do and **why**, and ends
with a **Check**. Do not start the next step until the check passes.

---

## How it works

There are four parts involved:

| Part | What it does |
|---|---|
| **cert-manager** | Watches `Certificate` objects. Creates a private key and a certificate request for each, and renews the certificate before it expires. |
| **ADCS issuer** | A plug-in for cert-manager. It sends the certificate request to ADCS and brings the signed certificate back. |
| **ADCS Web Enrollment** | The ADCS web page (`https://<server>/certsrv`) that the ADCS issuer talks to. |
| **Certificate template** | A setting in ADCS that decides what kind of certificate you get: how long it is valid, what it may be used for. |

What happens when you ask for a certificate:

```mermaid
flowchart LR
    cert[Certificate<br/>in Git] --> cm[cert-manager]
    cm -->|creates key + request| req[CertificateRequest]
    req --> adcs[ADCS issuer]
    adcs -->|HTTPS + NTLM login| ws[ADCS Web Enrollment]
    ws -->|signed certificate| adcs
    adcs --> secret[Secret with<br/>tls.crt + tls.key]
    secret --> app[Application]
```

The private key is created inside the cluster and never leaves it. ADCS only sees the request.

### How the files fit together

Each part is its own Argo CD Application: one small file in `cluster/base/` (every cluster gets
it) that points at a folder or a Helm chart. The **sync wave** decides the order. Argo CD only
starts a wave when everything in the waves before it is healthy.

| Wave | Application file | Points at | Step |
|---|---|---|---|
| -3 | `cluster/base/cert-manager.yaml` | `applications/cert-manager/` (the operator) | 3 |
| -2 | `cluster/base/adcs-issuer.yaml` | The ADCS issuer Helm chart, settings written in the file | 4 |
| -2 | `cluster/base/cluster-trust.yaml` | `applications/cluster-trust/` (trust the company CA) | 9 |
| -1 | `cluster/base/adcs-issuer-config.yaml` | `applications/adcs-issuer-config/` (the connection to ADCS) | 6 |

### How the files reach the new cluster

These files are applied by **the Argo CD that manages the new cluster**. That is either the
cluster's own OpenShift GitOps (it reads Git itself) or the hub's Argo CD (it pushes to the
cluster's API). It decides which network openings you need, in the table below.

---

## Before you start

### From the Active Directory team

Ask the team that runs ADCS for these five things. You cannot finish the guide without them.

| # | What | Why |
|---|---|---|
| 1 | The **Web Enrollment URL**, for example `https://adcs.example.internal/certsrv`. | This is where the ADCS issuer sends requests. |
| 2 | A **certificate template** for server certificates. It must allow *Server Authentication*, and the subject and names must be *supplied in the request*. | The template controls what you are allowed to get. Without "supplied in the request", ADCS ignores the names you ask for. |
| 3 | A **service account** in Active Directory with *Read* and *Enroll* rights on that template, and NTLM allowed on the Web Enrollment site. | The ADCS issuer logs in as this account. |
| 4 | The **CA certificates** (root and issuing CA) as PEM files. | So the cluster can trust ADCS's web site and the certificates it signs. A CA certificate is public, so it is safe to keep in Git. |
| 5 | Whether the template needs a **manager approval** in ADCS. | If yes, every request waits until someone approves it in ADCS. Ask for a template without manual approval. |

### From whoever runs the mirror

A disconnected cluster can only use what has been copied (mirrored) into your internal services:

| What | Where | Why |
|---|---|---|
| The operator `openshift-cert-manager-operator` | The mirrored operator catalog (`oc-mirror`), including its images | OLM installs the operator from the catalog |
| The image `docker.io/djkormo/adcs-issuer:2.2.2` | The internal registry, as `<registry>/djkormo/adcs-issuer:2.2.2` | The ADCS issuer pod runs it |
| The Helm chart `adcs-issuer` 2.2.2 (from `https://djkormo.github.io/adcs-issuer/`) | The internal Helm repository | Argo CD installs the ADCS issuer from it |

### From the network team

The new cluster lives in its own network. These connections must be open (firewall) and the names
must resolve (DNS) **from the new cluster's machine network**:

| From | To | Port | Why |
|---|---|---|---|
| Cluster nodes | Mirror registry | 443 | Pull the operator and ADCS issuer images |
| Cluster nodes | ADCS Web Enrollment server | 443 | Request certificates |
| Cluster nodes | DNS server that knows the ADCS and registry names | 53 | Find them by name |
| Cluster nodes | NTP server | 123 (UDP) | Correct time. Wrong time breaks NTLM logins and makes certificates look "not yet valid" or expired. |
| The managing Argo CD | Internal Git server and Helm repository | 443 | If the cluster's own Argo CD reads Git |
| The hub | The new cluster's API | 6443 | Only if the hub's Argo CD pushes to the cluster |

---

## Step 1: Fill in your values

Change the values to match your environment, then paste the block into your terminal. Every later
step uses these variables.

```bash
export REGISTRY=registry.example.internal                           # mirror registry
export CHART_REPO=https://charts.example.internal/repository/helm   # internal Helm repo
export GIT_REPO=https://git.example.internal/platform/fleet.git
export ADCS_URL=https://adcs.example.internal/certsrv               # Active Directory team, item 1
export ADCS_TEMPLATE=OpenShiftWebServer                             # Active Directory team, item 2
export CA_CHAIN=corporate-ca-chain.pem                              # item 4: root + issuing CA in one file
export CATALOG=cs-redhat-operator-index                             # the mirrored catalog, see Check 2
```

**Check 1:** the CA file contains certificates and nothing else:

```bash
grep -c 'BEGIN CERTIFICATE' $CA_CHAIN     # 2 or more
grep -c 'PRIVATE KEY' $CA_CHAIN           # must be 0
```

**Check 2:** the cluster uses the mirrored catalog, and the operator is in it:

```bash
oc get catalogsource -n openshift-marketplace          # the mirrored catalog: put its NAME in $CATALOG
oc get packagemanifest openshift-cert-manager-operator -n openshift-marketplace \
  -o jsonpath='catalog: {.status.catalogSource}{"\n"}channel: {.status.defaultChannel}{"\n"}'
```

The second command prints your mirrored catalog and a channel, for example `stable-v1`. If it says
`not found`, the operator is not mirrored: ask whoever runs the mirror.

**Check 3:** the cluster knows where the mirrored operator images are:

```bash
oc get imagedigestmirrorset -o yaml | grep -c 'registry.redhat.io'        # more than 0
oc get imagecontentsourcepolicy -o yaml | grep -c 'registry.redhat.io'    # older clusters use this instead
```

`oc-mirror` creates these mappings. Without them, OLM tries to pull from `registry.redhat.io` on
the internet and the installation hangs.

---

## Step 2: Test the network from inside the cluster

**What:** check, from one of the cluster's own nodes, that ADCS can be reached and the login works.

**Why:** the cluster is in a different network than your workstation. A test from your
workstation proves nothing about what the cluster can reach.

```bash
NODE=$(oc get nodes -l node-role.kubernetes.io/worker -o name | head -1)
oc debug $NODE
```

You now have a shell on the node. Run these inside it (`chroot /host` gives you the node's own
tools), then `exit` twice:

```bash
chroot /host
getent hosts adcs.example.internal                        # DNS: prints an IP address
chronyc tracking | grep -E 'Reference|System time'        # time: a reference server, small offset
curl --ntlm -u 'EXAMPLE\svc-ocp-certs' -k -s -o /dev/null -w '%{http_code}\n' https://adcs.example.internal/certsrv/
```

| Result | Meaning |
|---|---|
| `200` | Network, DNS and login work. |
| `401` | The network works, but the username, password or NTLM setting is wrong. |
| `000` or a timeout | The firewall blocks the cluster from ADCS. Ask the network team. |
| `getent` prints nothing | DNS on the cluster cannot resolve the ADCS name. |

(`-k` skips the certificate check in this test only. The real setup checks it with `$CA_CHAIN`.)

---

## Step 3: Install cert-manager

**What:** Red Hat's cert-manager operator, installed through Git from the **mirrored** catalog.

**Why:** cert-manager does all the work around certificates: keys, requests, renewal. It runs on
every cluster, so its Application goes in `cluster/base/`.

**Why its own namespace?** On OpenShift you can put operators in the shared namespace
`openshift-operators`, or give each operator its own. This guide uses the operator's own
namespace, `cert-manager-operator`, because:

- it is the namespace the operator itself recommends,
- with `installPlanApproval: Manual`, an approval covers all operators in the same namespace at
  once. With one namespace per operator, you upgrade one operator at a time,
- removing or troubleshooting one operator does not touch the others.

```bash
mkdir -p cluster/applications/cert-manager

cat > cluster/applications/cert-manager/operator.yaml <<EOF
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
  # The mirrored catalog (Step 1, Check 2), not redhat-operators: there is no internet
  source: $CATALOG
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
EOF

cat > cluster/applications/cert-manager/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - operator.yaml
EOF

cat > cluster/base/cert-manager.yaml <<EOF
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
    repoURL: $GIT_REPO
    targetRevision: main
    path: cluster/applications/cert-manager
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
EOF
```

Add `- cert-manager.yaml` to the list in `cluster/base/kustomization.yaml`. Commit, open a pull
request and merge it.

The installation waits for your approval, because of `installPlanApproval: Manual`. That way
nothing is upgraded without you deciding it:

```bash
oc -n cert-manager-operator get installplan
oc -n cert-manager-operator patch installplan <NAME> --type merge -p '{"spec":{"approved":true}}'
```

**Check:**

```bash
oc -n cert-manager-operator get csv          # PHASE Succeeded
oc -n cert-manager get pods                  # cert-manager, cert-manager-cainjector, cert-manager-webhook: Running
```

If a pod stays in `ImagePullBackOff`, the image mappings from Step 1, Check 3 are missing.

---

## Step 4: Install the ADCS issuer

**What:** the plug-in that connects cert-manager to ADCS, installed from its Helm chart in your
internal Helm repo, with its image from the mirror registry.

**How:** one Application file. It points at the chart, and all settings are written directly in
the file under `helm.valuesObject`. The image is pulled straight from the mirror registry by its
full name, so it does not depend on image mappings.

```bash
cat > cluster/base/adcs-issuer.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: adcs-issuer
  namespace: openshift-gitops
  annotations:
    # After cert-manager (-3)
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  source:
    repoURL: $CHART_REPO
    chart: adcs-issuer
    targetRevision: 2.2.2
    helm:
      releaseName: adcs-issuer
      valuesObject:
        # Creates the security context constraint (SCC) the plug-in needs on OpenShift
        openshift:
          enabled: true
        controllerManager:
          manager:
            image:
              # Full name in the mirror registry: no internet needed
              repository: $REGISTRY/djkormo/adcs-issuer
              tag: 2.2.2
              imagePullPolicy: IfNotPresent
        metricsService:
          serviceMonitor:
            enabled: false
  destination:
    server: https://kubernetes.default.svc
    namespace: adcs-issuer
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
EOF
```

Add `- adcs-issuer.yaml` to the list in `cluster/base/kustomization.yaml`.

**Check** before you commit (only your registry may appear):

```bash
yq '.spec.source.helm.valuesObject' cluster/base/adcs-issuer.yaml > /tmp/adcs-values.yaml
helm template adcs-issuer adcs-issuer --repo $CHART_REPO --version 2.2.2 -n adcs-issuer \
  -f /tmp/adcs-values.yaml | grep 'image:' | sort -u
```

Commit, open a pull request and merge it. If your Helm repo needs a login, add it once in the
Argo CD UI: **Settings → Repositories → Connect Repo**, type **Helm**.

**Check** after the merge:

```bash
oc -n adcs-issuer get pods                  # one pod adcs-issuer-... Running
oc get crd | grep adcs.certmanager           # adcsissuers, adcsrequests, clusteradcsissuers
```

If the pod stays in `ImagePullBackOff`: the image is not in the mirror registry, or the cluster's
pull secret has no login for it (`oc get secret pull-secret -n openshift-config`).

---

## Step 5: Give the ADCS issuer its login

**What:** a Secret with the service account's username and password.

**Why by hand:** a password never goes into Git. The Secret must be in the `adcs-issuer` namespace,
because that is where the plug-in looks for it. (When a secret store such as OpenBao is in place,
this Secret can come from there instead, under the same name.)

```bash
read -rsp 'Password for the ADCS service account: ' PW; echo
oc -n adcs-issuer create secret generic adcs-issuer-credentials \
  --from-literal=username='EXAMPLE\svc-ocp-certs' \
  --from-literal=password="$PW"
unset PW
```

Use the same username format that worked in Step 2 (`DOMAIN\user`).

**Check:**

```bash
oc -n adcs-issuer get secret adcs-issuer-credentials -o jsonpath='{.data}' | jq 'keys'
```

It shows `["password","username"]`.

---

## Step 6: Connect to ADCS

**What:** a `ClusterAdcsIssuer` named `adcs`. It tells the plug-in where ADCS is, which template
to use and which login to use. "Cluster" means every namespace on the cluster can use it.

**Why `caBundle`:** the plug-in talks HTTPS to the Web Enrollment site and must trust its
certificate. `caBundle` is the CA chain from Step 1, base64-encoded.

**How:** a plain YAML file in its own folder, and an Application that points at it. It comes in
the wave after the plug-in (Step 4), because the plug-in installs the `ClusterAdcsIssuer` type.

```bash
mkdir -p cluster/applications/adcs-issuer-config

cat > cluster/applications/adcs-issuer-config/clusteradcsissuer.yaml <<EOF
apiVersion: adcs.certmanager.csf.nokia.com/v1
kind: ClusterAdcsIssuer
metadata:
  name: adcs
spec:
  url: $ADCS_URL
  templateName: $ADCS_TEMPLATE
  credentialsRef:
    name: adcs-issuer-credentials
  caBundle: $(base64 -w0 $CA_CHAIN)
  statusCheckInterval: 5m
  retryInterval: 5m
EOF

cat > cluster/applications/adcs-issuer-config/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - clusteradcsissuer.yaml
EOF

cat > cluster/base/adcs-issuer-config.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: adcs-issuer-config
  namespace: openshift-gitops
  annotations:
    # After adcs-issuer (-2), which installs the ClusterAdcsIssuer type
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  source:
    repoURL: $GIT_REPO
    targetRevision: main
    path: cluster/applications/adcs-issuer-config
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
EOF
```

Add `- adcs-issuer-config.yaml` to the list in `cluster/base/kustomization.yaml`. Commit, open a
pull request and merge it.

**Check:**

```bash
oc get clusteradcsissuer adcs
oc -n adcs-issuer logs deploy/adcs-issuer --tail=20 | grep -i error
```

The issuer exists, and the log shows no errors. The issuer has no "ready" status of its own: it
only talks to ADCS when a certificate is requested, so the real test is Step 7.

---

## Step 7: Test with a certificate

**What:** ask for one real certificate in a test namespace, look at it, then remove it.

**Why:** this proves the whole chain (cert-manager → plug-in → ADCS → back) before any
application depends on it.

```bash
oc create namespace cert-test
oc apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test
  namespace: cert-test
spec:
  secretName: test-tls
  commonName: cert-test.example.internal
  dnsNames:
    - cert-test.example.internal
  privateKey:
    algorithm: RSA
    size: 2048
  issuerRef:
    group: adcs.certmanager.csf.nokia.com
    kind: ClusterAdcsIssuer
    name: adcs
EOF
```

**Check** (it can take a minute):

```bash
oc -n cert-test get certificate test         # READY True
oc -n cert-test get secret test-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

The issuer is your company CA, and the name `cert-test.example.internal` is in the list.

If `READY` stays `False`, follow the request step by step:

```bash
oc -n cert-test get certificaterequest       # APPROVED True? READY?
oc -n cert-test get adcsrequest              # STATE: pending, ready, errored or rejected
oc -n cert-test describe adcsrequest | tail -5
oc -n adcs-issuer logs deploy/adcs-issuer --tail=30
```

Clean up:

```bash
oc delete namespace cert-test
```

The test certificate stays valid in ADCS until it expires. Ask the ADCS team to revoke it if your
rules require that.

---

## Step 8: Use it in your applications

Every certificate is a small file next to the application in Git. Only `issuerRef` points to ADCS:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-tls
  namespace: myapp
spec:
  secretName: myapp-tls            # the Secret the application (or its Route) reads
  dnsNames:
    - myapp.apps.ocp-poc-01.example.internal
  privateKey:
    algorithm: RSA
    size: 2048
  issuerRef:
    group: adcs.certmanager.csf.nokia.com
    kind: ClusterAdcsIssuer
    name: adcs
```

Good to know:

- **Validity comes from the ADCS template**, not from `duration` in the file. cert-manager renews
  automatically when two thirds of the lifetime have passed.
- When another guide asks for an *issuer*, use these three values: group
  `adcs.certmanager.csf.nokia.com`, kind `ClusterAdcsIssuer`, name `adcs`.
- Use RSA keys unless you know the template accepts ECDSA.

---

## Step 9: Make the cluster trust the company CA

**What:** make sure the company CA is in the cluster's list of trusted CAs.

**Why:** the certificates are now signed by your company CA. Components inside the cluster (the
OAuth server, image pulls, and anything that reads the injected trust bundle, for example the
OpenBao guide) must trust that CA, or they fail with `x509: certificate signed by unknown authority`.

> **Easiest for new clusters:** add the company CA to `additionalTrustBundle` in the cluster's
> `install-config.yaml`, next to the mirror registry's CA, when RHACM creates the cluster. Then it
> is trusted from the first boot and this step is only a check.

**On a disconnected cluster this list already exists.** The installer created it with the mirror
registry's CA, so the cluster can pull images. Never replace it: **add** the company CA to it.

```bash
BUNDLE=$(oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}'); echo "$BUNDLE"   # usually user-ca-bundle
oc -n openshift-config get configmap $BUNDLE -o jsonpath='{.data.ca-bundle\.crt}' > current-bundle.pem
grep -c 'BEGIN CERTIFICATE' current-bundle.pem                                       # the CAs trusted today
```

Is the company CA already in it? Compare the subjects:

```bash
openssl crl2pkcs7 -nocrl -certfile current-bundle.pem | openssl pkcs7 -print_certs -noout | grep subject
openssl crl2pkcs7 -nocrl -certfile $CA_CHAIN          | openssl pkcs7 -print_certs -noout | grep subject
```

If every subject from `$CA_CHAIN` is already in the first list, you are done. Otherwise, put the
**combined** bundle in Git, under the **same name**, so it is managed from now on:

```bash
mkdir -p cluster/applications/cluster-trust

cat current-bundle.pem $CA_CHAIN > combined-bundle.pem
oc create configmap $BUNDLE -n openshift-config --from-file=ca-bundle.crt=combined-bundle.pem \
  --dry-run=client -o yaml > cluster/applications/cluster-trust/trusted-ca-bundle.yaml
rm current-bundle.pem combined-bundle.pem

cat > cluster/applications/cluster-trust/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - trusted-ca-bundle.yaml
EOF

cat > cluster/base/cluster-trust.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cluster-trust
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  source:
    repoURL: $GIT_REPO
    targetRevision: main
    path: cluster/applications/cluster-trust
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      # Never delete the trust bundle: without it the cluster cannot pull images
      prune: false
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
EOF
```

Check that the mirror registry's CA **and** the company CA are both in the new file before you
commit:

```bash
grep -c 'BEGIN CERTIFICATE' cluster/applications/cluster-trust/trusted-ca-bundle.yaml
```

Add `- cluster-trust.yaml` to `cluster/base/kustomization.yaml`. Commit, open a pull request and
merge it.

> A change to the trust bundle rolls through the nodes one by one, like a small upgrade. Do it in
> a maintenance window.

**Check** (after the nodes have updated, `oc get mcp` shows `UPDATED True`):

```bash
oc -n openshift-config get configmap $BUNDLE -o jsonpath='{.data.ca-bundle\.crt}' | grep -c 'BEGIN CERTIFICATE'
```

The number matches the file in Git, and images can still be pulled (`oc get pods -A | grep -c ImagePull`
shows 0).

---

## If something does not work

| What you see | What it means | What to do |
|---|---|---|
| Subscription shows no install plan, or `no operators found` | The catalog in `source:` does not have the operator | Step 1, Check 2: use the mirrored catalog's name, and ask for the operator to be mirrored |
| Operator or cert-manager pods in `ImagePullBackOff` | The cluster tries to pull from the internet | Step 1, Check 3: the `ImageDigestMirrorSet` from `oc-mirror` is missing |
| ADCS issuer pod in `ImagePullBackOff` | Image not in the mirror registry, or no login for it | Check the image name in Step 4 and the cluster's pull secret |
| Plug-in log: `i/o timeout` or `no route to host` | The firewall blocks the cluster from ADCS | Step 2 and the network table |
| Plug-in log: `no such host` | The cluster's DNS cannot resolve the ADCS name | Step 2 and the network table |
| `certificate is not yet valid`, or NTLM logins fail although the password is right | The cluster's clock is wrong | Step 2: check `chronyc tracking`. The cluster needs an internal NTP server. |
| No `AdcsRequest` is created at all | The plug-in is not running, or the `issuerRef` is wrong | `oc -n adcs-issuer get pods`, and check group, kind and name in `issuerRef` (Step 8) |
| `CertificateRequest` shows `APPROVED` empty | cert-manager has not approved it | The chart gives cert-manager the right to approve ADCS requests. Check that cert-manager runs in the namespace `cert-manager` with the service account `cert-manager`. |
| `AdcsRequest` stays `pending` | ADCS waits for a manager to approve the request, or the plug-in cannot reach ADCS | Read the plug-in log. If ADCS is waiting for approval, ask the ADCS team, or ask them to remove manual approval from the template. |
| `AdcsRequest` is `rejected` or `errored` | ADCS refused the request, or the call failed | Usually the template: it does not allow names in the request, the key size is too small, or the account lacks *Enroll*. The message is in `oc describe adcsrequest`. |
| `401` in the plug-in log | Wrong login | Fix the Secret from Step 5 (username format `DOMAIN\user`). |
| `x509: certificate signed by unknown authority` in the plug-in log | `caBundle` does not contain the CA of the ADCS web server | Ask the ADCS team which CA signed the Web Enrollment site, and add it to `$CA_CHAIN`. |
| Images stop pulling after Step 9 | The new trust bundle lost the mirror registry's CA | Put the registry CA back into `trusted-ca-bundle.yaml`, or revert the pull request |
| A certificate is valid for a shorter or longer time than you asked for | The template decides the validity | Expected. Change the template in ADCS if needed. |

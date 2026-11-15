<!--
=============================================================================
File        : README.md
Assignment  : DSO202 Assignment 4
Descriptor  : Unit IV 4.1-4.4 (GitOps with Argo CD)
Purpose     : What this repository is, the pinned versions, how to build the
              whole environment from an empty machine, cleanup, how
              credentials are handled, and the written answers Q1-Q6.
=============================================================================
-->
# dso202-gitops: GitOps Delivery of the Task Tracker with Argo CD

This repository is the **desired state** of the DSO202 Task Tracker (frontend,
backend API, PostgreSQL) in two environments, `dev` and `staging`. Nothing is
deployed by running `helm install` or `kubectl apply` against the workloads.
Argo CD runs inside the cluster, polls this repository every 60 s, and makes the
cluster match it.

| Environment | Namespace        | Follows                    | Sync                          | Frontend |
|-------------|------------------|----------------------------|-------------------------------|----------|
| dev         | `dso202-dev`     | branch `main`              | automated, prune + self-heal  | `http://localhost:30080` |
| staging     | `dso202-staging` | a tag (currently `v1.2.0`) | manual (approval gate)        | `kubectl port-forward -n dso202-staging svc/tasktracker-frontend 8081:8080` → `http://localhost:8081` |

Evidence for every task is in [`docs/evidence.md`](docs/evidence.md).

## Layout

```text
.gitignore                 keys and plaintext Secrets never enter Git (first commit)
cluster/kind-cluster.yaml  3-node kind cluster from Practical 1 (maps host port 30080)
bootstrap/argocd/          Argo CD v3.5.6 via Kustomize (+ argocd-cm and argocd-rbac-cm patches)  ← applied by hand
bootstrap/root/            'platform' AppProject + 'root' Application (app of apps)               ← applied by hand
argocd/projects/           'dso202' AppProject (wave -3)                                          ← delivered by root
argocd/applications/       sealed-secrets (-2), platform-dev/-staging (-1), tasktracker-dev/-staging (0)
platform/<env>/            Namespace, ResourceQuota, LimitRange, Role/RoleBinding, SealedSecret
charts/tasktracker/        Assignment 3 chart, adjusted to the chart contract C1-C11, + PostSync smoke test
environments/<env>/        values that differ per environment (and nothing else)
docs/evidence.md           command output for Tasks 1-10
```

## Pinned versions (section 3.1)

| Component | Version |
|---|---|
| Argo CD (server and `argocd` CLI) | v3.5.6 (`bootstrap/argocd/kustomization.yaml` pins the `v3.5.6` install manifest) |
| Sealed Secrets Helm chart | 2.20.0 (`argocd/applications/sealed-secrets.yaml`) |
| Sealed Secrets controller / `kubeseal` | 0.40.0 / v0.40.0 |
| kind / node image | v0.20.0 / `kindest/node:v1.36.1` (pinned by digest in `cluster/kind-cluster.yaml`) |
| kubectl / Helm | v1.36.3 / v4.3.1 |
| Application images | `sarojsanyasi/dso202-{frontend,backend,db}` tags `1.0` and `1.1` only |
| Smoke-test image | `busybox:1.37` |

`latest`, `stable`, `master` and `HEAD` are not used as a version anywhere.

## Build everything from an empty machine (as practised in Task 9)

Prerequisites: Docker, kind, kubectl, Helm, git, `argocd` v3.5.6, `kubeseal` v0.40.0,
and the sealing-key backup at `../dso202-keys/sealing-key.backup.yaml`.

```bash
git clone https://github.com/tadashi-dev-eng/dso202-gitops.git && cd dso202-gitops

# 1. Cluster
kind create cluster --name dso202-gitops --config cluster/kind-cluster.yaml

# 1a. Local workarounds on this laptop only (see "Deviations"):
#     CoreDNS -> public resolvers, and preload the arm64 application images.
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' \
  | sed 's#forward . /etc/resolv.conf#forward . 8.8.8.8 1.1.1.1#' \
  | kubectl -n kube-system create cm coredns --from-file=Corefile=/dev/stdin --dry-run=client -o yaml \
  | kubectl apply -f -
kubectl -n kube-system rollout restart deploy/coredns
for img in sarojsanyasi/dso202-frontend:1.0 sarojsanyasi/dso202-frontend:1.1 \
           sarojsanyasi/dso202-backend:1.0 sarojsanyasi/dso202-backend:1.1 \
           sarojsanyasi/dso202-db:1.0 busybox:1.37 bitnami/sealed-secrets-controller:0.40.0; do
  for node in dso202-gitops-control-plane dso202-gitops-worker dso202-gitops-worker2; do
    docker save "$img" | docker exec -i "$node" ctr -n k8s.io images import --all-platforms -
  done
done

# 2. Restore the sealing key BEFORE the controller exists
kubectl create namespace sealed-secrets
kubectl apply -f ../dso202-keys/sealing-key.backup.yaml

# 3. Bootstrap Argo CD (server-side apply: the ApplicationSet CRD is too large for client-side apply)
kubectl apply -k bootstrap/argocd --server-side --force-conflicts
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

# 4. The only hand-applied Argo CD objects
kubectl apply -f bootstrap/root
kubectl get applications -n argocd -w        # sealed-secrets -> platform-* -> tasktracker-dev

# 5. Sign in (port 8443: 8080 is used by Jenkins on this laptop) and release staging
kubectl port-forward svc/argocd-server -n argocd 8443:443 &
argocd admin initial-password -n argocd
argocd login localhost:8443 --username admin --insecure
argocd app sync tasktracker-staging

# 6. Back up the key again (the controller may have added one)
kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > ../dso202-keys/sealing-key.backup.yaml && chmod 600 ../dso202-keys/sealing-key.backup.yaml
```

Measured in Task 9: 12 min 30 s from `kind create cluster` to a working dev
frontend, including the image preload and first pulls of the Argo CD images.

## Cleanup

```bash
kind delete cluster --name dso202-gitops
# keep ../dso202-keys/ only as long as the SealedSecrets in Git must stay readable
```

## How credentials are handled

* The chart never renders a `Secret` (C3). Pods read `DB_USER`, `DB_PASSWORD`,
  `POSTGRES_USER` and `POSTGRES_PASSWORD` from the existing Secret
  `tasktracker-credentials`.
* That Secret is created by the Sealed Secrets controller from
  `platform/<env>/tasktracker-credentials.sealed.yaml`. Each file was produced by
  `kubectl create secret ... --dry-run=client -o yaml | kubeseal --format yaml`
  from a git-ignored `secrets-plain/<env>.env`, so the plaintext Secret was never
  written to disk. dev and staging have different passwords and are sealed
  separately (strict scope).
* The plaintext inputs were deleted from the working tree. The values and the
  sealing-key backup live outside the repository in `../dso202-keys/` (mode 600).
* `git log -p --all -S<value>` returned nothing for every credential value (Task 4).

## Deviations from the brief (all deliberate, documented)

1. **Port 8443 instead of 8080** for the Argo CD port-forward: Jenkins already listens on 8080.
2. **Image stand-ins.** The tutor's `1.1` tags were not published and the `1.0` images are
   arm64-only. `1.1` images were built locally on top of `1.0` (frontend shows `v1.1` in the
   header; backend 1.1 refuses to start without `APP_ENV`) and run under QEMU emulation. They are
   loaded with `docker save | ctr import` because `kind load` in kind v0.20 fails on this host.
3. **CoreDNS upstream.** After a host reboot, Docker Desktop's resolver (192.168.65.254) timed out
   inside Pods, so the Sealed Secrets chart could not be fetched. CoreDNS forwards to 8.8.8.8 and
   1.1.1.1 on this laptop. This is part of the cluster, not of the GitOps state.
4. **`ReplicaSet` and `Pod` in the `dso202` whitelist** (Task 6). Argo CD drops kinds the project
   does not permit from an Application's resource tree. Without these two entries no Pod appears,
   and the `logs, get` permission granted to `reviewer` has nothing to show. Both kinds are
   namespaced and created by the controllers of kinds already permitted. No platform or
   cluster-scoped kind was added.

## Written answers

### Q1. Why is `platform` applied by hand while `dso202` is created by the root Application, and what is the risk if `dso202` may deploy into `argocd`?

`platform` must exist **before** the root Application, because every Application names its project
and the root is in `platform`. It cannot be delivered by the Application that depends on it. It is
also the administrator-level project: any repository path, cluster-scoped kinds, and the `argocd`
namespace. Keeping it out of the `argocd/` directory means a merged pull request cannot widen it.
Changing it takes a deliberate `kubectl apply` by an administrator. `dso202` is an ordinary,
least-privilege boundary, so it is versioned and reviewed in Git like everything else, and the
root recreates it on every rebuild.

If `dso202` could deploy into `argocd`, a commit to the workload chart could add an
`Application` or `AppProject` there, for example an Application in project `platform` that
deploys anything anywhere. It could also edit `argocd-cm` or `argocd-rbac-cm`. A workload author
would then have administrator rights over the whole cluster, which defeats the project boundary.

### Q2. What does strict scope prevent, and what is lost and what must be done if the sealing key is lost?

With strict scope, the Secret's **name and namespace** are part of the encrypted data. A
SealedSecret can only be decrypted as `tasktracker-credentials` in the namespace it was sealed for.
That stops someone with write access to another namespace from copying the file (or renaming it)
to get the plaintext in a place they can read. It is also why the dev file cannot be reused in
staging.

If the private key is lost, every SealedSecret in Git becomes permanently unreadable. Secrets that
already exist in a running cluster keep working, but they are lost with the cluster, and a rebuild
(Task 9) leaves the platform Applications `Degraded` with `no key could decrypt secret`. Recovery:
let the controller generate a new key, re-seal every credential from the original values (kept in
a password manager), commit the new files, and back up the new key at once. If the key was leaked
rather than lost, the credentials themselves must also be rotated, because anyone with the key can
decrypt every old commit.

### Q3. `Synced` vs `Healthy`

`Synced` compares **Git with the cluster**: every rendered object exists and matches the desired
state. `Healthy` asks whether the objects **work**: Deployments rolled out, Pods ready, the PostSync
Job succeeded. The two are independent.

Example from Task 7, step 5 (`docs/evidence.md`, Task 7): after the backend 1.1 merge,

```text
Sync Status:        Synced to main (9dc39a1)
Health Status:      Degraded
apps   Deployment  dso202-dev  tasktracker-backend  Synced  Degraded  Deployment "tasktracker-backend" exceeded its progress deadline
```

Git and the cluster agreed (the Deployment did ask for image `1.1`), but the new Pod crash-looped
on `APP_ENV`, and after `progressDeadlineSeconds: 120` (C6) the Deployment was reported
`Degraded`. Through the restored Application health check in `argocd-cm`, `root` also turned
`Degraded`.

Observation from Task 5: a child that is `OutOfSync` / `Missing` (staging before its first manual
sync) did **not** make `root` `Progressing` on v3.5.6. `root` stayed `Healthy`, while a `Degraded`
child did propagate. Argo CD appears not to count a child's `Missing` health toward the parent,
because the missing state is already reported as `OutOfSync`.

### Q4. Argo CD RBAC vs Kubernetes RBAC; what changes with SSO

* **Argo CD RBAC** controls what a person may do **through Argo CD** (UI, CLI, API): `get`/`sync`/
  `delete` applications, read `logs`, `exec`, read projects. It is configured in `argocd-rbac-cm`
  (`policy.csv`, `policy.default`) from `bootstrap/argocd/argocd-rbac-cm-patch.yaml`. Accounts are
  declared in `argocd-cm` (`accounts.reviewer`), and AppProject roles can add more.
* **Kubernetes RBAC** controls what an identity (a user certificate or a ServiceAccount) may do
  **against the Kubernetes API**. In Assignment 2 that is the `app-reader` Role and
  `app-viewer-binding` in `platform/<env>/rbac.yaml`.
* The two are separate. Argo CD's controller applies changes with its own powerful ServiceAccount,
  so a person with no Kubernetes rights can still change the cluster if Argo CD RBAC lets them sync.
  A `kubectl` user is not limited by `policy.csv` at all.

With SSO through the organisation's identity provider (Dex/OIDC), the local `accounts.reviewer` and
its password go away. `policy.csv` would bind **IdP groups** to **roles** instead of naming local
users, for example:

```text
p, role:dso202-reader, applications, get,  dso202/*, allow
p, role:dso202-reader, projects,     get,  dso202,   allow
p, role:dso202-reader, logs,         get,  dso202/*, allow
g, dso202-reviewers, role:dso202-reader          # group claim from the IdP
```

`scopes: '[groups, email]'` tells Argo CD which token claims to match, and `policy.default: ""`
still denies everything else.

### Q5. Why is `argocd app rollback` refused, what is the GitOps equivalent, and why `git revert` rather than deleting the bad commit?

The refusal (Task 7, step 7):

```text
rpc error: code = FailedPrecondition desc = rollback cannot be initiated when auto-sync is enabled
```

A rollback would make the cluster match an older revision while Git still says `main` = backend 1.1.
Automated sync would immediately re-apply `main`, so Argo CD refuses rather than fight itself.
Desired state lives in Git, so the cluster cannot be "rolled back" behind Git's back.

The GitOps equivalent is to **change Git**: `git revert <bad-sha>` on a branch, a reviewed pull
request (#4), and a merge. Argo CD pulls the revert like any other commit. A fix-forward (#5) then
shipped the release properly.

`git revert` adds a new commit and keeps history intact (principle 2). Deleting the commit means
rewriting and force-pushing a shared branch. That breaks every clone and open branch, loses the
audit trail of what ran in dev and why, and can leave tags (`v1.2.0` contains the bad commit and its
revert) and Argo CD's recorded revisions pointing at commits that no longer exist on `main`.

Observed detail: dev took about 8½ minutes to pick up the revert. The in-flight sync of the bad
revision kept retrying (retry `limit: 5`, backoff up to 3 min) before auto-sync moved on.
`argocd app terminate-op tasktracker-dev` would shorten that.

### Q6 (a). One repository for chart and environment configuration: two advantages, two disadvantages

Advantages:
1. **Atomic, consistent releases.** One pull request changes the chart and the values together, and
   one tag (`v1.2.0`) pins both. Staging can never get a chart from one version and values from
   another.
2. **Simplicity.** One URL in `sourceRepos`, one set of credentials, and one history to read. For a
   single-person project the cost of a second repository buys nothing.

Disadvantages:
1. **No separation of access.** Anyone who can change the chart can also change `argocd/`
   (Applications, projects) and both environments' values. Separate repositories could have
   different reviewers and permissions.
2. **Noisy coupling.** Every commit (chart refactor, README, drill) moves `main`. That triggers
   reconciliation of everything that tracks `main`, and tags carry unrelated files. If application
   code were added, CI would commit image bumps into the same history and could loop on its own
   commits.

### Q6 (b). What is *not* under GitOps control after the rebuild, and how production teams handle it

* **The bootstrap layer** (`bootstrap/argocd`, including the `argocd-cm`/`argocd-rbac-cm` patches):
  applied by hand, so a commit there changes nothing until someone re-applies it (Task 6). In
  production Argo CD usually manages itself through a self-managed Application, or the cluster is
  provisioned with it by Terraform or Cluster API.
* **The root Application and `platform` project**: applied by hand. In production a cluster
  bootstrap pipeline, or a central management cluster (ApplicationSet / cluster generator), creates
  them.
* **The sealing key**: outside Git by design and backed up by hand. In production it is stored in a
  KMS or secret manager with automated backup and rotation, or replaced by External Secrets reading
  from Vault or a cloud secret manager.
* **Database contents**: lost in the rebuild. In production they are covered by managed database
  backups or scheduled `pg_dump`/Velero snapshots with tested restores.
* **Argo CD local account passwords** (the `reviewer` password set in Task 6 was gone after the
  rebuild): in production SSO replaces local accounts.
* **Local workarounds** (CoreDNS upstream, image preload): in production cluster DNS and registry
  mirrors are part of the cluster's infrastructure-as-code.

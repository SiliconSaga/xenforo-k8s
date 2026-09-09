# xenforo-k8s

A Kustomize-based [XenForo](https://xenforo.com) deployment that runs the **same core three ways** — plain Docker, plain Kubernetes, and Kubernetes-plus-platform-extras (GitOps). One source of truth, base observability, and no licensed source in any image. Follows the pattern established by [KubicValheim](https://github.com/SiliconSaga/KubicValheim), minus the game-server specifics.

**You need your own XenForo license.** This repository contains no XenForo source and never will — see [`docs/licensing-and-ci.md`](docs/licensing-and-ci.md).

## One core, three flavors

A single Kustomize `base/` (Deployment + Service + metrics Service + Ingress + PVC) is the one source of truth. Each platform extra is an additive Kustomize **component**; overlays compose them. The container images, volumes and probes are the same everywhere — what varies is where the database and its credentials come from, plus a small number of deliberate per-flavor patches (the GitOps overlay sets `XF_TITLE` and swaps the base `Ingress` for an `HTTPRoute`).

| Component | What it adds |
|---|---|
| `observability` | ServiceMonitor + PrometheusRules against Caddy's metrics listener |
| `backup` | nightly `mysqldump` CronJob to a separate PVC |
| `db-throwaway` | a disposable MySQL Deployment beside the forum |
| `db-dataservice` | a **database** vended from mimir's shared MySQL cluster |
| `db-mimir` | a whole PXC **cluster** of its own, via a Crossplane `MySQLInstance` claim |
| `secrets-openbao` | publishes `xenforo-secrets/db-password` from OpenBAO |

The three `db-*` components are mutually exclusive — each sets the same connection fields, so enabling two leaves a database running that nothing points at. `db-dataservice` is the current recommendation: `db-mimir` provisions ~4 pods and ~1.3Gi for one app, and as of 2026-09-06 no `MySQLInstance` claim had ever existed on the SiliconSaga cluster, making it the *less*-travelled path despite being the older file.

`secrets-openbao` is only needed alongside `db-throwaway` or `db-mimir`. `db-dataservice` generates and owns the credential itself, so pairing them would mean two sources for one password.

### Flavor 1 — Plain Docker

For users with no Kubernetes, and for rehearsing upgrades. See [`docker/`](docker/): `cp .env.example .env`, unpack XenForo into `./xf`, `docker compose up -d --build`.

### Flavor 2 — Plain Kubernetes

Boots with a bare kustomize apply, including a disposable database:

```bash
kubectl apply -k kustomize/overlays/plain
```

Then seed the forum tree and run the installer — [`docs/install.md`](docs/install.md). Reach it with `kubectl -n xenforo port-forward svc/xenforo 8080:80`.

### Flavor 3 — GitOps (ArgoCD + mimir DataService)

`kustomize/overlays/gitops` (base + observability + backup + db-dataservice) with Caddy's metrics scraped into heimdall's Prometheus, an `HTTPRoute` publishing the forum through the shared traefik-gateway, and the database vended from mimir's shared MySQL cluster. The base `Ingress` is deleted in this overlay — shipping both meant two objects claiming one hostname on the same controller.

**Test through Git** — change flavor 3 by committing and syncing, never `kubectl edit` (selfHeal reverts it).

**Proven live on 2026-09-06** on the SiliconSaga GKE cluster: `forum.cmdbee.org`, XenForo 2.3.12, on the first database ever vended from mimir's shared MySQL. See [`docs/install.md`](docs/install.md) for the exact sequence that was run.

## Layout

```
image/                       # the runtime image: Dockerfile, config.php, Caddyfile
docker/                      # Flavor 1: compose + env + README
kustomize/
  base/                      # the shared core (one source of truth)
  components/
    observability/           # ServiceMonitor + PrometheusRules against Caddy's metrics (opt-in)
    backup/                  # nightly mysqldump CronJob to its own PVC (opt-in)
    secrets-openbao/         # ExternalSecret for xenforo-secrets (opt-in)
    db-throwaway/            # disposable MySQL 8.4 — self-contained, no prerequisites
    db-dataservice/          # a DATABASE vended from mimir's shared MySQL cluster
    db-mimir/                # a whole PXC CLUSTER, via a Crossplane MySQLInstance claim
  overlays/
    plain/                   # Flavor 2: base + plain Secret + throwaway DB
    gitops/                  # Flavor 3: base + observability + backup + db-dataservice + HTTPRoute
docs/
  install.md                 # seeding the forum tree, per flavor
  upgrades.md                # image vs XenForo, and how to do each
  licensing-and-ci.md        # why no image contains XenForo source
```

## How it runs

One pod, two containers:

- **`php-fpm`** — our image. PHP 8.4 with the extension set XenForo needs, `config.php` driven entirely from the environment.
- **`caddy`** — stock `caddy:2.11-alpine`, serving the forum tree and proxying PHP over `127.0.0.1:9000`. TLS is the ingress's job, not Caddy's.

An init container copies `config.php` and the `Caddyfile` out of the image and onto the volume / a shared `emptyDir` at every start, so both files are versioned with the image rather than drifting in a ConfigMap.

The forum tree lives on a ReadWriteOnce PersistentVolume, because XenForo writes to it at runtime — add-on installs, the template cache, attachments. That also means **one replica, `Recreate` strategy**, deliberately. A second replica would need RWX storage and a shared cache first, and for a low-activity forum it buys nothing.

### Secrets

The database password reaches PHP as `XF_DB_PASSWORD_FILE` — a path to a mounted file, not an environment value. XenForo's `getenv_docker()` helper resolves the `_FILE` indirection. A secret in the environment leaks into `phpinfo()` and every child process; a file mount does not. It does not protect the value in memory — PHP reads it into config either way — so this narrows exposure rather than eliminating it.

### Database

Two interchangeable components, and the pod spec is identical either way — only `XF_DB_HOST` differs, with the password still arriving through `XF_DB_PASSWORD_FILE` from the same secret.

- [`db-throwaway`](kustomize/components/db-throwaway/README.md) — a single-pod MySQL 8.4 with no prerequisites, so the forum runs end to end on a bare cluster. Not backed up, replicated, or tuned.
- [`db-mimir`](kustomize/components/db-mimir/README.md) — claims a Percona XtraDB cluster from [mimir](https://github.com/SiliconSaga/mimir)'s Crossplane composition. Needs Crossplane and the PXC operator on the cluster; verified end-to-end on Docker Desktop's Kubernetes.

`db-throwaway` is MySQL rather than MariaDB specifically so the cutover between them is a dump and a hostname change rather than a cross-engine migration.

### Observability

`components/observability` scrapes Caddy's metrics listener (`:2020/metrics`) into heimdall's Prometheus. That gives HTTP-level signal — request rate, latency, status codes. PHP-FPM pool metrics and XenForo internals are not covered and would need a separate exporter.

## Images

`ghcr.io/siliconsaga/xenforo-k8s` — built by [`.github/workflows/image.yml`](.github/workflows/image.yml) on every push to `image/`, weekly for base-image fixes, and on demand. Tagged `latest` on `main` plus a long-form SHA tag. Contains no XenForo source, so CI needs no license and no credentials beyond `GITHUB_TOKEN`.

Pin a digest for anything you care about; see [`docs/upgrades.md`](docs/upgrades.md).

## Adding Access

To give another maintainer the minimally required access to Kubernetes to work with this setup:

```bash
# 1. IAM: lets them authenticate. Grants NO Kubernetes permissions by itself.
gcloud projects add-iam-policy-binding teralivekubernetes \
  --member="user:THEIR@EMAIL" --role=roles/container.clusterViewer
```

Apply the `minimal-access.yaml` RBAC resource, replacing the target email - `kubectl apply -f .\minimal-access.yaml -n xenforo`

Then they run `gcloud container clusters get-credentials ttf-cluster --location us-east1-d --project teralivekubernetes`

**The identity in the RoleBinding is case-sensitive; the one in the IAM command is not.** Google presents the capitalization the account was *registered* with, so `gcloud` accepts `first.last@example.com` while RBAC — an exact string compare — never matches an identity the API server reports as `First.Last@example.com`.

Authentication still succeeds, which is what makes it confusing: they reach the cluster, and the binding simply never applies. Requests that depend on it return **Forbidden**, and `kubectl auth can-i get pods -n xenforo` answers `no`. Nothing points at the casing as the cause. Settle it with:

```bash
kubectl auth whoami
```

and copy the **`Username` value exactly as printed** into `minimal-access.yaml`, replacing `THEIR@EMAIL`. It is usually the email address, but paste what that command reports rather than retyping an address — the whole failure mode is a string that looks right and is not.

**Do not diagnose this with `kubectl auth can-i --list`.** On this cluster it returns a near-empty table and warns `the list may be incomplete: webhook authorizer does not support user rule resolution`, so it looks identical whether access works or not. That depends on the authorizer a cluster is configured with rather than being true of GKE universally — but it is what you will see here. Test a concrete verb instead:

```bash
kubectl auth can-i get pods -n xenforo
```

**What `edit` actually grants is broader than it sounds.** Namespace-wide `edit` includes reading Secrets — convenient, since a maintainer can pull the database credentials themselves instead of being sent the live password out of band — and it permits deleting the PVCs that hold the forum. It also allows creating Pods with any ServiceAccount in the namespace, which means indirectly acquiring that ServiceAccount's API permissions. For a tighter grant, use `view` plus a narrow Role over just the one Secret.

## Credit

The PHP extension set, the env-driven `config.php`, and the Caddyfile are adapted from XenForo Ltd.'s own MIT-licensed container tooling at [`xenforo-ltd/cli`](https://github.com/xenforo-ltd/cli). See [`image/NOTICE.md`](image/NOTICE.md).

## License

This project is Apache-2.0. XenForo itself is commercial software under its own license; nothing here grants you any rights to it.

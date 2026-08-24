# Installing

The runtime image ships without XenForo source, so every flavor has the same two-step shape: bring up the pod, then put the forum tree on the volume.

## Prerequisites

- A XenForo license, and the release archive downloaded from your customer area.
- For the Kubernetes flavors: a cluster with a default StorageClass.

## Flavor 1 — plain Docker

See [`../docker/README.md`](../docker/README.md). Unpack into `docker/xf/` and `docker compose up -d --build`.

## Flavor 2 — plain Kubernetes

```bash
kubectl apply -k kustomize/overlays/plain
```

The pod starts with an empty volume. The init container logs `XenForo source not present yet — skipping config.php install` and the forum 404s — expected.

Copy the tree in:

```bash
POD=$(kubectl -n xenforo get pod -l app=xenforo -o name)

# Unpack your download locally first, then:
kubectl -n xenforo cp ./xenforo-2.3.x/. "${POD#pod/}":/var/www/html -c php-fpm
```

Restart so the init container installs `config.php` and fixes ownership:

```bash
kubectl -n xenforo rollout restart deploy/xenforo
```

Then run the installer:

```bash
kubectl -n xenforo exec deploy/xenforo -c php-fpm -- php cmd.php xf:install
```

Reach it with a port-forward — the plain overlay assumes no ingress controller:

```bash
kubectl -n xenforo port-forward svc/xenforo 8080:80
```

### Changing the database password

`overlays/plain/secret.yaml` has a placeholder committed to git so the overlay boots with no setup. Change it before the database is initialized — MySQL only reads `MYSQL_PASSWORD` on first start, so changing it after the fact means also changing it inside MySQL.

## Flavor 3 — GitOps

The `gitops` overlay is deployed by an ArgoCD Application, with the database password sourced from OpenBAO through External Secrets. Before syncing:

1. Write `db-password` to `secret/xenforo` in OpenBAO.
2. Set the real hostname in `overlays/gitops/kustomization.yaml`.
3. Confirm `openbao-kv` is the ClusterSecretStore name in this cluster.

Seeding the tree is the same `kubectl cp` as flavor 2 — a one-time bootstrap, not something GitOps manages.

**Test through Git.** ArgoCD syncs from the in-cluster seed-Gitea, not from GitHub. A push to GitHub reviews the code; it does not deploy it. Re-hydrate with nordri's `update-embedded-git.sh <homelab|gke>` and hard-refresh the Application. `kubectl edit` against a `selfHeal: true` Application gets reverted within ~3 minutes.

## Verifying

```bash
kubectl -n xenforo get pods
kubectl -n xenforo logs deploy/xenforo -c php-fpm
kubectl -n xenforo logs deploy/xenforo -c caddy
kubectl -n xenforo exec deploy/xenforo -c caddy -- wget -qO- localhost:8080/healthz
```

`/healthz` is answered by Caddy directly and does not touch PHP or the database — it tells you the pod is serving, not that the forum works.

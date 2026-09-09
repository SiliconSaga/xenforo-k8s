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

Copy the tree in. The download is a zip whose root is a single `upload/` directory, and the runtime image carries `unzip` — so ship the one archive and expand it in place rather than streaming ~15,000 small files across the API server:

```bash
POD=$(kubectl -n xenforo get pod -l app=xenforo -o name)
POD=${POD#pod/}

kubectl -n xenforo cp ./xenforo_2.3.12_<yourlicense>_full.zip "$POD":/tmp/xf.zip -c php-fpm
kubectl -n xenforo exec "$POD" -c php-fpm -- unzip -q /tmp/xf.zip -d /tmp/xf
kubectl -n xenforo exec "$POD" -c php-fpm -- cp -a /tmp/xf/upload/. /var/www/html/
kubectl -n xenforo exec "$POD" -c php-fpm -- rm -rf /tmp/xf /tmp/xf.zip
```

Stage on `/tmp`, not the forum volume, so the archive never becomes something to clean off the PVC later.

The trailing `/.` in `upload/.` is load-bearing: it copies the *contents* including dotfiles, rather than creating `/var/www/html/upload/`.

Restart so the init container installs `config.php` and fixes ownership:

```bash
kubectl -n xenforo rollout restart deploy/xenforo
```

**Do not skip this.** The init container only installs `config.php` when `/var/www/html/src` exists, so on the pre-seed pod it deliberately did nothing. This restart is also what chowns `internal_data`, `data` and `src/addons` to `82:82` — `cp` writes as root while PHP-FPM's workers run as uid 82, and without the fix XenForo fails at writing attachments and its template cache in ways that read as XenForo bugs rather than permissions. The rest of the tree stays root-owned on purpose: PHP having no write access to its own code is the point.

Then run the installer. It is interactive — it prompts for the admin username, email and password — so it needs a TTY:

```bash
kubectl -n xenforo exec -it deploy/xenforo -c php-fpm -- php cmd.php xf:install
```

No database details to enter: `config.php` is driven entirely from the environment, and `XF_DB_PASSWORD_FILE` points at the mounted secret, so host, port, database, user and password all come from whichever `db-*` component is enabled.

**While it runs the forum returns its own HTTP 503**, with `Server: XenForo` on the response — that is XenForo's maintenance page, not a broken deployment. `/healthz` keeps answering 200 throughout, which is what stops the kubelet restarting the pod mid-install. A schema of ~220 tables lands first, then default content, phrases, templates and styles; the whole thing took a few minutes on a single shared PXC node.

Reach it with a port-forward — the plain overlay assumes no ingress controller:

```bash
kubectl -n xenforo port-forward svc/xenforo 8080:80
```

### Changing the database password

`kustomize/overlays/plain/secret.yaml` has a placeholder committed to git so the overlay boots with no setup. Change it before the database is initialized — MySQL only reads `MYSQL_PASSWORD` on first start, so changing it after the fact means also changing it inside MySQL.

## Flavor 3 — GitOps

The `gitops` overlay gets its database from mimir's shared MySQL via `db-dataservice`, so there is no secret to seed first. Before syncing:

1. Set the real hostname in `kustomize/overlays/gitops/httproute.yaml` (`spec.hostnames`). That is the only place it lives now — this overlay deletes the base `Ingress` rather than patching its host, so there is no second copy to keep in sync.
2. Confirm mimir's shared MySQL is actually enabled: `shared/mysql-cluster.yaml` listed in `shared/kustomization.yaml`, and the `MIMIR_MYSQL_*` block uncommented in the operator deployment. With either missing the `DataService` reports `ClusterNotFound`.
3. Check the `HTTPRoute` `parentRefs` match this cluster's Gateway — on SiliconSaga that is `traefik-gateway` in `kube-system`, listener `websecure`.

Seeding the tree is the same `kubectl cp` as flavor 2 — a one-time bootstrap, not something GitOps manages.

Watch for `DataService` reaching `Ready` before expecting the pod to work:

```bash
kubectl -n xenforo get dataservice xenforo-db
```

**Test through Git.** ArgoCD syncs from the in-cluster seed-Gitea, not from GitHub. A push to GitHub reviews the code; it does not deploy it. Re-hydrate with nordri's `update-embedded-git.sh <homelab|gke>` and hard-refresh the Application. `kubectl edit` against a `selfHeal: true` Application gets reverted within ~3 minutes.

## Migrating content from an existing board

Copying a forum tree from another server is the same two steps as a fresh seed — **including the restart.** It is easy to skip, because the first step appears to work.

**Put the board in maintenance mode first.** The single pod keeps serving from `xenforo-data` while you write into it, so PHP-FPM and Caddy will happily serve a half-copied tree to whoever is browsing. Enable maintenance mode in the ACP, copy, then restart. Do *not* scale the Deployment to zero to avoid this unless a separate pod or Job mounts `xenforo-data` to perform the copy — with no pod there is nothing to `kubectl cp` into.

```bash
# with maintenance mode on, after rsync/tar/cp of the old tree onto the volume:
kubectl -n xenforo rollout restart deploy/xenforo
```

**An archive from another host can carry that host's numeric UIDs.** Whether it does depends on the tool and on privilege: `cp -a` and `rsync -a` request ownership preservation, and GNU `tar` preserves archived ownership when extracting **as root** (`-p` is the default there) while an unprivileged extraction assigns the extracting user instead. So the outcome varies — check rather than assume.

Observed on 2026-09-08 after a real migration: `internal_data`, `data` and `src/addons` arrived owned by `498`/`501` with mode `drwxrwxr-x`, which gives "other" no write — and PHP-FPM runs as uid **82**.

The failure does not look like permissions. PHP could still write the pre-existing `code_cache` subdirectories (they arrived mode 777) but could not create the *new* ones XenForo 2.3 needs, so templates recompiled on every request:

- `GET /forum/` → **500** after 10.9s, `Allowed memory size of 268435456 bytes exhausted` inside a DB fetch — that 256M was the limit *before* this was raised to 512M, so expect the larger number now
- `POST /login/keep-alive` → **500**, the poll the browser fires immediately after signing in, so the visible symptom was **"cannot log in"**

The restart alone fixed both — 0.62s and 0.20s, no code or config change — because the init container's `chown -R 82:82` reconciles the foreign ownership.

Check it landed **recursively**, not just the three top directories: a `chown -R` that died partway leaves those correct and their contents wrong, which is exactly what a spot check passes.

```bash
kubectl -n xenforo exec deploy/xenforo -c php-fpm -- \
  find /var/www/html/internal_data /var/www/html/data /var/www/html/src/addons \
    \( ! -user www-data -o ! -group www-data \) -print
```

No output means every checked path is owned by `www-data` (uid 82) and the check passed. Any path listed is one PHP may not be able to write.

`-user`/`-group`/`-print` rather than GNU's `-uid`/`-gid`/`-printf`: this image is Alpine and `find` is BusyBox, which does not implement those. The GNU form fails with `find: unrecognized: -uid` — which at least fails loudly rather than reporting a false pass.

**Then turn maintenance mode back off in the ACP**, before the checks under [Verifying](#verifying) — the front page and `/admin.php` answer from the maintenance page while it is on, so those checks cannot tell you anything until it is cleared.

Two things a content migration also leaves behind:

- **`boardUrl` and `homePageUrl` still point at the old domain.** The login form action is relative and `_xfRedirect` is derived from the request, so signing in still works — but the logo and "Home" link off-site, and sitemap pings go to the old host. Fix in the ACP, not here.
- **Add-ons listed in `xf_addon` whose files were not copied.** XenForo logs `Class … does not exist` once per render for each active one. **May cause request failures**, so deactivate or reinstall rather than leaving it: how bad it is depends on the extension point. A missing *widget* class is caught per widget — the page still returns 200 with that widget's content absent, which is what we saw (494 entries in 48h from one active widget, flooding `xf_error_log`). A missing class extension or listener is not contained that way and can fail the whole request path.

## Verifying

```bash
kubectl -n xenforo get pods
kubectl -n xenforo logs deploy/xenforo -c php-fpm
kubectl -n xenforo logs deploy/xenforo -c caddy
kubectl -n xenforo exec deploy/xenforo -c caddy -- wget -qO- localhost:8080/healthz
```

`/healthz` is answered by Caddy directly and does not touch PHP or the database — it tells you the pod is serving, not that the forum works. That distinction is exactly why the pod stays `2/2 Running` through an install that is returning 503 to real traffic, and why it is not sufficient as a post-install check.

For the real check, fetch the front page and the control panel:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<your-host>/
curl -sS -o /dev/null -w '%{http_code}\n' https://<your-host>/admin.php
```

Both 200 means the forum is genuinely up. A 503 carrying `Server: XenForo` means an install or upgrade is still running.

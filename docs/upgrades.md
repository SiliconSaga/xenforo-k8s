# Upgrades

Two things upgrade independently, and keeping them separate is the point of the split in [`licensing-and-ci.md`](licensing-and-ci.md).

## Upgrading the runtime image

Nothing to do — CI rebuilds `ghcr.io/siliconsaga/xenforo-k8s:latest` on every push to `image/`, and weekly for base-image security fixes. Roll it out with:

```bash
kubectl -n xenforo rollout restart deploy/xenforo
```

For anything but a homelab, pin a digest in `kustomize/base/kustomization.yaml`'s `images:` block rather than tracking `latest`, so a rollout is a deliberate act with something to roll back to:

```yaml
images:
  - name: ghcr.io/siliconsaga/xenforo-k8s
    newName: ghcr.io/siliconsaga/xenforo-k8s
    digest: sha256:...
```

## Upgrading XenForo itself

XenForo upgrades are file-replacement plus a schema migration, and both happen against the volume.

1. **Back up first.** The database and the volume, together — a half-migrated forum needs both to roll back.

   ```bash
   kubectl -n xenforo exec deploy/xenforo-db -- \
     mysqldump -u xenforo -p"$(...)" xenforo > xenforo-$(date +%F).sql
   ```

2. **Rehearse in the Docker flavor.** Point `docker/xf` at a copy of the tree, restore the dump into the compose database, run the upgrade there first. This is the main reason flavor 1 exists.

3. **Put the forum in maintenance mode** from the admin control panel, or accept errors during the migration.

4. **Copy the new files in**, over the top of the existing tree:

   ```bash
   POD=$(kubectl -n xenforo get pod -l app=xenforo -o name)
   kubectl -n xenforo cp ./xenforo-2.3.y/. "${POD#pod/}":/var/www/html -c php-fpm
   ```

   XenForo release archives are meant to be unpacked over an existing install. Do not delete the tree first — `internal_data/` and `data/` hold your attachments.

5. **Run the migration:**

   ```bash
   kubectl -n xenforo exec deploy/xenforo -c php-fpm -- php cmd.php xf:upgrade
   ```

6. **Restart** so opcache and the template cache are rebuilt cleanly:

   ```bash
   kubectl -n xenforo rollout restart deploy/xenforo
   ```

7. **Refresh XenForo's CA bundle** — the upgrade just overwrote it with the release's snapshot:

   ```bash
   scripts/refresh-ca-bundle.sh
   ```

## XenForo's own CA bundle, and why step 7 is not optional

XenForo ships `src/XF/Http/ca-bundle.crt` and `XF\SubContainer\Http` hands it to Guzzle as the `verify` path, so **every outbound HTTP request XenForo makes validates against that file and ignores the container's system trust store.** Link previews, the image proxy fetching user-supplied URLs, add-on and licence checks, Akismet — all of it.

Three consequences worth internalising:

- **Upgrading `ca-certificates` in the image does not touch it.** The image's store covers PHP's own OpenSSL/curl defaults; XenForo's HTTP client never consults it.
- **Rebuilding the image does not touch it either**, because the forum tree lives on the PersistentVolume. The bundle is only as fresh as the release that unpacked it.
- **A XenForo upgrade resets it** to that release's snapshot, which is why the refresh is a numbered step above rather than a one-off.

This stopped being theoretical on 2026-10-20. The eMudhra CA compromise (CVE-2026-111943) put eight recoverable intermediate CA keys in circulation, and the shipped bundle still trusted `emSign ECC Root CA - G3`, the root they cross-sign up to. Verified against the live pod: XF's bundle accepted a certificate chaining to a compromised intermediate while the same request through the system store also did. Two stores, two fixes.

`scripts/refresh-ca-bundle.sh` installs the current [curl extract](https://curl.se/docs/caextract.html), which is what XenForo's own `ca-bundle-readme.txt` says to do, and regenerates `ca-bundle-legacy-openssl.crt` as bundle + `legacy-equifax.crt` (that variant exists so Google endpoints validate on OpenSSL older than 1.0.2). It backs up both files first, then proves the result two ways: the compromised test chain is rejected, **and** `xenforo.com` and `accounts.google.com` still validate — because a bundle that rejects everything would pass the first check alone.

`scripts/refresh-ca-bundle.sh --check` reports without changing anything; it exits non-zero when the bundle is stale, so it suits a scheduled check.

Audit any other PEM the tree carries after an upgrade — `src/vendor/stripe/stripe-php/data/ca-certificates.crt` is a second bundled store, live only if Stripe payments are enabled:

```bash
kubectl -n xenforo exec deploy/xenforo -c php-fpm -- \
  find /var/www/html -name '*.pem' -o -name '*ca-bundle*' -o -name '*.crt'
```

## What the deployed version actually is

The running XenForo version is a property of the volume, not of a git tag — the honest cost of not baking the tree. Record it somewhere that survives: the admin control panel reports it, and it is worth noting in the deployment's annotations after each upgrade so `kubectl describe` answers the question too.

## PHP version bumps

`image/Dockerfile` pins `PHP_VERSION=8.4`. XenForo 2.3 supports 7.2+, and XenForo's own tooling defaults to 8.5 — but the add-on ecosystem lags. Before bumping:

1. Check every installed add-on for a stated PHP ceiling.
2. Rehearse with `PHP_VERSION=8.5 docker compose up --build` in the Docker flavor.
3. Bump the ARG default, let CI rebuild, then roll out.

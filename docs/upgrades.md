# Upgrades

Two things upgrade independently, and keeping them separate is the point of the split in [`licensing-and-ci.md`](licensing-and-ci.md).

## Upgrading the runtime image

CI rebuilds `ghcr.io/siliconsaga/xenforo-k8s` on every push to `image/`, and weekly for base-image security fixes. But `kustomize/base/kustomization.yaml` pins a **digest**, so a rebuild does not reach the cluster until someone bumps it. That is deliberate — see the comment there — and it means the image upgrade is a four-step job, not zero.

1. **Find the new index digest.** Not a per-platform one: the index digest is what lets amd64 GKE nodes and arm64 k3d dev clusters resolve from the same pin.

   ```bash
   docker buildx imagetools inspect ghcr.io/siliconsaga/xenforo-k8s:latest
   ```

   The top-level `Digest:` is the one you want, and it **already carries its `sha256:` prefix** — copy the whole value, because every placeholder below expects it. Pasting it after a second prefix gives `@sha256:sha256:…`, which fails as a malformed reference rather than as a missing image, so the error does not point at the typo. This talks to the registry, not the local daemon, so it works even when Docker is unhealthy.

2. **Verify it before pinning it.** A green CI log says the build succeeded, not that the result is what you think. Check the three things that have actually gone wrong here — PHP version, CA package version, and whether the trust store rejects a known-bad chain.

   Set the digest once and check **that**, never `:latest`. The tag can move between step 1 and step 2, and a stale local tag can answer for a different image entirely — verifying `:latest` and then committing a digest checks something you are not shipping:

   The check is one script, used two ways. It asserts rather than prints, so its exit status is the whole answer:

   ```sh
   # verify-image.sh — exits 0 only if this image is safe to pin.
   set -eu

   # Floors, not just printouts. Echoing a version proves nothing: an image can
   # print PHP 8.4.26 and still pass a TLS probe, and 8.4.26 is the
   # unauthenticated-RCE build (CVE-2026-109618/109619). Bump these together
   # with ARG CA_CERTIFICATES_MIN in image/Dockerfile.
   PHP_FLOOR=8.4.27
   CA_FLOOR=20261020-r0

   php_have="$(php -r 'echo PHP_VERSION;')"
   echo "php: $php_have (floor $PHP_FLOOR)"
   php -r "exit(version_compare(PHP_VERSION, '$PHP_FLOOR', '>=') ? 0 : 1);" \
     || { echo "FATAL: PHP $php_have is below the $PHP_FLOOR floor" >&2; exit 1; }

   # apk's own comparator, same as the Dockerfile's floor check — busybox sort
   # has no reliable -V, and these versions are not plain semver.
   ca_have="$(apk list --installed ca-certificates | head -n1 | cut -d' ' -f1 | sed 's/^ca-certificates-//')"
   echo "ca-certificates: $ca_have (floor $CA_FLOOR)"
   [ "$(apk version -t "$ca_have" "$CA_FLOOR")" != "<" ] \
     || { echo "FATAL: ca-certificates $ca_have is below the $CA_FLOOR floor" >&2; exit 1; }

   # Negative control: this host serves a chain built on one of the recoverable
   # eMudhra keys, so a trustworthy store MUST refuse it.
   rc=0
   verify="$(curl -sS --max-time 20 -o /dev/null -w '%{ssl_verify_result}' \
     https://dv-g3b-emudhra.we-have-a-problem.com/)" || rc=$?
   case "$rc" in
     60) ;;  # CURLE_PEER_FAILED_VERIFICATION — the only acceptable answer
     0)  echo "FATAL: trust store ACCEPTS the compromised chain" >&2; exit 1 ;;
     *)  echo "FATAL: no TLS verdict (curl exit $rc) — the probe never reached the host" >&2; exit 1 ;;
   esac
   [ "$verify" = 20 ] || { echo "FATAL: rejected, but ssl_verify_result=$verify (expected 20)" >&2; exit 1; }
   echo "OK: compromised chain rejected (exit 60, verify 20)"
   ```

   **Read the exit code precisely; "curl failed" is not "the chain was rejected."** DNS failure, blocked egress and timeouts all exit non-zero too, so a plain `if curl ...; then fail; fi` passes a *vulnerable* image whenever the probe simply never got through. Only exit 60 with `ssl_verify_result=20` is a rejection; everything else is no verdict, and no verdict must fail the check. This is the same three-way logic as `scripts/refresh-ca-bundle.sh`, for the same reason — and it has been got wrong here more than once.

   With Docker, run it on **both** architectures. The pin is the multi-arch index digest, so verifying only `linux/amd64` leaves the arm64 variant — the one a k3d dev cluster or an arm64 node resolves — entirely unchecked, and the two are separate builds that can differ:

   ```bash
   D=ghcr.io/siliconsaga/xenforo-k8s@<digest-from-step-1>
   rc=0
   for p in linux/amd64 linux/arm64; do
     echo "== $p =="
     docker run --rm --platform "$p" "$D" sh -c "$(cat verify-image.sh)" || rc=1
   done
   [ "$rc" = 0 ] || { echo "FATAL: an architecture failed verification" >&2; exit 1; }
   ```

   The non-native one runs under QEMU and is slower, but it is the same assertion.

   **`rc` is load-bearing, because a `for` loop exits with the status of its *last* iteration.** Without it an amd64 variant that fails every floor still leaves the block at exit 0, so long as arm64 passes — the same "the command failed but the block succeeded" shape as the `curl -f` trap above, and which arch it hides depends only on listing order. Collecting into `rc` rather than relying on `set -e` is deliberate: `set -e` aborts on the first bad arch, and whether *both* variants are broken or only one is the difference between a bad build and a bad publish.

   With no working Docker, run it as a throwaway pod on the digest — which also tests exactly what the cluster will pull. Note this covers only the **node's** architecture, so it verifies that cluster's variant rather than both:

   ```bash
   PROBE="xf-image-probe-$$"
   kubectl -n xenforo run "$PROBE" --restart=Never \
     --image=ghcr.io/siliconsaga/xenforo-k8s@<digest-from-step-1> \
     --command -- sh -c "$(cat verify-image.sh)" \
     || { echo "FATAL: could not create the probe pod" >&2; exit 1; }

   rc=0
   kubectl -n xenforo wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$PROBE" --timeout=180s || rc=$?
   kubectl -n xenforo logs "$PROBE"
   kubectl -n xenforo delete pod "$PROBE"
   [ "$rc" = 0 ] || { echo "FATAL: probe never reached Succeeded (wait exit $rc)" >&2; exit 1; }
   ```

   The `wait` is load-bearing: `kubectl run --restart=Never` returns while the pod is still `Pending`, so reading logs immediately can fail before the container has started — and a failed `logs` call reads as a broken probe rather than a race. A non-`Succeeded` phase *is* the failure signal; the logs only tell you which branch tripped.

   **Save that status before reading the logs, and re-assert it afterwards.** The `logs` and `delete` that follow both succeed against a *failed* pod, so the block without `rc` ends on `delete`'s exit 0 and reports a vulnerable image as verified. Print the logs and clean up either way — you want the diagnosis, and you do not want a leftover pod — but let the saved status have the last word.

   **The `$$` in the pod name, and the `||` on `run`, are both there to stop a *previous* probe from answering for this one.** With a fixed name, an interrupted run leaves `xf-image-probe` behind; the next `kubectl run` then fails with `AlreadyExists`, and `wait` goes on to find that leftover pod already `Succeeded` — on whatever digest it was built for. You get an instant green verdict about an image you never tested. A per-shell name means a leftover cannot be mistaken for the current run, and failing on `run` means a collision stops the block instead of handing it a stale answer.

   One more trap in the script above: `php -v | head -n1` would discard PHP's exit status, and chaining with `;` reports only the last command's. `set -eu` with unpiped commands is what makes a failure fail.

3. **Bump the digest** in `kustomize/base/kustomization.yaml` and commit it. The commit is the record of what the cluster runs — the thing `latest` could never give you.

4. **Apply, then roll out.** `rollout restart` alone is *not enough*: it recreates the pod from the Deployment the cluster already has, so with `:latest` it pulled whatever was newest, and with a digest it would faithfully redeploy the **old** digest. The changed manifest has to reach the cluster first.

   **Which path delivers the digest depends on whether an ArgoCD Application owns xenforo — and today none does.** Checked on GKE 2026-11-03: `kubectl -n argo get applications` lists mimir, nordri, keycloak, velero and the rest, with no `xenforo` among them. So this deployment runs the **gitops** overlay applied directly with `kubectl`, and the manual apply below is the real path rather than a shortcut. Adopting xenforo into ArgoCD is still an open item.

   ```bash
   kubectl apply -k kustomize/overlays/gitops
   kubectl -n xenforo rollout status deploy/xenforo
   ```

   `apply` changes the pod spec, which triggers the rollout on its own — no `rollout restart` needed. For the plain flavor it is `kubectl apply -k kustomize/overlays/plain`.

   ⚠ **Re-check the Application list before each upgrade, because this step becomes actively misleading the moment xenforo is adopted.** [`install.md`](install.md) describes the ArgoCD path for Flavor 3, and there a direct apply is not merely redundant — it is silently undone. ArgoCD syncs from the in-cluster seed-Gitea, not from GitHub, and against a `selfHeal: true` Application a `kubectl apply` is reverted within ~3 minutes. `rollout status` would report the new digest live and the Deployment would quietly return to the old one: a green check and no change, which is worse than an honest failure. Once an `xenforo` Application exists, step 3's commit replaces step 4 entirely — re-hydrate with nordri's `update-embedded-git.sh <homelab|gke>`, hard-refresh the Application, and read the digest off the live Deployment rather than off your own apply.

   ⚠ **Check which overlay the cluster is actually running before applying one.** They are not interchangeable, and the axis that matters is the database: `plain` carries `db-throwaway`, `gitops` carries `db-dataservice`. Applying `plain` over this deployment would repoint the forum at a different, empty database.

   So check the database credential, not the routing — each flavor names its own:

   ```bash
   kubectl -n xenforo get secret
   ```

   `xenforo-db-dataservice` is **gitops**; `xenforo-secrets` is **plain**. To see the binding itself rather than infer it from the Secret's existence, read the Deployment's `php-fpm` env: a literal `XF_DB_HOST: xenforo-db` is base's default (plain), while gitops patches it to a `secretKeyRef` on `xenforo-db-dataservice`.

   Routing is a weaker tell. An HTTPRoute does distinguish them, but *absence of an ExternalSecret* proves nothing — the gitops overlay deliberately dropped `secrets-openbao` once the DataService began owning the password, so neither flavor has one.

   **Roll back by applying a known-good digest — not with `rollout undo`, which is actively wrong for this upgrade.** Revert step 3's commit and apply again through whichever path step 4 established.

   `rollout undo` restores the *previous revision's pod spec*, and until this PR lands that spec is `ghcr.io/siliconsaga/xenforo-k8s:latest` with the default `imagePullPolicy: Always`. Undoing it therefore does not restore the old image at all: it pulls whatever `:latest` resolves to at that moment, which is the newest build — quite possibly the one you are rolling back from. It rolls *forward* under a reassuring name, and `rollout status` goes green either way. That is the same unreviewable-image problem this whole change exists to end, hiding in the rollback advice.

   Once two digest-pinned revisions exist in the Deployment's history, `kubectl -n xenforo rollout undo deploy/xenforo` becomes trustworthy again, because the previous spec then names an immutable image. Check with `kubectl -n xenforo rollout history deploy/xenforo` before relying on it.

Afterwards, confirm the volume's CA bundle survived the pod swap — it lives on the PVC and should, but that is the assumption worth testing rather than asserting:

```bash
scripts/refresh-ca-bundle.sh --check
```

## Upgrading XenForo itself

XenForo upgrades are file-replacement plus a schema migration, and both happen against the volume.

1. **Back up first, and verify both halves.** A half-migrated forum needs the database *and* the volume to roll back.

   **Which half applies depends on the overlay, and the two are opposites.** `components/backup` is composed only by `kustomize/overlays/gitops`, so the CronJob below exists there and *only* there; `components/db-throwaway` and its local `xenforo-db` Deployment belong only to `plain`. Check with `kubectl -n xenforo get cronjob` before picking.

   On the **gitops** overlay a nightly `xenforo-db-backup` CronJob already exists with 14-day retention, so take a fresh run of it rather than hand-rolling a dump. It carries the `--set-gtid-purged=OFF` and `--no-tablespaces` flags a vended DataService tenant needs, and it verifies its own output — `gzip -t` plus mysqldump's `-- Dump completed` footer — before publishing the file under its real name:

   ```bash
   kubectl -n xenforo create job xenforo-db-pre-<version> --from=cronjob/xenforo-db-backup
   kubectl -n xenforo wait --for=condition=Complete job/xenforo-db-pre-<version> --timeout=300s
   kubectl -n xenforo logs job/xenforo-db-pre-<version>
   ```

   ⚠ **On gitops, do not reach for `kubectl exec deploy/xenforo-db -- mysqldump`** — this document said to for longer than it should have. There is no `xenforo-db` Deployment on that overlay at all; the database is mimir's shared MySQL, reached through the `xenforo-db-dataservice` Secret, so the command fails with `deployments.apps "xenforo-db" not found`, which reads like "backups are impossible here" rather than "wrong flavor".

   ⚠ **And on `plain`, the CronJob above is the one that does not exist** — `create job --from=cronjob/xenforo-db-backup` fails `not found` there. That flavor has a local `xenforo-db`, so the `exec … mysqldump` form is the right one, piped through `gzip -c` and checked the same two ways the CronJob checks itself (`gzip -t`, then the `-- Dump completed` footer) before you trust it. **Each overlay's correct procedure is the other's error**, which is exactly how a single unqualified instruction ends up wrong for half its readers.

   The volume is the other half, and the `.sql.gz` does **not** contain it: `internal_data/` holds the attachments. Velero snapshots it:

   ```bash
   velero backup create xenforo-pre-<version> --include-namespaces xenforo \
     --snapshot-volumes --wait
   ```

   **`--wait` is not cosmetic.** `backup create` returns as soon as the object is accepted, so the status read below would otherwise race the controller: an `InProgress` backup reports empty snapshot counts, and empty is easy to misread as "no volumes were captured" — or, worse, to skim as a pair of zeroes that look like a clean answer. Wait for a terminal phase, then read:

   ```bash
   kubectl -n velero get backups.velero.io xenforo-pre-<version> \
     -o custom-columns='PHASE:.status.phase,TRIED:.status.volumeSnapshotsAttempted,DONE:.status.volumeSnapshotsCompleted,ERR:.status.errors'
   ```

   Then check the snapshot *count*, not just the phase — a backup that captured metadata and no volumes also reports `Completed`. Two assertions, both required: `PHASE` is exactly `Completed` (**not** `PartiallyFailed`, which is a terminal phase that also carries real data and is easy to accept by reflex), and `DONE` equals `TRIED` and is non-zero. For the 2.3.13 upgrade that read `Completed / 2 / 2 / <none>` — both `xenforo-data` and `xenforo-backups`.

2. **Rehearse in the Docker flavor, against the real data.** This is the main reason flavor 1 exists, and it costs a few minutes if you skip what the migration cannot touch.

   **Skip `internal_data/`.** It was 855MB of a 1.0GB tree and holds attachments and caches the schema migration never reads. Tar the remainder in the pod and copy one file out, rather than `kubectl cp`-ing a directory:

   ```bash
   POD=$(kubectl -n xenforo get pod -l app=xenforo -o name)
   POD=${POD#pod/}
   kubectl -n xenforo exec "$POD" -c php-fpm -- \
     tar -czf /tmp/xf-code.tgz -C /var/www/html --exclude=./internal_data --exclude=./data .
   kubectl -n xenforo cp "$POD:/tmp/xf-code.tgz" ./xf-code.tgz -c php-fpm --retries=5
   gzip -t ./xf-code.tgz
   tar -xzf ./xf-code.tgz -C docker/xf
   mkdir -p docker/xf/data docker/xf/internal_data
   ```

   **`--retries` is load-bearing and the byte count is how you check it.** A first attempt without it died with `error: unexpected EOF`, and the dump copy below visibly resumed mid-file (`Resuming copy at 21573632 bytes, retry 1/5`). Compare the local size against the in-pod `ls -l` every time, then `gzip -t`.

   Restore the dump with MySQL's own `source`, which needs no shell pipeline:

   ```bash
   gunzip -k xenforo-<stamp>.sql.gz
   tail -5 xenforo-<stamp>.sql          # `-- Dump completed` must be present
   docker compose -f docker/compose.yaml up -d --wait db
   docker compose -f docker/compose.yaml cp xenforo-<stamp>.sql db:/tmp/dump.sql
   docker compose -f docker/compose.yaml exec db sh -c \
     'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u "$MYSQL_USER" "$MYSQL_DATABASE" -e "source /tmp/dump.sql"'
   ```

   **`--wait`, because `up -d` returns when the container is *started*, not when MySQL is accepting connections.** The `db` service declares a healthcheck precisely so something can wait on it; `--wait` is what consumes it. Without it the `cp` usually survives and the import races initialisation, which fails in a way that looks like a bad dump rather than a bad sequence.

   **Resolve the password inside the container, not on your command line.** `-e MYSQL_PWD="$XF_DB_PASSWORD"` expands in your shell, so the credential lands in the host's process arguments where any local process can read it from `ps`. The `db` container already holds `MYSQL_PASSWORD`, `MYSQL_USER` and `MYSQL_DATABASE` from compose, so single-quoting the `sh -c` body defers expansion to the container and nothing crosses the boundary. (The nightly CronJob goes one better with a `--defaults-extra-file`, keeping the password out of the *container's* argv too; that is worth the extra lines for a recurring job and not for a throwaway rehearsal, but it is the stronger form if you copy this pattern somewhere durable.)

   Address the stack by **compose file and service name**, never by container name. `docker-db-1` is a *generated* name: it is the project name plus the service plus an index, and the project name defaults to the containing directory — so it is `docker-db-1` only while you happen to be standing in `docker/`. Run the same `docker cp` from the component root, or under a `-p` flag, or alongside a second copy of the stack, and it addresses nothing or the wrong thing. `-f docker/compose.yaml` also lets every command in this runbook be pasted from one directory.

   **Rehearse on the pinned image, not a local build.** `docker compose build` takes ~25 minutes; tagging the digest the cluster actually runs takes seconds and is strictly better fidelity:

   ```bash
   docker pull ghcr.io/siliconsaga/xenforo-k8s@<digest-from-kustomization>
   docker tag  ghcr.io/siliconsaga/xenforo-k8s@<digest-from-kustomization> xenforo-k8s:local
   docker compose -f docker/compose.yaml up -d --no-build xenforo caddy
   ```

   Then unpack the release's `upload/` over `docker/xf/` and run the migration **inside that container**, which is the whole point of pinning it:

   ```bash
   docker compose -f docker/compose.yaml exec -w /var/www/html xenforo \
     php cmd.php xf:upgrade --no-interaction --skip-statistics
   ```

   A bare `php cmd.php` on the host runs whatever PHP the workstation has — a different version, without the image's extensions, and on macOS usually none at all. The rehearsal is only worth something if it runs on the same PHP the cluster will. Confirm the forum renders on `http://localhost:8080/` before going near the cluster.

   **Compare raw row counts, not the forum's own figures.** `xf_user`, `xf_post`, `xf_thread`, `xf_attachment` and `xf_template` must be identical across the migration. The rendered stat block is filtered and will not show you a loss — it reported 2,965 "Members" against 29,026 rows in `xf_user`, because the difference is unconfirmed and rejected registrations.

3. **Put the forum in maintenance mode** from the admin control panel, or accept errors during the migration. The window is short — both 2.3.13 migration steps finished in well under a minute on a 16.5k-post database — so for a forum that is not yet the public hostname this step is a judgement call rather than a requirement. Check what `kubectl -n xenforo get httproute` answers before deciding.

4. **Copy the new files in**, over the top of the existing tree. Release archives nest everything under `upload/`, so strip that level; and tar one file in rather than `cp`-ing a directory, which is both faster and far less likely to truncate:

   ```bash
   COPYFILE_DISABLE=1 tar -czf xf-new.tgz -C ./xenforo-2.3.y/upload .
   kubectl -n xenforo cp ./xf-new.tgz "$POD:/tmp/xf-new.tgz" -c php-fpm --retries=5
   kubectl -n xenforo exec "$POD" -c php-fpm -- ls -l /tmp/xf-new.tgz   # byte-compare
   kubectl -n xenforo exec "$POD" -c php-fpm -- gzip -t /tmp/xf-new.tgz
   kubectl -n xenforo exec "$POD" -c php-fpm -- tar -xzf /tmp/xf-new.tgz -C /var/www/html
   ```

   XenForo release archives are meant to be unpacked over an existing install. Do not delete the tree first — `internal_data/` and `data/` hold your attachments, and `src/config.php` is not in the archive, so an overlay leaves it alone. Confirm that last point rather than trust it; without `config.php` the forum cannot reach its database at all.

   ⚠ **Fix ownership afterwards — the tarball does not save you from this, it only moves it.** `kubectl cp` lands files as your *local* uid/gid, and `tar` run as root faithfully restores whatever uid/gid the archive recorded, so a tarball built on a workstation extracts as that workstation's user. After the 2.3.13 extract the tree read `502 wheel` with the setgid bit and group-write gone (`drwxr-xr-x` where it had been `drwxrwsr-x`). The forum still *served*, because `other` keeps read — which is exactly why this is easy to miss.

   **XenForo needs exactly three paths writable: `internal_data/`, `data/`, and `src/addons/`** (the last only to install add-ons through the ACP). Everything else is application code, and php-fpm runs as `www-data` — so group-write on the code means the process serving the forum can rewrite the code serving the forum. Restore the two sets separately, code first so the writable paths win where they nest under `src/`:

   ```bash
   # Application code: owned by root, readable by php-fpm, NOT writable by it.
   # The archive's own top level IS the list of what was just extracted, so
   # derive it rather than maintaining a copy that can drift.
   kubectl -n xenforo exec "$POD" -c php-fpm -- sh -c '
     set -eu
     cd /var/www/html
     CODE=$(tar -tzf /tmp/xf-new.tgz | sed -n "s|^\./\([^/][^/]*\)/\{0,1\}$|\1|p")
     chown -R root:www-data $CODE
     find $CODE -type d -exec chmod 755 {} +
     find $CODE -type f -exec chmod 644 {} +
   '

   # The three XenForo writes to. setgid so new files inherit the group.
   kubectl -n xenforo exec "$POD" -c php-fpm -- \
     chown -R www-data:www-data /var/www/html/internal_data /var/www/html/data /var/www/html/src/addons
   kubectl -n xenforo exec "$POD" -c php-fpm -- \
     find /var/www/html/internal_data /var/www/html/data /var/www/html/src/addons -type d -exec chmod 2775 {} +
   ```

   For 2.3.13 that derives 20 entries — `admin.php`, `cmd.php`, `connected_account.php`, `css.php`, `embed.php`, `htaccess.txt`, `index.php`, `install`, `job.php`, `js`, `library`, `oembed.php`, `payment_callback.php`, `proxy.php`, `service_worker.js`, `sitemap.php`, `src`, `styles`, `unfurl.php`, `webmanifest.php`.

   **Scope it to the release, not to the volume.** `chown -R root:www-data /var/www/html` is the tempting shortcut and it is wrong twice over: it walks the 855MB of `internal_data` for no reason, and it strips the setgid bit and resets file modes across every attachment before the three-path repair below puts *directories* back — file modes it never restores. Deriving the list from the tarball touches exactly what was written and nothing else, and it keeps working when a future XenForo adds a top-level directory that a hand-maintained list would silently miss.

   `config.php` needs no special case under this scheme — `644` falls out of the code rule, and it holds the database password, so that is where you want it. Under the older blanket `664` it had to be clawed back by hand, which is a good sign the blanket was wrong.

   ⚠ **This is stricter than what the live tree inherited.** As of 2026-11-04 the deployed forum carries `drwxrwsr-x root:www-data` on code — group-writable — because that is how the original install was seeded and the 2.3.13 upgrade faithfully restored it. The three writable paths were already correct and `www-data`-owned, so tightening the rest is a contained change rather than a redesign; it is listed here because the runbook should stop propagating the looser form, and applying it to the running forum is a deliberate step to take on its own, with a Velero snapshot in hand, not folded into an upgrade.

   `COPYFILE_DISABLE=1` is a macOS detail: without it `tar` embeds AppleDouble xattrs and busybox in the pod prints one `Ignoring unknown extended header keyword` line per file, burying any real error in thousands of lines of noise.

5. **Run the migration:**

   ```bash
   kubectl -n xenforo exec deploy/xenforo -c php-fpm -- \
     php /var/www/html/cmd.php xf:upgrade --no-interaction --skip-statistics
   ```

   It prints `Current version:` from the **database** and `Upgrade target:` from `src/XF.php`, which is the clearest confirmation that step 4 actually landed. Re-running it once the versions match is safe — it degrades to a template and phrase rebuild rather than re-applying steps.

6. **Restart** so opcache and the template cache are rebuilt cleanly:

   ```bash
   kubectl -n xenforo rollout restart deploy/xenforo
   kubectl -n xenforo rollout status deploy/xenforo --timeout=300s
   ```

   The `rollout status` is part of the step, not a flourish. `rollout restart` returns as soon as the Deployment is updated, and this Deployment is **`Recreate`** (a rolling update would try to attach the same RWO volume twice) — so for a few seconds the only pod in the namespace is `Terminating`, and shortly after that the only pod is `Pending`. Step 7 runs against whichever pod it finds.

7. **Refresh XenForo's CA bundle** — the upgrade just overwrote it with the release's snapshot:

   ```bash
   scripts/refresh-ca-bundle.sh --check   # expect exit 1, "stale: refresh needed"
   scripts/refresh-ca-bundle.sh
   ```

   ⚠ **Do not start this before the rollout above has settled.** `refresh-ca-bundle.sh` selects the first matching pod and `exec`s into it; against a `Terminating` or `Pending` pod that fails, and the failure reads as a broken script rather than a mistimed one. The script trusts its caller on this — it does not wait for readiness itself — so the `rollout status` in step 6 is what makes step 7 deterministic.

   This is not precautionary. Measured inside the 2.3.13 container on 2026-11-04, against the same host, in the same shell:

   | trust store | result |
   | --- | --- |
   | system store (patched image) | exit 60, `verify=20` — **rejected** |
   | `src/XF/Http/ca-bundle.crt` as shipped in 2.3.13 | exit 0, `verify=0`, `code=200` — **accepted** |

   The release archive still carries all four emSign roots (`Root CA - G1`, `ECC Root CA - G3`, `Root CA - C1`, `ECC Root CA - C3`). So a clean, fully patched image running an upgraded forum is still trusting the compromised chain on every outbound request XenForo makes, until this step runs.

8. **Merge the outdated templates** in the ACP. The upgrade reports them and they are not an error, but customised templates stay on the old version until someone merges them, and new features can misbehave until they do. For 2.3.13 it was three.

## XenForo's own CA bundle, and why step 7 is not optional

XenForo ships `src/XF/Http/ca-bundle.crt` and `XF\SubContainer\Http` hands it to Guzzle as the `verify` path, so **every outbound HTTP request XenForo makes validates against that file and ignores the container's system trust store.** Link previews, the image proxy fetching user-supplied URLs, add-on and licence checks, Akismet — all of it.

Three consequences worth internalising:

- **Upgrading `ca-certificates` in the image does not touch it.** The image's store covers PHP's own OpenSSL/curl defaults; XenForo's HTTP client never consults it.
- **Rebuilding the image does not touch it either**, because the forum tree lives on the PersistentVolume. The bundle is only as fresh as the release that unpacked it.
- **A XenForo upgrade resets it** to that release's snapshot, which is why the refresh is a numbered step above rather than a one-off.

This stopped being theoretical on 2026-10-20. The eMudhra CA compromise (CVE-2026-111943) put eight recoverable intermediate CA keys in circulation, and the shipped bundle still trusted `emSign ECC Root CA - G3`, the root they cross-sign up to. Verified against the live pod on 2026-10-26: XF's bundle accepted a chain built on a compromised intermediate, and so did the system store. Two stores, two fixes.

The two fixes have since landed at different times, which is what makes the split concrete rather than theoretical. Patching the image fixed the system store and left XenForo's untouched; upgrading XenForo reset its bundle back to a vulnerable snapshot without affecting the system store. Step 7 above records both halves measured in the same container, in opposite states, on 2026-11-04.

`scripts/refresh-ca-bundle.sh` installs the current [curl extract](https://curl.se/docs/caextract.html), which is what XenForo's own `ca-bundle-readme.txt` says to do, and regenerates `ca-bundle-legacy-openssl.crt` as bundle + `legacy-equifax.crt` (that variant exists so Google endpoints validate on OpenSSL older than 1.0.2).

It validates the candidate **in the pod before anything live is overwritten**, and still backs both files up and rolls them back if a later step fails — a trust store left half-refreshed is a store nobody has verified, and the failure stays silent until an outbound request needs it. Each bundle is proven two ways: both compromised test chains are rejected, **and** `xenforo.com` and `accounts.google.com` still validate, because a bundle that rejects everything would pass the first check alone.

Two negative-control hosts, not one, and they fail for different reasons. `dv-g3b-emudhra` serves an emSign chain, which dropping the emSign roots defeats. `dv-g3b-aaa-emudhra` is cross-signed up to Sectigo's legacy `AAA Certificate Services` root — a *legitimate* root, so where it is present no bundle refresh defeats that chain; only revocation checking or a library-level key denylist (Go 1.27.3's `crypto/x509`) does. It is absent from both the XenForo snapshot and the current curl extract, so both are rejected here. Measured on 2026-10-25:

| bundle | `dv-g3b-emudhra` | `dv-g3b-aaa-emudhra` |
| --- | --- | --- |
| XenForo's shipped snapshot | `200 verify=0` — **accepted** | rejected (`verify=20`) |
| current curl extract | rejected (`verify=20`) | rejected (`verify=20`) |

If a future extract re-adds the AAA root, expect that probe to start failing for a reason no refresh can fix. That is a real signal, not a broken script.

One more trap, and it bit: **`curl -f` is wrong for a TLS check.** `-f` fails on any HTTP error status, and `xenforo.com` answers a bare GET with `403` (Cloudflare bot-blocking) while verifying perfectly — `code=403 verify=0`. So the positive check aborted the run over a status that says nothing about TLS, and once rollback existed it would have reverted a *correct* bundle for that reason. Every probe now reads the exit code: `0` means the handshake completed, `60` means it was rejected, anything else means no verdict.

Rollback restores a **fresh per-run copy**, not the dated `.bak-$STAMP`. The dated copy is archival and never clobbered, so a same-day re-run cannot overwrite the genuine pre-change original with the copy the script just installed; the per-run copy is what "undo this attempt" actually means, and it is removed on success.

`scripts/refresh-ca-bundle.sh --check` reports without changing anything, so it suits a scheduled check. Exit codes are three-way on purpose: `0` clean, `1` stale, `2` no verdict. The last one matters — curl exits non-zero for DNS failure, blocked egress and timeouts just as it does for a rejected certificate, so collapsing those into "rejected" would report a vulnerable bundle as clean. Only exit 60 (`CURLE_PEER_FAILED_VERIFICATION`) counts as a rejection; alert on `2` as a problem with the probe, not with the bundle.

### The image's store needs a bump too

The other half is `image/Dockerfile`. Its trust-store `RUN` is deliberately the **last** layer: `apk --no-cache` tells apk not to keep an index, it tells BuildKit nothing, and CI exports a `type=gha,mode=max` cache — so higher up the file that layer would be served from cache on the weekly rebuild and never fetch a newer `ca-certificates`. Last, it can be invalidated cheaply instead of re-compiling every PHP extension under QEMU. CI passes a per-run `CA_REFRESH` and `pull: true`.

`ARG CA_CERTIFICATES_MIN` asserts a floor afterwards, because "we ran `apk upgrade`" is not evidence that a fix landed. **Bump it at the next distrust event** — it is currently `20261020-r0`.

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

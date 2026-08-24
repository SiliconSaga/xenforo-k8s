# `backup` — nightly database dumps

A CronJob that runs `mysqldump` at 03:20 daily into the `xenforo-backups` volume, keeps 14 days, and alerts if it stops.

```yaml
components:
  - ../../components/backup
```

## What this covers, and what it does not

| | Covered |
|---|---|
| Database (posts, users, permissions, settings) | **Yes** |
| Uploaded attachments and avatars (`data/`, `internal_data/attachments/`) | **No** |
| Survives loss of the cluster or the storage backend | **No** |

Both gaps are deliberate, and both matter. Read on before trusting this.

### Why not the files too

The forum tree is a **ReadWriteOnce** volume. A CronJob pod that mounts it can only be scheduled onto the node the forum pod is already on; anywhere else it sits `Pending` forever. A backup job that silently never runs is worse than no backup job, because the freshness alert would be the only thing that ever told you — so this component does not try.

Back the files up out of band instead:

```bash
POD=$(kubectl -n xenforo get pod -l app=xenforo -o name)
kubectl -n xenforo exec "${POD#pod/}" -c php-fpm -- \
  tar -cz -C /var/www/html data internal_data/attachments > xenforo-files-$(date +%F).tar.gz
```

If the forum ever accumulates attachments worth automating, the honest fixes are RWX storage (Longhorn supports it) or a Velero schedule with a volume snapshot — not a CronJob that gambles on co-scheduling.

### Why on-cluster is not enough

These dumps live on a PersistentVolume in the same cluster as the thing they are backing up. That covers the failure you will actually hit — a bad upgrade, a bad add-on, a deleted forum — and not the one that would hurt most: losing the cluster or the storage backend.

The house pattern for the off-cluster leg is KubicValheim's: a scheduled job uploads to object storage and exports an upload-age metric, so the alert means *"backups left the cluster"* rather than *"a dump was written"*. That leg is not built here yet. Until it is, copy a dump off the cluster periodically and know that you are doing it by hand.

## Restoring

```bash
kubectl -n xenforo exec -i deploy/xenforo-db -- \
  mysql -u xenforo -p"$(kubectl -n xenforo get secret xenforo-secrets -o jsonpath='{.data.db-password}' | base64 -d)" xenforo \
  < <(gunzip -c xenforo-2026-08-23T032000Z.sql.gz)
```

Then rebuild XenForo's caches, or the forum will serve stale templates against fresh data:

```bash
kubectl -n xenforo exec deploy/xenforo -c php-fpm -- php cmd.php xf:rebuild-caches
```

**A restore is not verified by the forum starting.** Log in and find a post you know should be there. A restore that quietly produced an empty-but-working forum looks identical to a successful one from the outside.

## Alerts

Shipped with this component rather than with `observability`, so they cannot exist in an overlay that has no backups:

- `XenForoBackupStale` — no successful run in 36h (one missed night).
- `XenForoBackupNeverRan` — `absent()` on the success metric. This catches what the staleness rule structurally cannot: if the CronJob has never once succeeded, the metric does not exist, the comparison is never evaluated, and a stale-backup alert would stay silent forever.

Both carry `watched: "true"`, which routes to a phone through heimdall's existing ntfy receiver. No Alertmanager change needed.

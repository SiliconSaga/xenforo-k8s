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

If the forum ever accumulates attachments worth automating, the honest fixes are RWX storage or a Velero schedule with a volume snapshot — not a CronJob that gambles on co-scheduling.

On RWX: Longhorn supports it on paper, but it was **retired from the homelab on 2026-08-26** having never successfully provisioned a volume there — and its validating webhook then wedged PVC admission cluster-wide, which is a worse failure than the gap it was meant to close. Whether it returns, or SeaweedFS replaces it, is open and tracked by nordri. Don't design around RWX yet. Velero is the nearer option — see below.

### Why on-cluster is not enough

These dumps live on a PersistentVolume in the same cluster as the thing they are backing up. That covers the failure you will actually hit — a bad upgrade, a bad add-on, a deleted forum — and not the one that would hurt most: losing the cluster or the storage backend.

There are two house answers, and they are complementary rather than alternatives.

**Velero** (nordri, GKE) takes cluster-wide backups to GCS with persistent-disk snapshots. It is the net for losing the cluster, the namespace, or the PV. It is *not* a database backup: a snapshot of a live MySQL volume is crash-consistent, not transaction-consistent, so it recovers like a power cut. The dumps this component produces remain the thing you actually restore a forum from — Velero's job is to make sure the volume holding them still exists.

**The KubicValheim upload pattern** is the per-app off-cluster leg: a scheduled job ships the artifact to object storage and touches a marker *only after a confirmed upload*, so the exported age metric means *"backups left the cluster"* rather than *"a dump was written"*. That distinction is not academic — the Valheim fleet ran for a long time with correct local backups, a correct alert, and nothing ever leaving the cluster.

That leg is not built here yet. Until it is, copy a dump off the cluster periodically and know that you are doing it by hand.

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

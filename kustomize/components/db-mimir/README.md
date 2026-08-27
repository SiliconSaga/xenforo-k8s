# `db-mimir` — database from mimir's Crossplane composition

Replaces [`db-throwaway`](../db-throwaway/README.md). Instead of running our own MySQL Deployment, this claims one from [mimir](https://github.com/SiliconSaga/mimir) and lets Crossplane and the Percona operator provision it.

> ## ⚠️ This is mimir's *older* vending path
>
> This component uses the Crossplane `MySQLInstance` claim, which provisions **a whole PXC cluster dedicated to this app**. Mimir's `docs/plans/2026-08-17-dataservice-vending-design.md` names that pattern as the thing it is replacing — *"Explicitly not wanted: a cluster per app. That is the current behaviour and it costs ~4 pods per consumer."*
>
> The intended successor is mimir's own **`DataService`** operator (`mimir.siliconsaga.org/v1alpha1`): one namespaced resource that asks for a database *inside a shared cluster*, with the operator creating the database, the user, the grants, and the Secret.
>
> **We are not on it yet because it cannot serve MySQL today.** The `engine` enum accepts `mysql`, but `operator/cmd/main.go` registers only `engine.NewRegistry(engine.Postgres{})` — there is no `mysql.go` in `internal/engine/` — and `shared/kustomization.yaml` contains only `postgres-cluster.yaml`, so there is no shared MySQL cluster to vend out of either. A `DataService` with `engine: mysql` would pass admission and then fail to reconcile.
>
> When both land, migrating means replacing `claim.yaml` with a `DataService`, deleting `job-db-init.yaml` (the operator does that work), and pointing `XF_DB_HOST` at the shared cluster's endpoint.
>
> **It is not only `XF_DB_HOST`, though** — verified by running the operator against this cluster on 2026-08-27. A `DataService` publishes its own Secret, named in `status.secretName`, with keys `host` / `port` / `database` / `username` / `password` / `uri`. This component instead reads `xenforo-secrets` with the single key `db-password`, and carries `XF_DB_USER` and `XF_DB_DATABASE` as literal env values. Those do not line up, so the swap needs a `db-dataservice` component that maps the published keys onto the env the pod expects — most of it via `secretKeyRef`, since `config.php` already resolves `XF_DB_PASSWORD_FILE` and the rest are plain values.
>
> Also worth knowing before wiring it: the operator **refuses** a `DataService` naming a database it did not create. A claim for `databaseName: xenforo` against the database this component's Job made reports `phase: Conflict` — "created outside the operator" — and leaves it untouched. That is the marker working, not a bug, but it means the migration is *new database plus a dump/restore*, never an in-place adoption.

```yaml
components:
  - ../../components/db-mimir
  # and REMOVE ../../components/db-throwaway — see "Mutually exclusive" below
```

## What it does

| File | Purpose |
|---|---|
| `claim.yaml` | A `MySQLInstance` claim — `replicas: 1`, 5Gi, MySQL 8.0 |
| `patch-db-host.yaml` | Points `XF_DB_HOST` at the composition's Service |
| `job-db-init.yaml` | Creates the `xenforo` database and user |

Nothing else in the pod spec changes. The password still arrives through `XF_DB_PASSWORD_FILE` from the same `xenforo-secrets` secret, so the secret plumbing is identical whichever database component you pick.

## Cluster prerequisites

The claim silently stays `SYNCED=False` forever if mimir isn't installed. Quick check:

```bash
kubectl get xrd                    # expect xmysqls.database.example.org
kubectl get providers.pkg.crossplane.io
kubectl get deploy -n percona      # expect pxc-operator
```

Needed: Crossplane, `provider-kubernetes`, `function-go-templating`, `function-auto-ready`, the Percona PXC operator, and mimir's `MySQLXRD.yaml` + `MySQLComp.yaml`. Mimir's `setup.sh` installs all of that plus Strimzi, Valkey and the PG/Mongo operators — for this component only the PXC operator is required, and skipping the other four saves roughly 600–800MB of idle memory.

## Why the init Job exists

The composition vends a PXC cluster with the operator's own users (`root`, `monitor`, `xtrabackup`, …) and **no application database**. Nothing upstream creates one, so XenForo would connect and find nothing. The Job closes that gap.

This is the gap the `DataService` operator exists to close properly — `CREATE DATABASE`, `CREATE USER`, `GRANT`, write the Secret — so this Job is a hand-rolled stand-in for the MySQL provisioner that has not been written yet. It should be deleted, not ported, once that lands.

It's idempotent (`CREATE ... IF NOT EXISTS`, `ALTER USER`) and annotated as an ArgoCD `PostSync` hook with `HookSucceeded` deletion, because a Job is immutable on re-apply and would otherwise fail every sync after a spec change. Under plain `kubectl` the annotations are inert.

The root password reaches it via `MYSQL_PWD` from the operator-generated secret so it never appears in `argv`.

## Mutually exclusive with `db-throwaway`

Enabling both leaves a stray MySQL Deployment running that nothing points at — it won't break the forum, it just quietly costs ~470MB. `kubectl get deploy -n <ns>` after switching; delete `xenforo-db` (Deployment, Service, and the `xenforo-db-data` PVC) if it's still there.

## `replicas: 1` is a real tradeoff

A genuine PXC cluster is three nodes with Galera replication. One node has no quorum and no redundancy — `wsrep_cluster_size` will read `1`. It works only because the composition sets `allowUnsafeConfigurations: true`.

That is the right call for a low-activity forum where [`../backup`](../backup/README.md) is the recovery story, and the wrong call the moment the forum matters enough to need availability. Raising `replicas` to 3 in `claim.yaml` is the whole change, but budget for it: three PXC nodes plus three HAProxy pods is roughly 4GB rather than 1.3GB.

## Migrating from `db-throwaway`

Nothing is seeded before XenForo is installed, so if you switch before running `xf:install` there is no migration — just swap the component. Afterwards, dump and restore as described in [`db-throwaway`](../db-throwaway/README.md), then switch.

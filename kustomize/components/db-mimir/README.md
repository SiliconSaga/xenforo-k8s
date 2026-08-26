# `db-mimir` — database from mimir's Crossplane composition

Replaces [`db-throwaway`](../db-throwaway/README.md). Instead of running our own MySQL Deployment, this claims one from [mimir](https://github.com/SiliconSaga/mimir) and lets Crossplane and the Percona operator provision it.

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

It's idempotent (`CREATE ... IF NOT EXISTS`, `ALTER USER`) and annotated as an ArgoCD `PostSync` hook with `HookSucceeded` deletion, because a Job is immutable on re-apply and would otherwise fail every sync after a spec change. Under plain `kubectl` the annotations are inert.

The root password reaches it via `MYSQL_PWD` from the operator-generated secret so it never appears in `argv`.

## Mutually exclusive with `db-throwaway`

Enabling both leaves a stray MySQL Deployment running that nothing points at — it won't break the forum, it just quietly costs ~470MB. `kubectl get deploy -n <ns>` after switching; delete `xenforo-db` (Deployment, Service, and the `xenforo-db-data` PVC) if it's still there.

## `replicas: 1` is a real tradeoff

A genuine PXC cluster is three nodes with Galera replication. One node has no quorum and no redundancy — `wsrep_cluster_size` will read `1`. It works only because the composition sets `allowUnsafeConfigurations: true`.

That is the right call for a low-activity forum where [`../backup`](../backup/README.md) is the recovery story, and the wrong call the moment the forum matters enough to need availability. Raising `replicas` to 3 in `claim.yaml` is the whole change, but budget for it: three PXC nodes plus three HAProxy pods is roughly 4GB rather than 1.3GB.

## Migrating from `db-throwaway`

Nothing is seeded before XenForo is installed, so if you switch before running `xf:install` there is no migration — just swap the component. Afterwards, dump and restore as described in [`db-throwaway`](../db-throwaway/README.md), then switch.

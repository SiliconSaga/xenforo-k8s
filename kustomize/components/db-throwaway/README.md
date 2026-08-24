# `db-throwaway` — disposable MySQL

A single-pod MySQL 8.4 with one ReadWriteOnce volume. It exists so the forum can run end to end **before** mimir vends a real database, and it is meant to be deleted.

## What it is not

- **Not replicated, not backed up, not monitored.** One pod, one volume. If the node dies you restore from whatever you dumped yourself.
- **Not tuned.** `innodb-buffer-pool-size=256M` is a starting point for a low-traffic forum, nothing more.
- **Not upgrade-safe.** Bumping the `mysql:` tag across a major version does an in-place data-directory upgrade with no rehearsal.

## Why MySQL and not MariaDB

XenForo's own Docker tooling ships MariaDB, and XenForo runs fine on it. This component uses MySQL anyway because the destination is a **mimir Percona MySQL claim**, and Percona Server is a MySQL fork — staying in the same engine family makes the cutover a `mysqldump` and a hostname change rather than a cross-engine migration. Nothing in `config.php` or the schema depends on either engine's dialect.

## Cutting over to mimir

When the claim exists:

1. `mysqldump` the throwaway database.
2. Restore into the claimed instance.
3. Drop `- ../../components/db-throwaway` from the overlay's `components:` list.
4. Patch `XF_DB_HOST` (and `XF_DB_PORT` if it differs) to the claim's Service.
5. Point `xenforo-secrets`' `db-password` at whatever the claim publishes — via `components/secrets-openbao` if the credential lands in OpenBAO.

Steps 3–5 are the entire k8s-side change, which is the point of keeping the database out of `base/`.

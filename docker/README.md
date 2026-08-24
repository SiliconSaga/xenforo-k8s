# Flavor 1 — plain Docker

For working on the forum without a Kubernetes cluster, and for rehearsing an upgrade before you do it for real.

```bash
cp .env.example .env
# edit .env — XF_DB_PASSWORD is required

mkdir -p xf
# unpack your licensed XenForo download into ./xf so ./xf/src/XF.php exists

docker compose up -d --build
```

Then open <http://localhost:8080> and run the installer. If you would rather install from the command line:

```bash
docker compose exec xenforo php cmd.php xf:install
```

`config.php` is mounted from `../image/config.php`, so the installer will not ask for database details — it already has them from the environment.

## Notes

- `./xf` is gitignored. It holds licensed XenForo source and must never be committed.
- The database lives in a named volume (`db`). `docker compose down -v` destroys it.
- This uses the same `image/Dockerfile`, `image/config.php`, and `image/caddy/Caddyfile` as the Kubernetes flavors, so a problem reproduced here is a real problem there.

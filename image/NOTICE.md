# Third-party notices

## XenForo CLI (`xenforo-ltd/cli`)

Portions of `Dockerfile`, `config.php`, and `caddy/Caddyfile` in this directory are adapted from XenForo Ltd.'s own container tooling, published at <https://github.com/xenforo-ltd/cli> under the MIT license (`internal/docker/embed/`).

Specifically:

| File here | Adapted from | What was taken |
|---|---|---|
| `Dockerfile` | `internal/docker/embed/Dockerfile` | The PHP extension set XenForo requires, and the virtual-package build/drop technique that keeps the runtime layer small |
| `config.php` | `internal/docker/embed/src/config.docker.php` | The `getenv_docker()` helper with its `<NAME>_FILE` indirection, the environment variable names, and the `config.override.php` seam |
| `caddy/Caddyfile` | `internal/docker/embed/.docker/caddy/Caddyfile` | The security headers, the `internal_data`/`src`/`cmd.php` deny rules, and the mutable/immutable cache-control split |

Changes made: the development-mode branches are removed, PHP is pinned to 8.4 rather than 8.5, imagick and redis are opt-in build args, php-fpm is configured to log to stdout/stderr, TLS and `auto_https` are disabled in favour of cluster ingress, and a separate metrics listener was added.

MIT license text: <https://github.com/xenforo-ltd/cli/blob/main/LICENSE>

## XenForo itself

XenForo forum software is **not** included in this repository or in any image it builds. It is commercial, license-restricted software; you must supply your own licensed copy. See [`../docs/licensing-and-ci.md`](../docs/licensing-and-ci.md).

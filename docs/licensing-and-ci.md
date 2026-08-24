# Licensing, and why CI does not build a forum image

## The constraint

XenForo is commercial software. The license permits you to run it; it does not permit you to redistribute the source. That rules out the obvious thing — a `COPY . .` in the Dockerfile and an image on a public registry — because the image layers *are* redistribution, and a public GHCR package is about as redistributed as it gets.

Every community XenForo Docker project hits this and lands in the same place: the image supplies the runtime, and you supply the source.

## What we do instead

Two halves, split along the license line:

| Half | Where it lives | Contains XF source? | Built by |
|---|---|---|---|
| PHP runtime + config + Caddyfile | `ghcr.io/siliconsaga/xenforo-k8s` | No | GitHub Actions, every push |
| The forum tree | the `xenforo-data` PersistentVolume | Yes | You, once, then upgraded in place |

The runtime image is genuinely public and genuinely rebuildable — no license, no credentials, no secrets beyond `GITHUB_TOKEN`. CI stays boring.

## Why the tree on a volume is the right answer anyway

This is not purely a licensing dodge. XenForo writes into its own tree at runtime:

- The admin control panel installs and upgrades add-ons by unpacking them into `src/addons/`.
- Templates and phrases compile into `internal_data/code_cache/`.
- Attachments and avatars land in `data/` and `internal_data/attachments/`.

An immutable baked image fights all three. You would end up either disabling the add-on installer or layering a writable overlay back on top — at which point you have the volume anyway, just with more moving parts. Baking the tree makes sense for a forum managed entirely through git; it does not for one where an admin installs an add-on through the control panel.

The tradeoff is real and worth naming: the running forum is not reproducible from this repository alone. What version of XenForo is deployed is a property of the volume, not of a git tag. `docs/upgrades.md` is how that stays under control.

## About the official XenForo CLI

XenForo publishes [`xenforo-ltd/cli`](https://github.com/xenforo-ltd/cli) (MIT) — a Go tool that provisions XenForo **development** environments with Docker Compose. Its `internal/docker/embed/` directory is where the extension list, `config.docker.php`, and Caddyfile in this repo came from; see [`../image/NOTICE.md`](../image/NOTICE.md).

It is worth knowing what it does *not* solve here.

`xf download --license <key>` fetches XenForo releases by license, which sounds exactly like what a CI job wants. But `xf` authenticates by OAuth against xenforo.com and stores the token **only** in the OS keychain — `internal/auth/keychain.go` has no environment-variable or file fallback, deliberately, and `RequireAuth()` fails closed when no keychain is available. A GitHub Actions runner has no keychain.

Three ways around it, if we ever want CI to fetch source:

1. **Seed a keyring in the runner.** Start `dbus`/`gnome-keyring-daemon` in the job, inject a refresh token from a repository secret into the `xf`/`oauth-token` entry, then run `xf download`. It works, but it puts a XenForo account credential in CI, and the token rotates.
2. **Fetch from our own storage.** Download the release once by hand, put the archive in a private bucket (Garage on the homelab, or a private GHCR OCI artifact), and have the job pull from there. Simplest, and the credential is ours rather than XenForo's.
3. **Don't.** Keep the tree on the volume and upgrade it with a Job. This is what we do today.

Option 3 costs nothing and needs no secrets, so it is where we start. Option 2 is the natural next step if we ever want a baked image for a reproducible deploy; option 1 is only worth it if XenForo adds non-interactive auth, which would be a reasonable thing to ask them for.

## Also worth knowing

`ghcr.io/xenforo-ltd/php-ci` exists — XenForo publishes it weekly from the same Dockerfile. It is the `ci` build target with the PHP **cli** variant, intended for add-on test suites, not an FPM runtime, and an anonymous `docker manifest inspect` came back `unauthorized`. It is not a base we can build on.

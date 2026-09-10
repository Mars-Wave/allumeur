# Packaging

Every distribution channel installs the same payload (the portable shell suite
plus one prebuilt static `allumeur-backend`) and reuses the same on-host setup so
there is a single source of truth for how the service is stood up:

- `common/pkg-setup.sh` runs `deploy/deploy.sh bootstrap` with package-safe flags
  (`--skip-prereqs --skip-tailscale --skip-cloudflared --skip-tests`). Runtime
  dependencies come from each package's declared deps, not from apt.
- `common/pkg-teardown.sh` stops the service and removes only what setup created.
  It never touches the encrypted data store or the TLS certs.

## Channels

| Channel | Files | Consumer command |
| --- | --- | --- |
| One-line script | `get.sh` | `curl -fsSL .../packaging/get.sh \| sh` |
| Debian / Ubuntu | `deb/build-deb.sh` | `sudo apt install ./allumeur_<v>_amd64.deb` |
| Arch (AUR) | `aur/PKGBUILD`, `aur/allumeur.install` | `paru -S allumeur` |
| Nix / NixOS | `../flake.nix`, `nix/module.nix` | `nix run github:Mars-Wave/allumeur` |

## Build locally

```sh
# Build the static musl binary once (matches deploy.sh):
docker run --rm -v "$PWD/backend":/src -w /src messense/rust-musl-cross:x86_64-musl cargo build --release
BIN=backend/target/x86_64-unknown-linux-musl/release/allumeur-backend

bash packaging/make-tarball.sh --binary="$BIN"          # dist/allumeur-x86_64-linux.tar.gz
bash packaging/deb/build-deb.sh --version=1.0.0 --binary="$BIN"   # dist/allumeur_1.0.0_amd64.deb
```

## Nix notes

PolyForm Noncommercial is not an OSI/FSF-free licence, so nixpkgs classifies the
package as `unfree`. Consumers must opt in:

```nix
{ nixpkgs.config.allowUnfree = true; }        # NixOS
```
```sh
NIXPKGS_ALLOW_UNFREE=1 nix run --impure github:Mars-Wave/allumeur   # ad-hoc
```

The NixOS module (`nixosModules.default`) runs the backend on :443 and generates
the cert + empty data store on first start. Validate it on a real NixOS host; CI
only evaluates it.

## CI / releasing

`.github/workflows/release.yml` runs on a `v*` tag: it builds the static binary,
assembles the tarball and the `.deb`, and (re)creates the GitHub Release with
both attached. The AUR job runs only when the `AUR_SSH_KEY` secret is present.

Accounts / secrets needed to publish everywhere:

- **GitHub Release + `.deb` + `get.sh`**: nothing extra (uses the built-in token).
- **AUR**: an [aur.archlinux.org](https://aur.archlinux.org) account with an SSH
  key, the `allumeur` package name registered, and the private key stored as the
  `AUR_SSH_KEY` repository secret.
- **Nix**: nothing to publish; users consume the flake from the public repo.

# Allumeur

[![Release](https://github.com/Mars-Wave/allumeur/actions/workflows/release.yml/badge.svg)](https://github.com/Mars-Wave/allumeur/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/Mars-Wave/allumeur)](https://github.com/Mars-Wave/allumeur/releases/latest)
![Platform: Linux](https://img.shields.io/badge/platform-Linux-FCC624?logo=linux&logoColor=black)
[![License: PolyForm Noncommercial](https://img.shields.io/badge/license-PolyForm%20Noncommercial-blue)](LICENSE.md)
[![Sponsor](https://img.shields.io/badge/sponsor-%E2%9D%A4-db61a2?logo=githubsponsors)](https://github.com/sponsors/Mars-Wave)

Ultra-light homelab control suite: wake/sleep machines, SSH key management, on-demand tunnels, and a tiny web UI on :443.

## Install

Debian / Ubuntu, one line (elevates with sudo as needed):

```sh
curl -fsSL https://raw.githubusercontent.com/Mars-Wave/allumeur/main/packaging/get.sh | sh
```

Or install the `.deb`:

```sh
curl -fLO https://github.com/Mars-Wave/allumeur/releases/download/v1.0.0/allumeur_1.0.0_amd64.deb
sudo apt install ./allumeur_1.0.0_amd64.deb
```

From a clone:

```sh
./install.sh this                              # install on this machine
./install.sh root@your-server.example.com      # deploy over ssh
```

NixOS: `nix run github:Mars-Wave/allumeur`, or import `nixosModules.default` (set `nixpkgs.config.allowUnfree = true`).

## Options

- `--domain=NAME` - cert domain; the UI is served at `https://<hostname>.<domain>`
- `--restore=PATH` - restore secrets + data from a backup tarball this suite produced
- `--binary=PATH` - install this prebuilt backend binary (skip building)
- `--build=local|here` - local-install build strategy when no `--binary` (default `local`)
- `--tailscale-up` - run `tailscale up` if not already connected
- `--skip-tailscale` - do not install / ensure tailscale
- `--skip-tests` - skip the pre-deploy bash test gate
- `--dry-run` - print actions, change nothing
- `-h`, `--help` - show usage

If the target user is not root, export `ALLUMEUR_SUDO_PASS` - it is fed transiently to `sudo -S`, never stored.

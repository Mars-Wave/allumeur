# NixOS module for Allumeur. Import via the flake:
#
#   inputs.allumeur.url = "github:Mars-Wave/allumeur";
#   ...
#   imports = [ inputs.allumeur.nixosModules.default ];
#   services.allumeur.enable = true;
#   services.allumeur.domain = "lan";   # web UI at https://<hostname>.lan
#
# The backend binds :443 directly and its API is UNAUTHENTICATED - keep the host
# on a LAN / tailnet only and never expose :443 to the internet.
#
# NOTE: validate on a real NixOS host. This module is evaluated in CI but its
# runtime behaviour (cert generation, the service on :443) needs a NixOS system.
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.allumeur;
  backend = self.packages.${pkgs.system}.allumeur-backend;

  # The web root, exposed at the path the backend is compiled to serve from.
  public = pkgs.runCommand "allumeur-public" { } ''
    mkdir -p $out
    cp -a ${../../public}/. $out/
  '';

  # The portable shell CLI, staged so it can populate ~/.allumeur-scripts.
  scripts = pkgs.runCommand "allumeur-scripts" { } ''
    mkdir -p $out
    cp -a ${../../scripts}/. $out/
  '';

  # Everything the shell tools and the backend shell out to at runtime. The
  # backend itself calls the openssl CLI to decrypt its data store, so openssl
  # MUST be present or the API returns empty results.
  runtimeDeps = with pkgs; [
    openssl openssh sshpass wakeonlan curl jq iputils
    ncurses util-linux gawk gnused coreutils
  ];

  # Thin PATH wrappers so 'nodes', 'tunnel', etc. work for the admin (root),
  # whose ~/.allumeur-scripts the service populates on start.
  mkCli = name: file: pkgs.writeShellScriptBin name ''
    export PATH=${lib.makeBinPath runtimeDeps}:$PATH
    exec "$HOME/.allumeur-scripts/${file}" "$@"
  '';
  cli = [
    (mkCli "nodes" "nodes.sh")
    (mkCli "tunnel" "tunnel.sh")
    (mkCli "keys" "keys.sh")
    (mkCli "subtitles" "subtitle-helper.sh")
  ];
in
{
  options.services.allumeur = {
    enable = lib.mkEnableOption "the Allumeur homelab control backend";
    package = lib.mkOption {
      type = lib.types.package;
      default = backend;
      description = "The allumeur-backend package to run.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "local";
      description = "Domain appended to the hostname for the self-signed cert CN (https://<hostname>.<domain>).";
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open TCP :443. Leave off unless the host is firewalled to a LAN/tailnet.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = cli;

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [ 443 ];
    };

    systemd.services.allumeur = {
      description = "Allumeur homelab control backend";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = runtimeDeps;
      serviceConfig = {
        Type = "simple";
        User = "root";
        WorkingDirectory = "/opt/allumeur";
        ExecStart = "${cfg.package}/bin/allumeur-backend";
        Restart = "always";
        LimitNOFILE = 10000;
        Environment = "HOME=/root";
      };
      preStart = ''
        set -e
        umask 077

        # Web root at the compiled-in path.
        mkdir -p /opt/allumeur
        ln -sfn ${public} /opt/allumeur/public

        # Self-signed cert (create-only; never overwrite an existing keypair).
        mkdir -p /opt/allumeur/certs
        if [ ! -e /opt/allumeur/certs/cert.pem ] && [ ! -e /opt/allumeur/certs/key.pem ]; then
          cn="$(hostname -s 2>/dev/null || echo localhost).${cfg.domain}"
          ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
            -keyout /opt/allumeur/certs/key.pem -out /opt/allumeur/certs/cert.pem \
            -subj "/CN=$cn" -addext "subjectAltName=DNS:$cn,DNS:localhost,IP:127.0.0.1"
          chmod 600 /opt/allumeur/certs/key.pem
          chmod 644 /opt/allumeur/certs/cert.pem
        fi

        # Empty encrypted data store + master key (create-only).
        store=/root/.allumeur-scripts/encrypted
        mkdir -p "$store"; chmod 700 "$store"
        [ -e "$store/.root_key" ] || { ${pkgs.openssl}/bin/openssl rand -base64 48 > "$store/.root_key"; chmod 600 "$store/.root_key"; }
        for blob in usr_blob.enc srv_blob.enc; do
          [ -e "$store/$blob" ] || { printf '' | ${pkgs.openssl}/bin/openssl enc -aes-256-cbc -salt -pbkdf2 -pass file:"$store/.root_key" -out "$store/$blob"; chmod 600 "$store/$blob"; }
        done
        [ -e "$store/allumeur-master-key" ] || ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -a 100 -f "$store/allumeur-master-key" -N "" -q -C "allumeur-master-key"

        # Make the CLI tools available to root at the path they source from.
        for f in nodes.sh tunnel.sh keys.sh lib.sh help.sh subtitle-helper.sh; do
          ln -sfn ${scripts}/$f /root/.allumeur-scripts/$f
        done
      '';
    };
  };
}

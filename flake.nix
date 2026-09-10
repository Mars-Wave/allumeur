{
  description = "Allumeur - ultra-light homelab control suite (static Rust backend + portable shell tools)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    in
    {
      # The backend engine, built from source. rustls + ring means no OpenSSL is
      # needed at build or run time.
      packages = forAllSystems (system: pkgs: rec {
        allumeur-backend = pkgs.rustPlatform.buildRustPackage {
          pname = "allumeur-backend";
          version = "1.0.0";
          src = ./backend;
          cargoLock.lockFile = ./backend/Cargo.lock;
          doCheck = false;
          meta = with pkgs.lib; {
            description = "Allumeur backend: tiny web UI + JSON API served over HTTPS on :443";
            homepage = "https://github.com/Mars-Wave/allumeur";
            # PolyForm Noncommercial is not an OSI/FSF-approved free licence.
            license = licenses.unfree;
            platforms = [ "x86_64-linux" ];
            mainProgram = "allumeur-backend";
          };
        };
        default = allumeur-backend;
      });

      apps = forAllSystems (system: pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${system}.allumeur-backend}/bin/allumeur-backend";
        };
      });

      # NixOS service module. See packaging/nix/module.nix for the options.
      nixosModules.default = import ./packaging/nix/module.nix self;
      nixosModules.allumeur = self.nixosModules.default;
    };
}

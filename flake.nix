{
  description = "NixOS options for the package: seaweedfs";

  nixConfig = {
    extra-substituters = [ "https://microvm.cachix.org" ];
    extra-trusted-public-keys = [ "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys=" ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
   in
      flake-utils.lib.eachSystem systems (system: {
        packages =
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in {
            build-seaweedfs-options = pkgs.callPackage ./pkgs/build-seaweedfs.nix { inherit self; };
            doc = pkgs.callPackage ./pkgs/doc.nix { inherit nixpkgs; };
            microvm = import ./pkgs/seaweedfs-command.nix {
              inherit pkgs;
            };
            # all compilation-heavy packages that shall be prebuilt for a binary cache
            prebuilt = pkgs.buildEnv {
              name = "prebuilt";
              paths = with self.packages.${system}; with pkgs; [
              seaweedfs
             ];
              pathsToLink = [ "/" ];
              extraOutputsToInstall = [ "dev" ];
              ignoreCollisions = true;
            };
         }
          # wrap self.nixosConfigurations in executable packages
          builtins.foldl' (result: systemName:
            let
              nixos = self.nixosConfigurations.${systemName};
              name = builtins.replaceStrings [ "${system}-" ] [ "" ] systemName;
           in
              if nixos.pkgs.system == system
              then result // {
                "${name}" = nixos.config.seaweedfs.runner;
              }
              else result
          ) {} (builtins.attrNames self.nixosConfigurations);

        # Takes too much memory in `nix flake show`
        # checks = import ./checks { inherit self nixpkgs system; };

        # hydraJobs are checks
        hydraJobs = builtins.mapAttrs (_: check:
          (nixpkgs.lib.recursiveUpdate check {
            meta.timeout = 12 * 60 * 60;
          })
        ) (import ./checks { inherit self nixpkgs system; });
      }) // {
        lib = import ./lib { nixpkgs-lib = nixpkgs.lib; };

        nixosModules = {
          seaweedfs = import ./nixos-modules/seaweedfs;
          host = import ./nixos-modules/host;
          # Just the generic microvm options
          seaweedfs-options = import ./nixos-modules/seaweedfs/options.nix;
        };

        defaultTemplate = self.templates.seaweedfs;
        templates.seaweedfs = {
          path = ./flake-template;
          description = "example Flake with distributed DB";
        };

        nixosConfigurations =
          let
          makeExample = { system, config ? {} }:
            nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.microvm
                ({ config, lib, ... }: {
                  system.stateVersion = config.system.nixos.version;

                  networking.hostName = "seaweedfs";
                  services.getty.autologinUser = "root";
                  networking.firewall.allowedTCPPorts = 22;
                  services.openssh = {
                    enable = true;
                    settings.PermitRootLogin = "yes";
                  };
                })
                config
              ];
            };
          in
            (builtins.foldl' (results: system:
              builtins.foldl' ({ result, n }: hypervisor: {
                result = result // {
                  "${system}-seaweedfs-example" = makeExample {
                    inherit system;
                  };
                } //
                nixpkgs.lib.optionalAttrs (builtins.elem hypervisor self.lib.hypervisorsWithNetwork) {
                  "${system}-seaweedfs-example-todo" = makeExample {
                    inherit system hypervisor;
                    config = { lib, ...}: {
                      networking.firewall.allowedTCPPorts = [ 22 ];
                      services.openssh = {
                        enable = true;
                        settings.PermitRootLogin = "yes";
                      };
                    };
                  };
                };
                n = n + 1;
              }) results self.lib.hypervisors
            ) { result = {}; n = 1; } systems).result;
      };
}
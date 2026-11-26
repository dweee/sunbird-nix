{
  description = "Phoenix desktop for Nix, with the Sunbird loader on x86-64 Linux";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux"; # Sunbird loader for the Linux package
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true; # Phoenix and the Sunbird loader are unfree binaries
      };
      sources = builtins.fromJSON (builtins.readFile ./sources.json);
      darwinSystem = "aarch64-darwin";
      darwinPkgs = import nixpkgs {
        system = darwinSystem;
        config.allowUnfree = true;
      };
    in
    {
      packages.${system} = rec {
        phoenix = pkgs.callPackage ./pkgs/phoenix.nix { inherit sources; };
        sunbird-loader = pkgs.callPackage ./pkgs/sunbird-loader.nix { inherit sources; };
        sunbird = pkgs.callPackage ./pkgs/sunbird.nix { inherit phoenix sunbird-loader; };
        sunbird-mutable = sunbird.override { loaderMode = "mutable"; };
        default = sunbird;
      };

      packages.${darwinSystem}.phoenix = darwinPkgs.callPackage ./pkgs/phoenix-darwin.nix {
        source = builtins.fromJSON (builtins.readFile ./sources-darwin.json);
      };

      apps.${darwinSystem}.phoenix = {
        type = "app";
        program = "${self.packages.${darwinSystem}.phoenix}/bin/phoenix";
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${self.packages.${system}.sunbird}/bin/sunbird";
        };
        gate-only = {
          type = "app";
          program = "${self.packages.${system}.sunbird}/bin/sunbird-gate-only";
        };
        phoenix = {
          type = "app";
          program = "${self.packages.${system}.phoenix}/bin/phoenix";
        };
      };

      overlays.default = final: prev: {
        inherit (self.packages.${system})
          phoenix
          sunbird-loader
          sunbird
          sunbird-mutable
          ;
      };

      nixosModules.default =
        { config, lib, ... }:
        let
          cfg = config.programs.sunbird;
        in
        {
          options.programs.sunbird = {
            enable = lib.mkEnableOption "Phoenix with the Sunbird loader";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${system}.sunbird;
              description = "Sunbird package (set to phoenix for the plain client).";
            };
          };
          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ cfg.package ];
            # Stop the client from registering its bare binary as the discord:// handler
            # (see pkgs/sunbird.nix): put our entry at that path in every user's home.
            systemd.user.tmpfiles.rules = [
              "L+ %h/.local/share/applications/${cfg.package.urlHandler} - - - - ${cfg.package}/share/applications/${cfg.package.urlHandler}"
            ];
          };
        };

      homeManagerModules.default =
        { config, lib, ... }:
        let
          cfg = config.programs.sunbird;
        in
        {
          options.programs.sunbird = {
            enable = lib.mkEnableOption "Phoenix with the Sunbird loader";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${system}.sunbird;
              defaultText = lib.literalExpression "inputs.phoenix.packages.x86_64-linux.sunbird";
              description = "Sunbird package (sunbird-mutable for a self-updating loader, phoenix for the plain client).";
            };
            defaultLinkHandler = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Open discord:// links with Sunbird. Needs xdg.mimeApps.enable, which makes
                Home Manager manage ~/.config/mimeapps.list.
              '';
            };
          };
          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];
            # Stop the client from registering its bare binary as the discord:// handler
            # (see pkgs/sunbird.nix). force: replaces the copy the client already wrote.
            xdg.dataFile."applications/${cfg.package.urlHandler}" = {
              source = "${cfg.package}/share/applications/${cfg.package.urlHandler}";
              force = true;
            };
            xdg.mimeApps.defaultApplications = lib.mkIf cfg.defaultLinkHandler {
              "x-scheme-handler/discord" = [ "sunbird.desktop" ];
            };
            assertions = [
              {
                assertion = cfg.defaultLinkHandler -> config.xdg.mimeApps.enable;
                message = "programs.sunbird.defaultLinkHandler needs xdg.mimeApps.enable = true.";
              }
            ];
          };
        };
      homeModules.default = self.homeManagerModules.default; # newer HM naming

      formatter.${system} = pkgs.nixfmt;
    };
}

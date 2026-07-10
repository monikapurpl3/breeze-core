{
  description = "Breeze Core — self-hosted, LAN-first control for Midea air conditioners";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      commit = if (self ? shortRev) then self.shortRev else "dirty";
    in
    {
      packages = forAll (pkgs:
        let
          py = pkgs.python312;
          pyPkgs = py.pkgs;

          # Deps not in nixpkgs — built from PyPI sdists.
          msmart-ng = pyPkgs.buildPythonPackage rec {
            pname = "msmart-ng";
            version = "2026.7.0";
            pyproject = true;
            src = pyPkgs.fetchPypi {
              pname = "msmart_ng";
              inherit version;
              hash = "sha256-cx/K63Uz1QJkqGmMmMalf6tGcINkc4yPFP6sGFg3P1k=";
            };
            build-system = [ pyPkgs.setuptools pyPkgs.setuptools-scm ];
            dependencies = [ pyPkgs.httpx pyPkgs.pycryptodome ];
            doCheck = false;
          };

          brotli-asgi = pyPkgs.buildPythonPackage rec {
            pname = "brotli-asgi";
            version = "1.6.0";
            pyproject = true;
            src = pyPkgs.fetchPypi {
              pname = "brotli_asgi";
              inherit version;
              hash = "sha256-+Zhdmeywgs9eZ0hqWMJ7fzmy076NnRPDirwSMoztzpo=";
            };
            build-system = [ pyPkgs.setuptools ];
            dependencies = [ pyPkgs.starlette pyPkgs.brotli ];
            doCheck = false;
          };

          pyEnv = py.withPackages (ps: [
            ps.fastapi ps.uvicorn ps.uvloop ps.httptools ps.websockets
            msmart-ng brotli-asgi
          ]);

          breeze-core = pkgs.stdenv.mkDerivation {
            pname = "breeze-core";
            version = "2.5.0";
            src = self;
            dontBuild = true;
            installPhase = ''
              mkdir -p $out/opt/breeze-core $out/bin
              cp -r meow_ac static setup_device.py $out/opt/breeze-core/
              cp packaging/binary/launcher.py $out/opt/breeze-core/
              echo "${commit}" > $out/opt/breeze-core/meow_ac/_commit.txt

              cat > $out/bin/breeze-core <<EOF
              #!${pkgs.runtimeShell}
              export PYTHONPATH=$out/opt/breeze-core\''${PYTHONPATH:+:\$PYTHONPATH}
              exec ${pyEnv}/bin/python $out/opt/breeze-core/launcher.py "\$@"
              EOF
              chmod 755 $out/bin/breeze-core
            '';
            meta = with pkgs.lib; {
              description = "Self-hosted, LAN-first control for Midea air conditioners";
              homepage = "https://github.com/monikapurpl3/breeze-core";
              license = licenses.agpl3Plus;
              mainProgram = "breeze-core";
              platforms = platforms.linux;
            };
          };
        in
        {
          default = breeze-core;
          breeze-core = breeze-core;
        });

      nixosModules.breeze-core = { config, lib, pkgs, ... }:
        let cfg = config.services.breeze-core; in
        {
          options.services.breeze-core = {
            enable = lib.mkEnableOption "Breeze Core";
            host = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1";
              description = "Bind address — a LAN IP for direct use, 127.0.0.1 behind a proxy. Never 0.0.0.0.";
            };
            port = lib.mkOption { type = lib.types.port; default = 8420; };
            behindProxy = lib.mkOption { type = lib.types.bool; default = false; };
            openFirewall = lib.mkOption { type = lib.types.bool; default = false; };
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.breeze-core;
            };
          };

          config = lib.mkIf cfg.enable {
            users.users.breeze = {
              isSystemUser = true;
              group = "breeze";
              home = "/etc/breeze-core";
            };
            users.groups.breeze = { };
            systemd.tmpfiles.rules = [ "d /etc/breeze-core 0750 breeze breeze -" ];

            systemd.services.breeze-core = {
              description = "Breeze Core - self-hosted Midea AC control";
              wantedBy = [ "multi-user.target" ];
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              environment = {
                AC_CONFIG = "/etc/breeze-core/config.json";
                AC_DEVICES = "/etc/breeze-core/devices.json";
                AC_PROGRAMS = "/etc/breeze-core/programs.json";
              };
              serviceConfig = {
                ExecStart = "${cfg.package}/bin/breeze-core serve --host ${cfg.host} --port ${toString cfg.port}"
                  + lib.optionalString cfg.behindProxy " --behind-proxy";
                User = "breeze";
                Group = "breeze";
                Restart = "on-failure";
                RestartSec = 5;
                # Same sandbox posture as the packaged systemd unit.
                NoNewPrivileges = true;
                ProtectSystem = "strict";
                ProtectHome = true;
                ReadWritePaths = [ "/etc/breeze-core" ];
                PrivateTmp = true;
                ProtectKernelTunables = true;
                ProtectKernelModules = true;
                ProtectControlGroups = true;
                RestrictSUIDSGID = true;
                RestrictRealtime = true;
                RestrictAddressFamilies = "AF_INET AF_INET6 AF_UNIX";
                RemoveIPC = true;
                SystemCallFilter = "@system-service";
                SystemCallArchitectures = "native";
                CapabilityBoundingSet = "";
                LockPersonality = true;
              };
            };

            networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
          };
        };
    };
}

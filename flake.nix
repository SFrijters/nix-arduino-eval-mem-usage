{
  description = "Demonstrate memory usage spike for newer Arduino packages";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    arduino-nix.url = "github:bouk/arduino-nix";
    arduino-indexes = {
      url = "github:bouk/arduino-indexes";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      arduino-nix,
      arduino-indexes,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      # Boilerplate to make the rest of the flake more readable
      # Do not inject system into these attributes
      flatAttrs = [
        "overlays"
        "nixosModules"
      ];
      # Inject a system attribute if the attribute is not one of the above
      injectSystem =
        system:
        lib.mapAttrs (name: value: if builtins.elem name flatAttrs then value else { ${system} = value; });
      # Combine the above for a list of 'systems'
      forSystems =
        systems: f:
        lib.attrsets.foldlAttrs (
          acc: system: value:
          lib.attrsets.recursiveUpdate acc (injectSystem system value)
        ) { } (lib.genAttrs systems f);
    in
    forSystems [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        overlays = [
          arduino-nix.overlay
          # https://downloads.arduino.cc/packages/package_index.json
          (arduino-nix.mkArduinoPackageOverlay "${arduino-indexes}/index/package_index.json")
          # https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json
          (arduino-nix.mkArduinoPackageOverlay "${arduino-indexes}/index/package_esp32_index.json")
          # https://downloads.arduino.cc/libraries/library_index.json
          (arduino-nix.mkArduinoLibraryOverlay "${arduino-indexes}/index/library_index.json")
        ];

        pkgs = import nixpkgs {
          inherit overlays system;
        };

        nix = pkgs.nixVersions.nix_2_30;

        generate-flamegraph-app = pkgs.writeShellApplication {
          name = "generate-flamegraph";

          runtimeInputs = [ nix pkgs.flamegraph ];

          text = ''
            WORKDIR=$(mktemp -d /tmp/nix-fun-calls-XXXXX)
            nix eval --trace-function-calls --raw "$1" >"$WORKDIR/nix-function-calls.trace" 2>&1
            ${nix.src}/contrib/stack-collapse.py "$WORKDIR/nix-function-calls.trace" > "$WORKDIR/nix-function-calls.folded"
            flamegraph.pl "$WORKDIR/nix-function-calls.folded" > "$WORKDIR/nix-function-calls.svg"
            echo "$WORKDIR/nix-function-calls.svg"
          '';
        };

        time-app = pkgs.writeShellApplication {
          name = "run-with-time";

          runtimeInputs = [ nix pkgs.time ];

          text = ''
            command time -v nix eval --trace-function-calls --raw "$1"
          '';
        };

      in
      {
        packages = {
          # Works fine, nix memory usage in the order of hundreds of megabytes
          esp-3_1 = pkgs.wrapArduinoCLI {
            packages = [
              pkgs.arduinoPackages.platforms.esp32.esp32."3.1.3"
            ];
          };
          # Memory usage during eval balloons to several gigabytes
          esp-3_2 = pkgs.wrapArduinoCLI {
            packages = [
              pkgs.arduinoPackages.platforms.esp32.esp32."3.2.0"
            ];
          };
        };

        apps = rec {
          default = generate-flamegraph;
          generate-flamegraph = {
            type = "app";
            program = "${lib.getExe generate-flamegraph-app}";
          };
          speedscope = {
            type = "app";
            program = "${lib.getExe pkgs.speedscope}";
          };
          time = {
            type = "app";
            program = "${lib.getExe time-app}";
          };
        };

        formatter = pkgs.nixfmt-tree;
      }
    );
}

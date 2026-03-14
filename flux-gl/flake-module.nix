{ inputs, ... }: {
  perSystem = { config, lib, pkgs, system, ... }:
    let
      inherit (inputs) crane;
      inherit (pkgs) stdenv stdenvNoCC;

      pkgsCross = import inputs.nixpkgs {
      inherit system;
      crossSystem.config = "x86_64-w64-mingw32";
      overlays = [ (import inputs.rust-overlay) ];
      };
      rustToolchainWindows = pkgsCross.pkgsBuildHost.rust-bin.stable.latest.default.override {
      targets = [ "x86_64-pc-windows-gnu" ];
      };
      craneLibWindows = (inputs.crane.mkLib pkgsCross).overrideToolchain rustToolchainWindows;

      src = ../.;

      rustExtensions = [
        "cargo"
        "rust-src"
        "rust-analyzer"
        "rustfmt"
      ];

      rustToolchain = pkgs.rust-bin.stable.latest.default.override {
        extensions = rustExtensions;
        targets = [ "wasm32-unknown-unknown" ];
      };

      craneLib = (crane.mkLib pkgs).overrideScope (final: prev: {
        rustc = rustToolchain;
        cargo = rustToolchain;
        rustfmt = rustToolchain;
      });

      crateNameFromCargoToml = packagePath:
        craneLib.crateNameFromCargoToml {
          cargoToml = lib.path.append packagePath "Cargo.toml";
        };
    in {
    packages = {
      flux-gl = craneLib.buildPackage {
        inherit (crateNameFromCargoToml ./flux) version;
        pname = "flux-gl";
        inherit src;
        cargoExtraArgs = "-p flux-gl";
        doCheck = true;
      };

      flux-gl-windows = craneLibWindows.buildRustPackage {
        inherit (config.packages.flux-gl)  # reuse same src/cargoToml/etc.
          src cargoToml cargoLock;

        CARGO_BUILD_TARGET = "x86_64-pc-windows-gnu";
        depsBuildBuild = [ pkgsCross.pkgsBuildHost.stdenv.cc ];
        CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS =
          "-L native=${pkgsCross.windows.pthreads}/lib";

        # disable tests — can't run Windows binaries on Linux
        doCheck = false;
      };

      flux-gl-desktop-wrapped =
        let
          runtimeLibraries = with pkgs; [
            wayland
            wayland-protocols
            libxkbcommon
            xorg.libX11
            xorg.libXcursor
            xorg.libXrandr
            xorg.libXi
            libGL
          ];
        in
          # Can’t use symlinkJoin because of the hooks are passed to the
          # dependency-only build.
          stdenvNoCC.mkDerivation {
            name = "flux-gl-desktop-wrapped";
            inherit (config.packages.flux-gl-desktop) version;
            nativeBuildInputs = [pkgs.makeWrapper];
            buildCommand = ''
              mkdir -p $out/bin
              cp ${config.packages.flux-gl-desktop}/bin/flux-desktop $out/bin
              wrapProgram $out/bin/flux-desktop \
                --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath runtimeLibraries}
            '';
            passthru.unwrapped = config.packages.flux-gl-desktop;
          };

      flux-gl-desktop = craneLib.buildPackage {
        inherit (crateNameFromCargoToml ./flux-desktop) version;
        pname = "flux-gl-desktop";
        inherit src;
        release = true;
        cargoExtraArgs = "-p flux-gl-desktop";
        doCheck = true;
      };

      flux-gl-wasm = craneLib.buildPackage {
        pname = "flux-gl-wasm";
        src = lib.cleanSourceWith {
          inherit src;
          filter = path: type:
            (lib.hasSuffix "\.vert" path) ||
            (lib.hasSuffix "\.frag" path) ||
            (craneLib.filterCargoSources path type);
        };
        cargoExtraArgs = "--package flux-gl-wasm";
        CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
        doCheck = false;
      };
    };
  };
}

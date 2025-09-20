{
  description = "ZMP dev shell and package with Android SDK via android-nixpkgs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    android-nixpkgs.url = "github:tadfisher/android-nixpkgs";
  };

  outputs = { self, nixpkgs, android-nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
      perSystem = f: forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          sysimg = sdkPkgs:
            if pkgs.stdenv.hostPlatform.isAarch64 then
              sdkPkgs.system-images-android-34-google-apis-arm64-v8a
            else
              sdkPkgs.system-images-android-34-google-apis-x86_64;
          androidSdk = android-nixpkgs.sdk.${system} (sdkPkgs: with sdkPkgs; [
            cmdline-tools-latest
            platform-tools
            platforms-android-34
            build-tools-34-0-0
            emulator
            (sysimg sdkPkgs)
          ]);
          androidHome = "${androidSdk}/libexec/android-sdk";
          baseRuntimeInputs = [
            pkgs.bashInteractive
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnused
            pkgs.gnugrep
            pkgs.util-linux
            pkgs.which
            pkgs.zig
            pkgs.jdk17
            pkgs.gradle
            pkgs.bun
            pkgs.zip
            pkgs.unzip
            androidSdk
          ];
          mkCiScript = pkgs.writeShellApplication {
            name = "zmp-ci";
            runtimeInputs = baseRuntimeInputs;
            text = ''
              set -euo pipefail
              export ANDROID_HOME=${androidHome}
              export ANDROID_SDK_ROOT=${androidHome}
              export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/emulator:$PATH"
              export IN_NIX_SHELL=1
              scripts/test-e2e.sh "$@"
            '';
          };
          ciTools = pkgs.symlinkJoin {
            name = "zmp-ci-tools";
            paths = [ pkgs.unzip pkgs.zip pkgs.android-tools ];
          };
        in f { inherit pkgs androidSdk androidHome mkCiScript ciTools; }
      );

    in {

      packages = perSystem ({ pkgs, mkCiScript, ciTools, ... }:
        let
          zmpPackage = pkgs.stdenvNoCC.mkDerivation {
            pname = "zmp";
            version = "0.0.1";
            src = ./.;
            nativeBuildInputs = [ pkgs.zig ];
            buildPhase = ''
              zig build -Doptimize=ReleaseSafe
            '';
            installPhase = ''
              mkdir -p $out/bin
              cp zig-out/bin/zmp $out/bin/
            '';
          };
        in {
          zmp = zmpPackage;
          "ci-tools" = ciTools;
          default = zmpPackage;
        }
      );

      apps = perSystem ({ mkCiScript, ... }:
        let
          ciApp = {
            type = "app";
            program = "${mkCiScript}/bin/zmp-ci";
          };
        in {
          ci = ciApp;
          default = ciApp;
        }
      );

      devShells = perSystem ({ pkgs, androidSdk, androidHome, ... }: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig
            pkgs.jdk17
            pkgs.gradle
            pkgs.bun
            pkgs.zip
            pkgs.unzip
            androidSdk
          ];
          ANDROID_HOME = androidHome;
          ANDROID_SDK_ROOT = androidHome;
          shellHook = ''
            export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/emulator:$PATH"
            if [ -d "$ANDROID_SDK_ROOT/ndk" ]; then
              export ANDROID_NDK_ROOT="$(echo "$ANDROID_SDK_ROOT"/ndk/* | awk '{print $1}')"
            fi
            echo "ZMP dev shell ready."
            (adb version >/dev/null 2>&1 && echo "- adb: $(adb version 2>/dev/null | head -n1)") || echo "- adb: missing"
            (avdmanager --help >/dev/null 2>&1 && echo "- avdmanager: ok") || echo "- avdmanager: missing"
            (emulator -version >/dev/null 2>&1 && echo "- emulator: ok") || echo "- emulator: missing"
            echo "- Java: $(java -version 2>&1 | head -n1)"
          '';
        };
      });
    };
}

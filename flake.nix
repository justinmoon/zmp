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
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          zmp = pkgs.stdenvNoCC.mkDerivation {
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
          default = self.packages.${system}.zmp;
        }
      );

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          # Choose an emulator system image appropriate for host arch
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
            ndk-26-1
          ]);
        in {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig
              pkgs.jdk17
              pkgs.gradle
              androidSdk
            ];
            ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
            ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
            shellHook = ''
              # Add Android tools to PATH (adb, avdmanager, emulator)
              export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/emulator:$PATH"
              # Best-effort ANDROID_NDK_ROOT export (resolve the single installed NDK)
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
        }
      );
    };
}

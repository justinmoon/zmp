set shell := ["/usr/bin/env", "bash", "-c"]
set positional-arguments := true

default:
    @just --list

run-host:
    @nix run .#ci -- --mode host --skip-ui-tests {{justargs}}

run-native:
    @nix run .#ci -- --mode native --skip-ui-tests {{justargs}}

ci-host:
    @nix run .#ci -- --mode host {{justargs}}

ci-native:
    @nix run .#ci -- --mode native {{justargs}}

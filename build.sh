#!/usr/bin/env bash
set -euo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.17.0}"

zvm run "$ZIG_VERSION" build \
    -Dtarget=wasm32-wasi \
    -Dcpu=lime1+atomics \
    -Ddev=full \
    -Dstrip=true \
    -Dflat=true \
    -Dversion-string="$ZIG_VERSION" \
    --prefix dist \
    "$@"

wat dist/zig.wasm

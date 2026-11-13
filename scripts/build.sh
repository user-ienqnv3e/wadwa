#!/usr/bin/env bash
# Builds the genuine binary place file WildFeastIslands.rbxl:
#   1. Rojo compiles the source tree into a binary place (build/base.rbxl)
#   2. Lune bakes the procedural archipelago into Workspace
#   3. Lune reopens the result and verifies it
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
rojo build default.project.json -o build/base.rbxl
lune run scripts/bake.luau build/base.rbxl WildFeastIslands.rbxl
lune run scripts/verify-place.luau WildFeastIslands.rbxl

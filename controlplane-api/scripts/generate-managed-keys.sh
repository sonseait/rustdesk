#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec cargo run --quiet --manifest-path "$script_dir/../Cargo.toml" \
  -p control-plane-api --bin generate_managed_keys

#!/usr/bin/env bash
set -eu
if [ "$(uname -s)" != Darwin ]; then
  printf '%s\n' 'macOS releases require a native macOS host.' >&2
  exit 2
fi
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec "${CXV_PYTHON:-python3}" "$script_dir/native_release.py" macos

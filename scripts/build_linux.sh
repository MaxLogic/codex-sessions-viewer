#!/usr/bin/env bash
set -eu
if [ "$(uname -s)" != Linux ]; then
  printf '%s\n' 'Linux releases require a native Linux host.' >&2
  exit 2
fi
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec "${CXV_PYTHON:-python3}" "$script_dir/native_release.py" linux

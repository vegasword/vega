#!/usr/bin/env sh
set -e
cd "$(dirname "$0")"

odin build . -out:vega -o:speed
./vega --install-desktop || true
echo "built vega"

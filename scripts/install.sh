#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d build/Murmur.app ] || scripts/build.sh
mkdir -p ~/Applications
rm -rf ~/Applications/Murmur.app
cp -R build/Murmur.app ~/Applications/Murmur.app
echo "Installed ~/Applications/Murmur.app"

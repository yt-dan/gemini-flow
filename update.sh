#!/bin/bash
# Update GeminiFlow to the latest version from GitHub, rebuild, and restart it.
# Your API key, permissions and settings are kept.
set -euo pipefail
cd "$(dirname "$0")"
echo "==> Downloading the latest version"
git pull --ff-only
echo "==> Rebuilding and restarting"
exec ./install.sh "$@"

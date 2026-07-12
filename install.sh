#!/usr/bin/env bash
# Torlamp — installer launcher. Just run:  bash install.sh
# Thin wrapper that delegates to the real guided installer in media-server/.
here="$(cd "$(dirname "$0")" && pwd)"
exec bash "$here/media-server/install.sh" "$@"

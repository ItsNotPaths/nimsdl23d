#!/usr/bin/env bash
# Fetches third-party source deps into vendor/.
# Run this once before building.
set -euo pipefail

VENDOR="$(cd "$(dirname "$0")" && pwd)/vendor"

SDL2_VERSION="2.30.11"

fetch() {
    local name="$1"
    local url="$2"
    local dest="$3"

    if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
        echo "  already present: $(basename "$dest")"
        return
    fi

    echo "  downloading $name..."
    mkdir -p "$dest"
    curl -fsSL "$url" | tar xz --strip-components=1 -C "$dest"
    echo "  done."
}

echo "==> SDL2 $SDL2_VERSION"
fetch "SDL2" \
    "https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-${SDL2_VERSION}.tar.gz" \
    "$VENDOR/sdl2"

echo ""
echo "All deps ready. You can now run ./docker-build/build.sh."

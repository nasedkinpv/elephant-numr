#!/bin/bash
set -e

VERSION="2.19.1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
SRC_DIR="$BUILD_DIR/elephant-${VERSION}"

# Install location (system by default, user with --user)
if [ "$1" = "--user" ]; then
    INSTALL_BIN="$HOME/.local/bin"
    INSTALL_LIB="$HOME/.local/lib/elephant"
    SUDO=""
else
    INSTALL_BIN="/usr/bin"
    INSTALL_LIB="/usr/lib/elephant"
    SUDO="sudo"
fi

# Stop elephant before build
echo "Stopping elephant..."
if [ -n "$SUDO_USER" ]; then
    SUDO_UID=$(id -u "$SUDO_USER")
    sudo -u "$SUDO_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SUDO_UID/bus" XDG_RUNTIME_DIR="/run/user/$SUDO_UID" systemctl --user stop elephant 2>/dev/null || true
fi
pkill -9 elephant 2>/dev/null || true
pkill -9 walker 2>/dev/null || true
# Kill anything using the binary
fuser -k /usr/bin/elephant 2>/dev/null || true
sleep 2

# Use system Go
export GOROOT=/usr/lib/go
export PATH=$GOROOT/bin:$PATH

echo "=== Building elephant + numr provider ==="
echo "Go: $(go version)"
echo "Install: $INSTALL_BIN, $INSTALL_LIB"
echo ""

# Download source if needed
if [ ! -d "$SRC_DIR" ]; then
    echo "Downloading elephant source..."
    mkdir -p "$BUILD_DIR"
    curl -sL "https://github.com/abenz1267/elephant/archive/refs/tags/v${VERSION}.tar.gz" | tar xz -C "$BUILD_DIR"
fi

cd "$SRC_DIR"

# Build elephant binary
echo "Building elephant..."
cd cmd/elephant
go build -buildvcs=false -trimpath -o elephant
cd ../..

# Build providers
PROVIDERS="bluetooth calc clipboard desktopapplications files menus providerlist runner symbols todo unicode websearch"
mkdir -p "$BUILD_DIR/plugins"

for p in $PROVIDERS; do
    echo "Building $p..."
    cd "$SRC_DIR/internal/providers/$p"
    go build -buildvcs=false -buildmode=plugin -trimpath -o "$BUILD_DIR/plugins/$p.so"
done

# Build numr (copy source into elephant tree first)
echo "Building numr..."
mkdir -p "$SRC_DIR/internal/providers/numr"
cp "$SCRIPT_DIR/setup.go" "$SRC_DIR/internal/providers/numr/"
cp "$SCRIPT_DIR/README.md" "$SRC_DIR/internal/providers/numr/"
cd "$SRC_DIR/internal/providers/numr"
go build -buildvcs=false -buildmode=plugin -trimpath -o "$BUILD_DIR/plugins/numr.so"

# Install
echo ""
echo "Installing..."
$SUDO mkdir -p "$INSTALL_BIN" "$INSTALL_LIB"
$SUDO cp "$SRC_DIR/cmd/elephant/elephant" "$INSTALL_BIN/"
$SUDO cp "$BUILD_DIR/plugins/"*.so "$INSTALL_LIB/"

# Install numr theme files to system location
NUMR_SHARE="/usr/share/elephant/numr"
$SUDO mkdir -p "$NUMR_SHARE"
$SUDO cp "$SCRIPT_DIR/numr.css" "$NUMR_SHARE/"
$SUDO cp "$SCRIPT_DIR/item_numr.xml" "$NUMR_SHARE/"
$SUDO chmod 644 "$NUMR_SHARE/numr.css" "$NUMR_SHARE/item_numr.xml"
echo "Theme files: $NUMR_SHARE/"

echo ""
echo "=== Done ==="
echo "Binary: $INSTALL_BIN/elephant"
echo "Plugins: $INSTALL_LIB/*.so"

# Start elephant (run as user, not root)
echo ""
echo "Starting elephant..."
if [ -n "$SUDO_USER" ]; then
    SUDO_UID=$(id -u "$SUDO_USER")
    sudo -u "$SUDO_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SUDO_UID/bus" XDG_RUNTIME_DIR="/run/user/$SUDO_UID" systemctl --user start elephant
else
    systemctl --user start elephant
fi
sleep 1

echo "Ready! Press SUPER+SPACE to test."

# Configure Walker for numr actions
echo ""
echo "Configuring Walker..."
"$SCRIPT_DIR/configure-walker.sh"

# Configure Walker theme
echo ""
"$SCRIPT_DIR/configure-theme.sh"

# Sync AUR package sources (as user, not root)
if [ -d "$SCRIPT_DIR/aur" ]; then
    echo ""
    echo "Syncing AUR sources..."
    if [ -n "$SUDO_USER" ]; then
        sudo -u "$SUDO_USER" cp "$SCRIPT_DIR/setup.go" "$SCRIPT_DIR/numr.css" "$SCRIPT_DIR/item_numr.xml" "$SCRIPT_DIR/README.md" \
           "$SCRIPT_DIR/configure-walker.sh" "$SCRIPT_DIR/configure-theme.sh" "$SCRIPT_DIR/aur/"
    else
        cp "$SCRIPT_DIR/setup.go" "$SCRIPT_DIR/numr.css" "$SCRIPT_DIR/item_numr.xml" "$SCRIPT_DIR/README.md" \
           "$SCRIPT_DIR/configure-walker.sh" "$SCRIPT_DIR/configure-theme.sh" "$SCRIPT_DIR/aur/"
    fi
fi

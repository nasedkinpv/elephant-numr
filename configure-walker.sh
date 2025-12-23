#!/bin/bash
# Configure Walker for numr provider

# Handle sudo: use actual user's home, not root's
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    USER_HOME="$HOME"
fi

WALKER_CONFIG="$USER_HOME/.config/walker/config.toml"

if [ ! -f "$WALKER_CONFIG" ]; then
    echo "Walker config not found at $WALKER_CONFIG"
    exit 1
fi

# Check if numr is already configured
if grep -q 'numr = \[' "$WALKER_CONFIG"; then
    echo "numr already configured in Walker config"
    exit 0
fi

# Create backup
BACKUP="${WALKER_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
cp "$WALKER_CONFIG" "$BACKUP"
echo "Backup created: $BACKUP"

NUMR_CONFIG='numr = [
  { action = "copy", default = true },
  { action = "refresh", label = "refresh rates", bind = "ctrl r", after = "AsyncReload" },
  { action = "append", label = "save to numr", bind = "shift Return" }
]'

# Check if [providers.actions] section exists
if grep -q '\[providers.actions\]' "$WALKER_CONFIG"; then
    # Create temp file with numr config inserted after [providers.actions]
    awk -v cfg="$NUMR_CONFIG" '
        /\[providers.actions\]/ { print; print cfg; next }
        { print }
    ' "$WALKER_CONFIG" > "${WALKER_CONFIG}.tmp"
    mv "${WALKER_CONFIG}.tmp" "$WALKER_CONFIG"
else
    # Append new section at end
    echo "" >> "$WALKER_CONFIG"
    echo "[providers.actions]" >> "$WALKER_CONFIG"
    echo "$NUMR_CONFIG" >> "$WALKER_CONFIG"
fi

echo "Walker configured for numr"
echo "Restart Walker: systemctl --user restart elephant"

#!/bin/bash
# Configure Walker theme for numr provider

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Handle sudo: use actual user's home, not root's
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    USER_HOME="$HOME"
fi

WALKER_THEMES="$USER_HOME/.config/walker/themes"
WALKER_CONFIG="$USER_HOME/.config/walker/config.toml"

# Use system location if installed, otherwise dev location
NUMR_SHARE="/usr/share/elephant/numr"
if [ -f "$NUMR_SHARE/numr.css" ]; then
    NUMR_FILES="$NUMR_SHARE"
else
    NUMR_FILES="$SCRIPT_DIR"
fi

# Detect active theme from config
ACTIVE_THEME=""
if [ -f "$WALKER_CONFIG" ]; then
    ACTIVE_THEME=$(grep -E '^theme\s*=' "$WALKER_CONFIG" | sed 's/.*=\s*"\([^"]*\)".*/\1/' | head -1)
fi

if [ -z "$ACTIVE_THEME" ]; then
    ACTIVE_THEME="custom"
fi

THEME_DIR="$WALKER_THEMES/$ACTIVE_THEME"

echo "Configuring Walker theme: $ACTIVE_THEME"

# Create theme directory if needed
mkdir -p "$THEME_DIR"

# Symlink item_numr.xml
if [ -L "$THEME_DIR/item_numr.xml" ] || [ ! -e "$THEME_DIR/item_numr.xml" ]; then
    ln -sf "$NUMR_FILES/item_numr.xml" "$THEME_DIR/item_numr.xml"
    echo "  Linked item_numr.xml → $NUMR_FILES/"
else
    echo "  item_numr.xml exists (not a symlink, skipping)"
fi

# Handle CSS
NUMR_CSS_PATH="$NUMR_FILES/numr.css"
STYLE_CSS="$THEME_DIR/style.css"
IMPORT_LINE="@import url(\"$NUMR_CSS_PATH\");"

if [ -f "$STYLE_CSS" ]; then
    # Create backup before modifying
    BACKUP="${STYLE_CSS}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$STYLE_CSS" "$BACKUP"
    echo "  Backup created: $BACKUP"
    # Remove any existing embedded numr styles (entire CSS blocks)
    if grep -q "\.numr-\|\.currency\|\.unit\|\.percentage\|\.number" "$STYLE_CSS"; then
        echo "  Removing embedded numr styles..."
        # Use awk to remove CSS blocks containing numr/type classes
        awk '
            /^[.a-z].*\{/ { block = $0; in_block = 1; next }
            in_block && /\}/ {
                if (block !~ /numr|\.currency|\.unit|\.percentage|\.number/) {
                    print block
                    print
                }
                in_block = 0
                next
            }
            in_block { block = block "\n" $0; next }
            /@import/ { print; next }
            /^[[:space:]]*$/ { next }
            { print }
        ' "$STYLE_CSS" > "${STYLE_CSS}.tmp"
        mv "${STYLE_CSS}.tmp" "$STYLE_CSS"
    fi

    # Check if already imported
    if grep -q "numr.css" "$STYLE_CSS"; then
        echo "  numr.css already imported"
    else
        # Add import after other imports
        if grep -q "@import" "$STYLE_CSS"; then
            # Insert after last @import line
            awk -v imp="$IMPORT_LINE" '
                /@import/ { last_import = NR; lines[NR] = $0; next }
                { lines[NR] = $0 }
                END {
                    for (i = 1; i <= NR; i++) {
                        print lines[i]
                        if (i == last_import) print imp
                    }
                }
            ' "$STYLE_CSS" > "${STYLE_CSS}.tmp"
            mv "${STYLE_CSS}.tmp" "$STYLE_CSS"
        else
            # No imports, add at beginning
            echo -e "$IMPORT_LINE\n$(cat "$STYLE_CSS")" > "$STYLE_CSS"
        fi
        echo "  Added numr.css import"
    fi
else
    # Create new style.css
    echo "$IMPORT_LINE" > "$STYLE_CSS"
    echo "  Created style.css"
fi

echo "Theme configured!"

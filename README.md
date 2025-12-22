# elephant-numr

[numr](https://github.com/nasedkinpv/numr) calculator provider for [Walker/Elephant](https://github.com/abenz1267/walker) launcher.

## Install

### Arch Linux (AUR)

```bash
yay -S elephant-numr
```

### Manual

```bash
git clone https://github.com/nasedkinpv/elephant-numr
cd elephant-numr
sudo ./build.sh
```

## Config

`~/.config/elephant/numr.toml`:

```toml
min_chars = 2
require_number = true
command = "wl-copy -n %VALUE%"
```

## Keybindings

| Action | Key | Description |
|--------|-----|-------------|
| Copy | Enter | Copy result to clipboard |
| Refresh | Ctrl+R | Fetch fresh exchange rates |

Press `Alt+J` for actions menu.

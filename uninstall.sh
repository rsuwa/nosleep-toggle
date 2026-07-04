#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
extension_uuid="nosleep-toggle@systemd-inhibit.local"

remove_owned_link() {
  local link="$1"
  local target="$2"

  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
    rm "$link"
    printf 'Removed %s\n' "$link"
  fi
}

if command -v nosleep >/dev/null 2>&1; then
  nosleep off >/dev/null 2>&1 || true
fi

if command -v gnome-extensions >/dev/null 2>&1; then
  gnome-extensions disable "$extension_uuid" >/dev/null 2>&1 || true
fi

remove_owned_link "$HOME/.local/bin/nosleep" "$repo_root/bin/nosleep"
remove_owned_link "$HOME/.local/share/gnome-shell/extensions/$extension_uuid" "$repo_root/extension"

printf 'Uninstalled nosleep-toggle links. Source repo remains at %s\n' "$repo_root"

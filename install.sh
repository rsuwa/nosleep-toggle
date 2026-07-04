#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="$HOME/.local/bin"
extension_root="$HOME/.local/share/gnome-shell/extensions"
extension_uuid="nosleep-toggle@suwa.local"

link_path() {
  local target="$1"
  local link="$2"

  mkdir -p "$(dirname "$link")"

  if [[ -L "$link" ]]; then
    if [[ "$(readlink "$link")" == "$target" ]]; then
      return 0
    fi
    rm "$link"
  elif [[ -e "$link" ]]; then
    local backup="${link}.bak.$(date +%Y%m%d%H%M%S)"
    mv "$link" "$backup"
    printf 'Backed up %s to %s\n' "$link" "$backup"
  fi

  ln -s "$target" "$link"
}

chmod +x "$repo_root/bin/nosleep" "$repo_root/bin/nosleepctl"

mkdir -p "$bin_dir" "$extension_root"
link_path "$repo_root/bin/nosleep" "$bin_dir/nosleep"
link_path "$repo_root/bin/nosleepctl" "$bin_dir/nosleepctl"
link_path "$repo_root/gnome-shell/extensions/$extension_uuid" "$extension_root/$extension_uuid"

if command -v gnome-extensions >/dev/null 2>&1; then
  gnome-extensions enable "$extension_uuid" >/dev/null 2>&1 || true
fi

printf 'Installed nosleep-toggle from %s\n' "$repo_root"
printf 'If the top-bar toggle does not appear, log out and log back in.\n'

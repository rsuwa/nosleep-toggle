#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
extension_uuid="nosleep-toggle@systemd-inhibit.local"
installed_cli="$HOME/.local/bin/nosleep"
installed_extension="$HOME/.local/share/gnome-shell/extensions/$extension_uuid"
cli_target="$repo_root/bin/nosleep"
extension_target="$repo_root/extension"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  printf 'Do not run uninstall.sh as root. Run it as your desktop user.\n' >&2
  exit 1
fi

remove_owned_link() {
  local link="$1"
  local target="$2"

  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
    rm "$link"
    printf 'Removed %s\n' "$link"
  fi
}

if [[ -L "$installed_cli" && "$(readlink "$installed_cli")" == "$cli_target" ]]; then
  "$installed_cli" off >/dev/null 2>&1 || true
fi

if command -v gnome-extensions >/dev/null 2>&1; then
  if ! disable_output="$(gnome-extensions disable "$extension_uuid" 2>&1)"; then
    printf 'Warning: could not disable GNOME extension %s.\n' "$extension_uuid" >&2
    if [[ -n "$disable_output" ]]; then
      printf '%s\n' "$disable_output" >&2
    fi
  fi
fi

remove_owned_link "$installed_cli" "$cli_target"
remove_owned_link "$installed_extension" "$extension_target"

printf 'Uninstalled nosleep-toggle links. Source repo remains at %s\n' "$repo_root"

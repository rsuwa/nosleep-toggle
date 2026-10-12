#!/bin/bash
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
extension_uuid="nosleep-toggle@systemd-inhibit.local"
installed_cli="$HOME/.local/bin/nosleep"
installed_extension="$HOME/.local/share/gnome-shell/extensions/$extension_uuid"
cli_target="$repo_root/bin/nosleep"
# Every extension variant install.sh can link from this checkout: keep the
# directory names in sync with it.
extension_targets=("$repo_root/extension" "$repo_root/extension-legacy")
gnome_extensions_cmd="${NOSLEEP_GNOME_EXTENSIONS_CMD:-}"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  printf 'Do not run uninstall.sh as root. Run it as your desktop user.\n' >&2
  exit 1
fi

if [[ -z "$gnome_extensions_cmd" ]] && command -v gnome-extensions >/dev/null 2>&1; then
  gnome_extensions_cmd="$(command -v gnome-extensions)"
fi

# link_points_to_any LINK TARGET...
# Ownership is an exact match of the link text, so links into other checkouts
# and foreign links never count as owned.
link_points_to_any() {
  local link="$1"
  local current target

  shift
  [[ -L "$link" ]] || return 1
  current="$(readlink "$link")"
  for target in "$@"; do
    if [[ "$current" == "$target" ]]; then
      return 0
    fi
  done
  return 1
}

remove_owned_link() {
  local link="$1"

  shift
  if link_points_to_any "$link" "$@"; then
    rm "$link"
    printf 'Removed %s\n' "$link"
  fi
}

installed_cli_owned() {
  link_points_to_any "$installed_cli" "$cli_target"
}

installed_extension_owned() {
  link_points_to_any "$installed_extension" "${extension_targets[@]}"
}

if installed_cli_owned && [[ -x "$cli_target" ]]; then
  if ! stop_output="$("$cli_target" off 2>&1)"; then
    printf 'Warning: could not turn persistent NoSleep off.\n' >&2
    if [[ -n "$stop_output" ]]; then
      printf '%s\n' "$stop_output" >&2
    fi
    exit 1
  fi
fi

if installed_extension_owned && [[ -n "$gnome_extensions_cmd" ]]; then
  if ! disable_output="$("$gnome_extensions_cmd" disable "$extension_uuid" 2>&1)"; then
    printf 'Warning: could not disable GNOME extension %s.\n' "$extension_uuid" >&2
    if [[ -n "$disable_output" ]]; then
      printf '%s\n' "$disable_output" >&2
    fi
  fi
fi

remove_owned_link "$installed_cli" "$cli_target"
remove_owned_link "$installed_extension" "${extension_targets[@]}"

printf 'Uninstalled nosleep-toggle links. Source repo remains at %s\n' "$repo_root"

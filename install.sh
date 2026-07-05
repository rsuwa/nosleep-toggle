#!/bin/bash
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="$HOME/.local/bin"
extension_root="$HOME/.local/share/gnome-shell/extensions"
extension_uuid="nosleep-toggle@systemd-inhibit.local"
gnome_extensions_cmd="${NOSLEEP_GNOME_EXTENSIONS_CMD:-}"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  printf 'Do not run install.sh as root. Run it as your desktop user.\n' >&2
  exit 1
fi

for command in systemd-inhibit flock setsid; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command" >&2
    exit 1
  fi
done

if [[ -z "$gnome_extensions_cmd" ]] && command -v gnome-extensions >/dev/null 2>&1; then
  gnome_extensions_cmd="$(command -v gnome-extensions)"
fi

backup_path() {
  local link="$1"
  local backup_dir backup

  backup_dir="$(mktemp -d "${link}.bak.$(date +%Y%m%d%H%M%S).XXXXXX")"
  backup="$backup_dir/$(basename "$link")"

  mv "$link" "$backup"
  printf 'Backed up %s to %s\n' "$link" "$backup"
}

link_path() {
  local target="$1"
  local link="$2"

  mkdir -p "$(dirname "$link")"

  if [[ -L "$link" ]]; then
    if [[ "$(readlink "$link")" == "$target" ]]; then
      return 0
    fi
    backup_path "$link"
  elif [[ -e "$link" ]]; then
    backup_path "$link"
  fi

  ln -s "$target" "$link"
}

chmod +x "$repo_root/bin/nosleep"

mkdir -p "$bin_dir" "$extension_root"
link_path "$repo_root/bin/nosleep" "$bin_dir/nosleep"
link_path "$repo_root/extension" "$extension_root/$extension_uuid"

if [[ -n "$gnome_extensions_cmd" ]]; then
  if ! enable_output="$("$gnome_extensions_cmd" enable "$extension_uuid" 2>&1)"; then
    printf 'Warning: could not enable GNOME extension %s.\n' "$extension_uuid" >&2
    if [[ -n "$enable_output" ]]; then
      printf '%s\n' "$enable_output" >&2
    fi
    printf 'Try: gnome-extensions enable %s\n' "$extension_uuid" >&2
  fi
fi

printf 'Installed nosleep-toggle from %s\n' "$repo_root"
printf 'If the top-bar toggle does not appear, log out and log back in.\n'

#!/bin/bash
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="$HOME/.local/bin"
extension_root="$HOME/.local/share/gnome-shell/extensions"
extension_uuid="nosleep-toggle@systemd-inhibit.local"
extension_link="$extension_root/$extension_uuid"
# GNOME Shell 45 and newer load extension.js as an ES module; older releases
# load it as a legacy script. uninstall.sh owns links to both directories:
# keep the directory names in sync with it.
extension_module_dir="$repo_root/extension"
extension_legacy_dir="$repo_root/extension-legacy"
first_module_shell_major=45

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

# Prints how to invoke an optional command, or nothing when it is unavailable.
resolve_optional_command() {
  command -v "$1" 2>/dev/null || true
}

gnome_extensions_cmd="$(resolve_optional_command "${NOSLEEP_GNOME_EXTENSIONS_CMD:-gnome-extensions}")"
gnome_shell_cmd="$(resolve_optional_command "${NOSLEEP_GNOME_SHELL_CMD:-gnome-shell}")"

# Prints the major version of the installed GNOME Shell, for example 42 or 46.
# Only stdout is parsed because gnome-shell can print warnings on stderr.
detect_gnome_shell_major() {
  local output

  [[ -n "$gnome_shell_cmd" ]] || return 1
  output="$(LC_ALL=C "$gnome_shell_cmd" --version 2>/dev/null)" || return 1
  output="${output%%$'\n'*}"
  [[ "$output" =~ ^GNOME\ Shell\ ([0-9]{1,4})(\.|$) ]] || return 1
  printf '%s\n' "$((10#${BASH_REMATCH[1]}))"
}

metadata_lists_shell_major() {
  local metadata="$1"
  local major="$2"

  tr -d '[:space:]' <"$metadata" |
    grep -E "\"shell-version\":\\[[^]]*\"${major}\"" >/dev/null
}

backup_path() {
  local link="$1"
  local backup_dir backup

  backup_dir="$(mktemp -d "${link}.bak.$(date +%Y%m%d%H%M%S).XXXXXX")"
  backup="$backup_dir/$(basename "$link")"

  mv "$link" "$backup"
  printf 'Backed up %s to %s\n' "$link" "$backup"
}

# link_path TARGET LINK [OTHER_OWNED_TARGET...]
# Points LINK at TARGET. A link to another target owned by this checkout is
# switched in place; anything else in the way is backed up as foreign.
link_path() {
  local target="$1"
  local link="$2"
  local current owned

  shift 2
  mkdir -p "$(dirname "$link")"

  if [[ -L "$link" ]]; then
    current="$(readlink "$link")"
    if [[ "$current" == "$target" ]]; then
      return 0
    fi
    for owned in "$@"; do
      if [[ "$current" == "$owned" ]]; then
        rm "$link"
        ln -s "$target" "$link"
        printf 'Switched %s from %s to %s\n' "$link" "$current" "$target"
        return 0
      fi
    done
    backup_path "$link"
  elif [[ -e "$link" ]]; then
    backup_path "$link"
  fi

  ln -s "$target" "$link"
}

# Decide the extension variant before creating any link.
extension_target=""
if shell_major="$(detect_gnome_shell_major)"; then
  if ((shell_major >= first_module_shell_major)); then
    extension_target="$extension_module_dir"
  else
    extension_target="$extension_legacy_dir"
  fi

  if [[ ! -f "$extension_target/metadata.json" ]]; then
    printf 'Missing extension files for GNOME Shell %s: %s\n' "$shell_major" "$extension_target" >&2
    exit 1
  fi

  if ! metadata_lists_shell_major "$extension_target/metadata.json" "$shell_major"; then
    printf 'Warning: GNOME Shell %s is not a supported version. The extension is linked anyway, but GNOME Shell may report it as out of date.\n' "$shell_major" >&2
  fi
else
  printf 'Warning: could not determine the GNOME Shell version, so the top-bar extension link was not created or changed.\n' >&2
  printf 'Install GNOME Shell, or set NOSLEEP_GNOME_SHELL_CMD to a command whose --version prints "GNOME Shell <version>", then run ./install.sh again.\n' >&2
fi

chmod +x "$repo_root/bin/nosleep"
link_path "$repo_root/bin/nosleep" "$bin_dir/nosleep"

if [[ -z "$extension_target" ]]; then
  printf 'Installed the nosleep CLI from %s (GNOME extension skipped)\n' "$repo_root"
  exit 0
fi

previous_extension_target=""
if [[ -L "$extension_link" ]]; then
  previous_extension_target="$(readlink "$extension_link")"
fi
link_path "$extension_target" "$extension_link" "$extension_module_dir" "$extension_legacy_dir"

extension_enabled=0
if [[ -z "$gnome_extensions_cmd" ]]; then
  printf 'Warning: gnome-extensions was not found, so GNOME extension %s was not enabled.\n' "$extension_uuid" >&2
elif enable_output="$("$gnome_extensions_cmd" enable "$extension_uuid" 2>&1)"; then
  extension_enabled=1
else
  printf 'Warning: could not enable GNOME extension %s yet.\n' "$extension_uuid" >&2
  if [[ -n "$enable_output" ]]; then
    printf '%s\n' "$enable_output" >&2
  fi
fi

printf 'Installed nosleep-toggle from %s\n' "$repo_root"
printf 'Extension variant for GNOME Shell %s: %s\n' "$shell_major" "$extension_target"

# GNOME Shell scans extension directories only when it starts. An enable call
# for an extension the running Shell has not scanned fails without recording
# anything, so it has to be repeated after the restart.
restart_how='log out and log back in (on an X11 session you can press Alt+F2, type r, and press Enter instead)'
if [[ "$extension_enabled" -eq 0 ]]; then
  printf 'GNOME Shell only picks up a new or changed extension when it starts. To finish, do both steps in this order:\n'
  printf '  1. Restart GNOME Shell: %s.\n' "$restart_how"
  if [[ -n "$gnome_extensions_cmd" ]]; then
    printf '  2. Then run: gnome-extensions enable %s (or run ./install.sh again).\n' "$extension_uuid"
  else
    printf '  2. Then enable the extension, for example in the Extensions app or with: gnome-extensions enable %s\n' "$extension_uuid"
  fi
elif [[ "$previous_extension_target" != "$extension_target" ]]; then
  printf 'GNOME Shell only picks up a new or changed extension when it starts.\n'
  printf 'Restart GNOME Shell to finish: %s.\n' "$restart_how"
fi

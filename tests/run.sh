#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dirs=()
run_pids=()
blocker_pids=()

make_tmp_dir() {
  local dir
  dir="$(mktemp -d)"
  tmp_dirs+=("$dir")
  printf '%s\n' "$dir"
}

cleanup() {
  local pid dir

  set +e
  for pid in "${run_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done

  for pid in "${blocker_pids[@]}"; do
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  done

  for dir in "${tmp_dirs[@]}"; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

test_syntax() {
  bash -n "$repo_root/bin/nosleep" "$repo_root/install.sh" "$repo_root/uninstall.sh"
}

# ESLint 9 (pinned in package-lock.json) needs Node.js ^18.18.0 || ^20.9.0 || >=21.1.0.
node_supports_eslint() {
  local version="$1"
  local major minor

  [[ "$version" =~ ^v([0-9]+)\.([0-9]+)\. ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"

  ((major == 18 && minor >= 18)) || ((major == 20 && minor >= 9)) ||
    ((major == 21 && minor >= 1)) || ((major >= 22))
}

test_js_lint() {
  local node_version version

  # A wrong boundary would only skip the lint below, so check the helper first; this needs no Node.js.
  for version in v18.18.0 v18.19.1 v20.9.0 v20.19.2 v21.1.0 v21.7.3 v22.0.0 v100.0.0; do
    if ! node_supports_eslint "$version"; then
      printf 'FAIL: node_supports_eslint rejected "%s", which ESLint 9 supports\n' "$version" >&2
      exit 1
    fi
  done
  for version in v12.22.9 v18.9.0 v18.17.1 v19.9.0 v20.8.1 v21.0.0 22.16.0 ''; do
    if node_supports_eslint "$version"; then
      printf 'FAIL: node_supports_eslint accepted "%s", which ESLint 9 does not support\n' "$version" >&2
      exit 1
    fi
  done

  if [[ ! -x "$repo_root/node_modules/.bin/eslint" ]]; then
    printf 'SKIP: JS lint skipped because npm dependencies are not installed\n'
    return 0
  fi

  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    printf 'SKIP: JS lint skipped because node or npm is not on PATH\n'
    return 0
  fi

  node_version="$(node --version 2>/dev/null || true)"
  if [[ ! "$node_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+[-+.0-9A-Za-z]*$ ]]; then
    printf 'SKIP: JS lint skipped because the Node.js version could not be determined from "node --version"\n'
    return 0
  fi

  if ! node_supports_eslint "$node_version"; then
    printf 'SKIP: JS lint skipped because Node.js %s is not supported by ESLint 9 (needs ^18.18.0 || ^20.9.0 || >=21.1.0)\n' "$node_version"
    return 0
  fi

  npm --prefix "$repo_root" run lint:js >/dev/null
}

test_status_list_failure() {
  local runtime_dir fake_bin

  runtime_dir="$(make_tmp_dir)"
  fake_bin="$(make_tmp_dir)"
  printf '#!/usr/bin/env bash\nexit 77\n' >"$fake_bin/systemd-inhibit"
  chmod +x "$fake_bin/systemd-inhibit"

  if NOSLEEP_TRUSTED_PATH="$fake_bin:/usr/sbin:/usr/bin:/sbin:/bin" XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" status >/dev/null 2>&1; then
    printf 'FAIL: status succeeded when systemd-inhibit --list failed\n' >&2
    exit 1
  fi
}

test_path_poisoning() {
  local marker poisoned_bin runtime_dir trusted_bin

  runtime_dir="$(make_tmp_dir)"
  poisoned_bin="$(make_tmp_dir)"
  trusted_bin="$(make_tmp_dir)"
  marker="$runtime_dir/path-command-called"
  printf '#!/bin/sh\ntouch %q\nexec /bin/bash "$@"\n' "$marker" >"$poisoned_bin/bash"
  printf '#!/bin/sh\ntouch %q\nexit 77\n' "$marker" >"$poisoned_bin/systemd-inhibit"
  printf '#!/bin/sh\ntouch %q\nexit 77\n' "$marker" >"$poisoned_bin/mkdir"
  printf '#!/bin/sh\ntouch %q\nexit 77\n' "$marker" >"$poisoned_bin/chmod"
  cat >"$trusted_bin/systemd-inhibit" <<'FAKE_INHIBIT'
#!/bin/bash
if [[ "${1:-}" == "--list" ]]; then
  exit 0
fi
exit 77
FAKE_INHIBIT
  chmod +x "$poisoned_bin/bash"
  chmod +x "$poisoned_bin/systemd-inhibit"
  chmod +x "$poisoned_bin/mkdir" "$poisoned_bin/chmod"
  chmod +x "$trusted_bin/systemd-inhibit"

  assert_eq off "$(
    PATH="$poisoned_bin:$PATH" \
      NOSLEEP_TRUSTED_PATH="$trusted_bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      XDG_RUNTIME_DIR="$runtime_dir" \
      "$repo_root/bin/nosleep" status
  )" 'status ignores poisoned PATH'
  [[ ! -e "$marker" ]] || {
    printf 'FAIL: status used mkdir/chmod from poisoned PATH\n' >&2
    exit 1
  }
}

test_lock_symlink() {
  local runtime_dir fake_bin marker

  runtime_dir="$(make_tmp_dir)"
  fake_bin="$(make_tmp_dir)"
  marker="$runtime_dir/marker"
  mkdir -p "$runtime_dir/nosleep"
  printf 'keep\n' >"$marker"
  ln -s "$marker" "$runtime_dir/nosleep/lock"
  cat >"$fake_bin/systemd-inhibit" <<'FAKE_INHIBIT'
#!/usr/bin/env bash
if [[ "${1:-}" == "--list" ]]; then
  exit 0
fi
exit 77
FAKE_INHIBIT
  chmod +x "$fake_bin/systemd-inhibit"

  assert_eq off "$(
    NOSLEEP_TRUSTED_PATH="$fake_bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      XDG_RUNTIME_DIR="$runtime_dir" \
      "$repo_root/bin/nosleep" status
  )" 'status works with lock symlink present'
  assert_eq keep "$(<"$marker")" 'lock symlink target is not truncated'
}

test_state_dir_symlink() {
  local runtime_dir target_dir

  runtime_dir="$(make_tmp_dir)"
  target_dir="$(make_tmp_dir)"
  ln -s "$target_dir" "$runtime_dir/nosleep"

  if XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" status >/dev/null 2>&1; then
    printf 'FAIL: status accepted a symlink state directory\n' >&2
    exit 1
  fi
}

test_state_dir_concurrent_create() {
  local fake_bin index pid real_mkdir runtime_dir
  local -a pids

  runtime_dir="$(make_tmp_dir)"
  fake_bin="$(make_tmp_dir)"
  real_mkdir="$(command -v mkdir)"
  cat >"$fake_bin/mkdir" <<FAKE_MKDIR
#!/bin/bash
sleep 0.2
exec "$real_mkdir" "\$@"
FAKE_MKDIR
  cat >"$fake_bin/systemd-inhibit" <<'FAKE_INHIBIT'
#!/bin/bash
if [[ "${1:-}" == "--list" ]]; then
  exit 0
fi
exit 77
FAKE_INHIBIT
  chmod +x "$fake_bin/mkdir" "$fake_bin/systemd-inhibit"

  pids=()
  for index in {1..8}; do
    (
      NOSLEEP_TRUSTED_PATH="$fake_bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        XDG_RUNTIME_DIR="$runtime_dir" \
        "$repo_root/bin/nosleep" status >"$runtime_dir/status-$index" 2>"$runtime_dir/error-$index"
    ) &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      printf 'FAIL: concurrent state directory creation failed\n' >&2
      cat "$runtime_dir"/error-* >&2
      exit 1
    fi
  done

  for index in {1..8}; do
    assert_eq off "$(<"$runtime_dir/status-$index")" 'concurrent state directory status'
  done
}

test_cli_state() {
  local blocker_pid cli_pid counter fake_bin fields pid proc_stat real_inhibit real_setsid runtime_dir
  local duplicate_pid_one duplicate_pid_two spoof_pid spoof_who target_pid

  if systemd-inhibit --list --no-pager --no-legend 2>/dev/null | grep -F 'nosleep:' >/dev/null; then
    printf 'SKIP: CLI state test skipped because a nosleep inhibitor is already active\n'
    return 0
  fi

  runtime_dir="$(make_tmp_dir)"
  assert_eq off "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" status)" 'initial status'
  systemd-inhibit --what=sleep --mode=block --who=other-tool --why=nosleep:running sleep 5 &
  spoof_pid="$!"
  run_pids+=("$spoof_pid")
  sleep 0.3
  assert_eq off "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" status)" 'status ignores spoofed running reason'
  kill "$spoof_pid" 2>/dev/null || true
  wait "$spoof_pid" 2>/dev/null || true

  systemd-inhibit --what=sleep --mode=block --who=other-tool --why=nosleep:persistent sleep 5 &
  spoof_pid="$!"
  run_pids+=("$spoof_pid")
  sleep 0.3
  assert_eq off "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" status)" 'status ignores spoofed persistent reason'
  kill "$spoof_pid" 2>/dev/null || true
  wait "$spoof_pid" 2>/dev/null || true

  sleep 20 &
  target_pid="$!"
  run_pids+=("$target_pid")
  spoof_who="nosleep:persistent $(id -u) $(id -un) $target_pid systemd-inhibit handle-lid-switch:sleep:idle filler"
  systemd-inhibit --what=handle-lid-switch:sleep:idle --mode=block --who="$spoof_who" --why=spoofed-nosleep sleep 5 &
  spoof_pid="$!"
  run_pids+=("$spoof_pid")
  sleep 0.3
  assert_eq off "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" status)" 'status ignores whitespace-spoofed persistent who'
  assert_eq off "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" off)" 'off ignores whitespace-spoofed persistent who'
  if ! kill -0 "$target_pid" 2>/dev/null; then
    printf 'FAIL: off killed pid injected through inhibitor who field\n' >&2
    exit 1
  fi
  kill "$spoof_pid" "$target_pid" 2>/dev/null || true
  wait "$spoof_pid" 2>/dev/null || true
  wait "$target_pid" 2>/dev/null || true

  runtime_dir="$(make_tmp_dir)"
  fake_bin="$(make_tmp_dir)"
  cat >"$fake_bin/systemd-inhibit" <<'FAKE_INHIBIT'
#!/usr/bin/env bash
if [[ "${1:-}" == "--list" ]]; then
  exit 0
fi
exit 77
FAKE_INHIBIT
  chmod +x "$fake_bin/systemd-inhibit"
  bash -c 'exec -a "$1" bash -c "trap \"exit\" TERM; while :; do sleep 1; done" nosleep-shim "${@:2}"' \
    bash "$fake_bin/systemd-inhibit" \
    --who=nosleep:persistent \
    --what=handle-lid-switch:sleep:idle \
    --mode=block &
  pid="$!"
  run_pids+=("$pid")
  sleep 0.3
  mkdir -p "$runtime_dir/nosleep"
  printf '%s\n' "$pid" >"$runtime_dir/nosleep/inhibit.pid"
  IFS= read -r proc_stat <"/proc/$pid/stat"
  fields="${proc_stat##*) }"
  # shellcheck disable=SC2086 # Split /proc stat fields into positional parameters.
  set -- $fields
  printf '%s\n' "${20}" >"$runtime_dir/nosleep/inhibit.start"
  IFS= read -r fields </proc/sys/kernel/random/boot_id
  printf '%s\n' "$fields" >"$runtime_dir/nosleep/inhibit.boot"
  assert_eq off "$(
    NOSLEEP_TRUSTED_PATH="$fake_bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      XDG_RUNTIME_DIR="$runtime_dir" \
      "$repo_root/bin/nosleep" status
  )" 'status ignores recorded process without logind inhibitor'
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  runtime_dir="$(make_tmp_dir)"
  fake_bin="$(make_tmp_dir)"
  counter="$runtime_dir/list-count"
  real_inhibit="$(command -v systemd-inhibit)"
  cat >"$fake_bin/systemd-inhibit" <<FAKE_INHIBIT
#!/usr/bin/env bash
if [[ "\${1:-}" == "--list" ]]; then
  count=0
  [[ -r "$counter" ]] && count=\$(<"$counter")
  count=\$((count + 1))
  printf '%s\\n' "\$count" >"$counter"
  if [[ "\$count" -eq 1 ]]; then
    exit 0
  fi
  sleep 5
  exit 0
fi
exec "$real_inhibit" "\$@"
FAKE_INHIBIT
  chmod +x "$fake_bin/systemd-inhibit"
  NOSLEEP_TRUSTED_PATH="$fake_bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    setsid "$repo_root/bin/nosleep" on >/dev/null 2>/dev/null &
  cli_pid="$!"
  run_pids+=("$cli_pid")
  blocker_pid=""
  for _ in {1..30}; do
    if [[ -r "$runtime_dir/nosleep/inhibit.pid" ]]; then
      blocker_pid="$(<"$runtime_dir/nosleep/inhibit.pid")"
      break
    fi
    sleep 0.1
  done
  [[ -n "$blocker_pid" ]] || {
    printf 'FAIL: interrupted start did not write a blocker pid\n' >&2
    exit 1
  }
  blocker_pids+=("$blocker_pid")
  kill -TERM -- "-$cli_pid" 2>/dev/null || kill -TERM "$cli_pid" 2>/dev/null || true
  wait "$cli_pid" 2>/dev/null || true
  sleep 0.3
  if kill -0 "$blocker_pid" 2>/dev/null; then
    printf 'FAIL: interrupted start left blocker running\n' >&2
    exit 1
  fi
  if compgen -G "$runtime_dir/nosleep/inhibit.*" >/dev/null; then
    printf 'FAIL: interrupted start left state files\n' >&2
    exit 1
  fi

  runtime_dir="$(make_tmp_dir)"
  fake_bin="$(make_tmp_dir)"
  real_setsid="$(command -v setsid)"
  cat >"$fake_bin/setsid" <<FAKE_SETSID
#!/usr/bin/env bash
sleep 0.4
exec "$real_setsid" "\$@"
FAKE_SETSID
  chmod +x "$fake_bin/setsid"
  assert_eq on "$(
    NOSLEEP_TRUSTED_PATH="$fake_bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      XDG_RUNTIME_DIR="$runtime_dir" \
      "$repo_root/bin/nosleep" on
  )" 'turn on waits for delayed setsid'
  pid="$(<"$runtime_dir/nosleep/inhibit.pid")"
  blocker_pids+=("$pid")
  assert_eq on "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" status)" 'status after delayed setsid'
  assert_eq off "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" off)" 'turn off after delayed setsid'

  runtime_dir="$(make_tmp_dir)"
  fake_bin="$(make_tmp_dir)"
  assert_eq on "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" on)" 'turn on before list miss'
  pid="$(<"$runtime_dir/nosleep/inhibit.pid")"
  blocker_pids+=("$pid")
  cat >"$fake_bin/systemd-inhibit" <<'FAKE_INHIBIT'
#!/usr/bin/env bash
if [[ "${1:-}" == "--list" ]]; then
  exit 0
fi
exit 77
FAKE_INHIBIT
  chmod +x "$fake_bin/systemd-inhibit"
  assert_eq off "$(
    NOSLEEP_TRUSTED_PATH="$fake_bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      XDG_RUNTIME_DIR="$runtime_dir" \
      "$repo_root/bin/nosleep" off
  )" 'off stops recorded inhibitor when list misses it'
  if kill -0 "$pid" 2>/dev/null; then
    printf 'FAIL: off left recorded blocker running after list miss\n' >&2
    exit 1
  fi
  if compgen -G "$runtime_dir/nosleep/inhibit.*" >/dev/null; then
    printf 'FAIL: off left recorded state files after list miss\n' >&2
    exit 1
  fi

  runtime_dir="$(make_tmp_dir)"
  systemd-inhibit \
    --what=handle-lid-switch:sleep:idle \
    --mode=block \
    --who=nosleep:persistent \
    --why=duplicate-nosleep-one \
    -- sleep 20 &
  duplicate_pid_one="$!"
  run_pids+=("$duplicate_pid_one")
  systemd-inhibit \
    --what=handle-lid-switch:sleep:idle \
    --mode=block \
    --who=nosleep:persistent \
    --why=duplicate-nosleep-two \
    -- sleep 20 &
  duplicate_pid_two="$!"
  run_pids+=("$duplicate_pid_two")
  sleep 0.3
  assert_eq off "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" off)" 'off stops duplicate persistent inhibitors'
  if systemd-inhibit --list --no-pager --no-legend 2>/dev/null | grep -F 'nosleep:persistent' >/dev/null; then
    printf 'FAIL: off left duplicate persistent inhibitors\n' >&2
    exit 1
  fi
  wait "$duplicate_pid_one" 2>/dev/null || true
  wait "$duplicate_pid_two" 2>/dev/null || true

  runtime_dir="$(make_tmp_dir)"
  assert_eq on "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" on)" 'turn on before recorded duplicate'
  pid="$(<"$runtime_dir/nosleep/inhibit.pid")"
  blocker_pids+=("$pid")
  systemd-inhibit \
    --what=handle-lid-switch:sleep:idle \
    --mode=block \
    --who=nosleep:persistent \
    --why=recorded-duplicate-nosleep \
    -- sleep 20 &
  duplicate_pid_one="$!"
  run_pids+=("$duplicate_pid_one")
  sleep 0.3
  assert_eq off "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" off)" 'off stops recorded and duplicate persistent inhibitors'
  if systemd-inhibit --list --no-pager --no-legend 2>/dev/null | grep -F 'nosleep:persistent' >/dev/null; then
    printf 'FAIL: off left recorded duplicate persistent inhibitor\n' >&2
    exit 1
  fi
  wait "$duplicate_pid_one" 2>/dev/null || true

  assert_eq on "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" on)" 'turn on'
  pid="$(<"$runtime_dir/nosleep/inhibit.pid")"
  blocker_pids+=("$pid")
  rm "$runtime_dir/nosleep/inhibit.start" "$runtime_dir/nosleep/inhibit.boot"
  assert_eq on "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" status)" 'status after identity file loss'
  assert_eq off "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" off)" 'turn off after identity file loss'

  runtime_dir="$(make_tmp_dir)"
  assert_eq on "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" on)" 'turn on before pid file loss'
  pid="$(<"$runtime_dir/nosleep/inhibit.pid")"
  blocker_pids+=("$pid")
  rm "$runtime_dir/nosleep/inhibit.pid"
  assert_eq on "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" status)" 'status after pid file loss'
  assert_eq off "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" off)" 'turn off after pid file loss'
  if kill -0 -- "-$pid" 2>/dev/null; then
    printf 'FAIL: fallback off left blocker process group after pid file loss\n' >&2
    exit 1
  fi

  runtime_dir="$(make_tmp_dir)"
  XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" run sleep 5 &
  run_pids+=("$!")
  sleep 0.3
  assert_eq on "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" on)" 'turn on while command runs'
  assert_eq running "$(XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" off)" 'turn off while command runs'

  runtime_dir="$(make_tmp_dir)"
  fake_bin="$(make_tmp_dir)"
  printf '#!/usr/bin/env bash\nprintf "dash-command-ran\\n"\n' >"$fake_bin/-dashcmd"
  chmod +x "$fake_bin/-dashcmd"
  assert_eq dash-command-ran "$(PATH="$fake_bin:$PATH" XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" run -dashcmd)" 'dash-prefixed command'
}

extension_source_matches() {
  local variant="$1"
  local pattern="$2"
  local message="$3"

  grep -E -e "$pattern" "$repo_root/$variant/extension.js" >/dev/null || {
    printf 'FAIL: %s/extension.js %s\n' "$variant" "$message" >&2
    exit 1
  }
}

extension_source_lacks() {
  local variant="$1"
  local pattern="$2"
  local message="$3"

  if grep -E -e "$pattern" "$repo_root/$variant/extension.js" >/dev/null; then
    printf 'FAIL: %s/extension.js %s\n' "$variant" "$message" >&2
    exit 1
  fi
}

check_extension_variant() {
  local variant="$1"
  local expected_shell_version="$2"
  local variant_dir="$repo_root/$variant"
  local contract icon metadata_uuid shell_version
  local -a source_contracts

  metadata_uuid="$(sed -n 's/.*"uuid": *"\([^"]*\)".*/\1/p' "$variant_dir/metadata.json")"
  assert_eq nosleep-toggle@systemd-inhibit.local "$metadata_uuid" "$variant metadata UUID"

  shell_version="$(sed -n 's/.*"shell-version": *\[\(.*\)\].*/\1/p' "$variant_dir/metadata.json" | tr -d '" ')"
  assert_eq "$expected_shell_version" "$shell_version" "$variant metadata shell-version"

  while IFS= read -r icon; do
    [[ -f "$variant_dir/icons/$icon" ]] || {
      printf 'FAIL: missing %s icon: %s\n' "$variant" "$icon" >&2
      exit 1
    }
  done < <(grep -o 'nosleep-[a-z]*-symbolic\.svg' "$variant_dir/extension.js" | sort -u)

  # Each entry is 'fixed string|failure message'.
  source_contracts=(
    '_signalControl(control, SIGTERM)|does not terminate subprocesses gracefully first'
    "const SETSID_PATH = '/usr/bin/setsid';|does not launch controls in a new session"
    'get_identifier|does not track the subprocess process group'
    'processGroupId|does not signal subprocess process groups'
    'SIGKILL|does not keep a process group force-kill fallback'
    'FORCE_EXIT_DELAY_SECONDS|does not keep a delayed force-exit fallback'
    '_stateGeneration|does not guard stale refresh results'
    'loading:|does not have an initial loading state'
    '_statusLoaded|does not guard toggles before initial status'
  )
  for contract in "${source_contracts[@]}"; do
    grep -F -e "${contract%%|*}" "$variant_dir/extension.js" >/dev/null || {
      printf 'FAIL: %s/extension.js %s\n' "$variant" "${contract#*|}" >&2
      exit 1
    }
  done
}

# Prints a variant's metadata.json with the shell-version value blanked, so
# that everything else, including the rest of that line, is still compared.
metadata_without_shell_version() {
  local variant="$1"

  sed 's/"shell-version": *\[[^]]*\]/"shell-version": []/' "$repo_root/$variant/metadata.json"
}

test_extension_metadata() {
  check_extension_variant extension 46
  check_extension_variant extension-legacy 42

  if ! diff <(metadata_without_shell_version extension) \
    <(metadata_without_shell_version extension-legacy) >/dev/null; then
    printf 'FAIL: extension variant metadata differs beyond shell-version\n' >&2
    exit 1
  fi

  [[ -L "$repo_root/extension-legacy/icons" ]] || {
    printf 'FAIL: extension-legacy/icons is not a symlink\n' >&2
    exit 1
  }
  assert_eq ../extension/icons "$(readlink "$repo_root/extension-legacy/icons")" 'legacy extension icons link'
}

# Prints one part of a variant's extension.js. The parts do not overlap and
# together cover the file from the UUID constant to its last line:
#   shared        the code both variants must share: from the UUID constant to
#                 the end of the indicator class, without the click-policy
#                 method
#   click-policy  the click-policy method of the indicator class
#   entry-point   everything after the indicator class
# The class ends at the first "});" line after its "const NoSleepIndicator = "
# line, so an earlier "});" does not cut the shared code short.
extension_source_part() {
  local variant="$1"
  local click_method="$2"
  local wanted="$3"

  awk -v wanted="$wanted" -v click_header="    $click_method(event) {" '
    part == "" && /^const UUID = / { part = "shared" }
    part == "shared" && /^const NoSleepIndicator = / { in_class = 1 }
    part == "shared" && in_class && $0 == click_header { part = "click-policy" }
    part == wanted { print }
    part == "click-policy" && $0 == "    }" { part = "shared"; next }
    part == "shared" && in_class && $0 == "});" { part = "entry-point" }
  ' "$repo_root/$variant/extension.js"
}

# Fails unless the code lines of a part of extension-legacy/extension.js are
# exactly the lines on standard input. Blank lines and lines holding only a //
# comment are not code lines, so such a comment cannot stand in for a statement.
assert_legacy_code() {
  local label="$1"
  local part="$2"
  local actual pinned

  pinned="$(cat)"
  actual="$(sed -E '/^[[:space:]]*(\/\/.*)?$/d' <<<"$part")"
  if [[ "$actual" != "$pinned" ]]; then
    printf 'FAIL: extension-legacy/extension.js %s differs from the code pinned in tests/run.sh (< pinned, > file)\n' "$label" >&2
    diff <(printf '%s\n' "$pinned") <(printf '%s\n' "$actual") | head -n 20 >&2 || true
    exit 1
  fi
}

test_extension_variants() {
  local esm_body esm_click_policy esm_lines expected_legacy_body legacy_body variant

  # GNOME Shell 45+ runs import() on extension/extension.js.
  extension_source_matches extension '^export default class ' 'has no default export class'
  extension_source_lacks extension '(^|[^.[:alnum:]_])imports[.]' 'uses the legacy imports object'

  # GNOME Shell 42 loads extension-legacy/extension.js as a legacy script.
  extension_source_lacks extension-legacy '^(import|export)([^[:alnum:]_]|$)' 'uses ES module syntax'
  extension_source_lacks extension-legacy $'\r' 'contains a carriage return'
  extension_source_matches extension-legacy '^function init[(]extension[)] [{]$' 'has no init(extension) entry point'

  # GNOME Shell 42 toggles the menu in PanelMenu.Button.vfunc_event() before
  # button-press-event is emitted, so the click policy has to live there.
  extension_source_matches extension-legacy '^    vfunc_event[(]event[)] [{]$' 'does not decide the click policy in vfunc_event'
  extension_source_lacks extension-legacy '^[[:space:]]*vfunc_button_press_event[(]' 'handles clicks in vfunc_button_press_event'

  # Yaru's 27px panel squeezes the icon unless its vertical padding is removed.
  extension_source_matches extension-legacy "^const ICON_STYLE = 'padding-top: 0; padding-bottom: 0;';\$" 'does not define the icon style'
  extension_source_matches extension-legacy '^            style: ICON_STYLE,$' 'does not apply the icon style'

  for variant in extension extension-legacy; do
    # extension_source_part splits each file at these two lines.
    extension_source_matches "$variant" '^const UUID = ' 'does not define the UUID constant'
    extension_source_matches "$variant" '^const NoSleepIndicator = ' 'does not define the indicator class as NoSleepIndicator'
    extension_source_matches "$variant" "^        Main[.]panel[.]addToStatusArea[(]UUID, this[.]_indicator, 1, 'right'[)];\$" 'does not add the indicator to the status area'
    extension_source_matches "$variant" '^            this[.]_indicator[.]destroy[(][)];$' 'does not destroy the indicator on disable'
  done

  esm_body="$(extension_source_part extension vfunc_button_press_event shared)"
  # Sanity floor (344 lines today): an empty or truncated span must not pass.
  esm_lines=0
  [[ -z "$esm_body" ]] || esm_lines="$(wc -l <<<"$esm_body")"
  [[ "$esm_lines" -gt 300 ]] || {
    printf 'FAIL: extension/extension.js has %s lines of shared code; expected more than 300 from "const UUID" to the end of the NoSleepIndicator class\n' "$esm_lines" >&2
    exit 1
  }

  # Nothing compares the legacy click policy and the legacy entry point with
  # the ES module, so their code lines are pinned here. Their behaviour can
  # only be checked by running the variant: before changing the pinned text,
  # enable the variant on GNOME Shell 42 and click the indicator again.
  assert_legacy_code 'click policy' "$(extension_source_part extension-legacy vfunc_event click-policy)" <<'PINNED'
    vfunc_event(event) {
        if (event.type() !== Clutter.EventType.BUTTON_PRESS)
            return super.vfunc_event(event);
        const button = event.get_button();
        if (button === Clutter.BUTTON_PRIMARY) {
            this._toggle();
            return Clutter.EVENT_STOP;
        }
        if (button === Clutter.BUTTON_SECONDARY) {
            this.menu.toggle();
            return Clutter.EVENT_STOP;
        }
        return Clutter.EVENT_PROPAGATE;
    }
PINNED
  assert_legacy_code 'entry point' "$(extension_source_part extension-legacy vfunc_event entry-point)" <<'PINNED'
class NoSleepToggleExtension {
    constructor(extension) {
        this._path = extension.path;
        this._indicator = null;
    }
    enable() {
        this._indicator = new NoSleepIndicator(Gio.File.new_for_path(this._path));
        Main.panel.addToStatusArea(UUID, this._indicator, 1, 'right');
    }
    disable() {
        if (this._indicator) {
            this._indicator.destroy();
            this._indicator = null;
        }
    }
}
function init(extension) {
    return new NoSleepToggleExtension(extension);
}
PINNED

  # The parity check skips the click-policy method of each file. The ES
  # module's is not pinned, so make sure the range skipped there is that one
  # method: only its header and its closing brace are indented less than a
  # method body.
  esm_click_policy="$(extension_source_part extension vfunc_button_press_event click-policy)"
  [[ "$(grep -c -v -E -e '^(        |[[:space:]]*$)' <<<"$esm_click_policy")" -eq 2 ]] || {
    printf 'FAIL: extension/extension.js click-policy range is not exactly one method\n' >&2
    exit 1
  }
  # The braces opened by the header must close on the last line, not earlier.
  awk '
    { depth += gsub(/[{]/, "{") - gsub(/[}]/, "}") }
    depth == 0 && !closed { closed = NR }
    END { exit closed != NR }
  ' <<<"$esm_click_policy" || {
    printf 'FAIL: extension/extension.js click-policy range closes before its last line\n' >&2
    exit 1
  }

  legacy_body="$(extension_source_part extension-legacy vfunc_event shared)"
  # The legacy file has exactly one more line: the icon style, right after the
  # icon's style class. A style: ICON_STYLE line anywhere else is a difference.
  expected_legacy_body="$(awk -v style_class="            style_class: 'system-status-icon'," '
    { print }
    $0 == style_class && !styled { print "            style: ICON_STYLE,"; styled = 1 }
  ' <<<"$esm_body")"
  if [[ "$legacy_body" != "$expected_legacy_body" ]]; then
    printf 'FAIL: shared extension code differs between extension/ and extension-legacy/\n' >&2
    diff <(printf '%s\n' "$expected_legacy_body") <(printf '%s\n' "$legacy_body") | head -n 20 >&2 || true
    exit 1
  fi
}

test_install_uninstall() {
  local extension_uuid foreign_extension gnome_marker home_dir marker runtime_dir fake_bin stop_marker

  home_dir="$(make_tmp_dir)"
  runtime_dir="$(make_tmp_dir)"
  fake_bin="$(make_tmp_dir)"
  marker="$home_dir/path-nosleep-called"
  stop_marker="$home_dir/source-nosleep-called"
  gnome_marker="$home_dir/gnome-extensions-called"
  extension_uuid="nosleep-toggle@systemd-inhibit.local"

  mkdir -p "$home_dir/.local/bin" "$home_dir/.local/share/gnome-shell/extensions"
  ln -s /tmp/foreign-nosleep "$home_dir/.local/bin/nosleep"
  foreign_extension="$home_dir/foreign-extension"
  mkdir -p "$foreign_extension"
  ln -s "$foreign_extension" "$home_dir/.local/share/gnome-shell/extensions/$extension_uuid"
  printf '#!/bin/bash\ntouch %q\nexit 77\n' "$stop_marker" >"$fake_bin/systemd-inhibit"
  chmod +x "$fake_bin/systemd-inhibit"

  HOME="$home_dir" XDG_RUNTIME_DIR="$runtime_dir" \
    NOSLEEP_TRUSTED_PATH="$fake_bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$repo_root/uninstall.sh" >/dev/null 2>/dev/null
  [[ ! -e "$stop_marker" ]] || {
    printf 'FAIL: uninstall stopped NoSleep for a foreign CLI link\n' >&2
    exit 1
  }
  assert_eq /tmp/foreign-nosleep "$(readlink "$home_dir/.local/bin/nosleep")" 'foreign CLI link preserved'
  assert_eq "$foreign_extension" "$(readlink "$home_dir/.local/share/gnome-shell/extensions/$extension_uuid")" 'foreign extension link preserved'

  cat >"$fake_bin/gnome-extensions" <<FAKE_GNOME_EXTENSIONS
#!/bin/bash
printf '%s\\n' "\$*" >> $(printf '%q' "$gnome_marker")
if [[ "\${1:-}" == "enable" ]]; then
  echo enable failed >&2
  exit 1
fi
FAKE_GNOME_EXTENSIONS
  chmod +x "$fake_bin/gnome-extensions"
  printf '#!/bin/bash\nprintf "GNOME Shell 46.0\\n"\n' >"$fake_bin/gnome-shell"
  chmod +x "$fake_bin/gnome-shell"

  HOME="$home_dir" PATH="$fake_bin:$PATH" \
    NOSLEEP_GNOME_EXTENSIONS_CMD="$fake_bin/gnome-extensions" \
    NOSLEEP_GNOME_SHELL_CMD="$fake_bin/gnome-shell" \
    "$repo_root/install.sh" >/dev/null 2>/dev/null
  assert_eq "$repo_root/bin/nosleep" "$(readlink "$home_dir/.local/bin/nosleep")" 'installed CLI link'
  assert_eq "$repo_root/extension" "$(readlink "$home_dir/.local/share/gnome-shell/extensions/$extension_uuid")" 'installed extension link'
  compgen -G "$home_dir/.local/bin/nosleep.bak.*/nosleep" >/dev/null || {
    printf 'FAIL: install did not back up foreign symlink\n' >&2
    exit 1
  }
  grep -Fx "enable $extension_uuid" "$gnome_marker" >/dev/null || {
    printf 'FAIL: install did not call test gnome-extensions helper\n' >&2
    exit 1
  }

  printf '#!/usr/bin/env bash\ntouch %q\n' "$marker" >"$fake_bin/nosleep"
  chmod +x "$fake_bin/nosleep"

  HOME="$home_dir" XDG_RUNTIME_DIR="$runtime_dir" PATH="$fake_bin:$PATH" \
    NOSLEEP_GNOME_EXTENSIONS_CMD="$fake_bin/gnome-extensions" \
    "$repo_root/uninstall.sh" >/dev/null 2>/dev/null
  [[ ! -e "$marker" ]] || {
    printf 'FAIL: uninstall called nosleep from PATH\n' >&2
    exit 1
  }
  grep -Fx "disable $extension_uuid" "$gnome_marker" >/dev/null || {
    printf 'FAIL: uninstall did not call test gnome-extensions helper\n' >&2
    exit 1
  }
  [[ ! -e "$home_dir/.local/bin/nosleep" ]] || {
    printf 'FAIL: uninstall left CLI link behind\n' >&2
    exit 1
  }
  [[ ! -e "$home_dir/.local/share/gnome-shell/extensions/$extension_uuid" ]] || {
    printf 'FAIL: uninstall left extension link behind\n' >&2
    exit 1
  }
}

installer_uuid="nosleep-toggle@systemd-inhibit.local"
installer_extension_root=".local/share/gnome-shell/extensions"
installer_extension_link="$installer_extension_root/$installer_uuid"

# Writes a fake gnome-shell that prints VERSION_LINE on stdout.
write_fake_gnome_shell() {
  local path="$1"
  local version_line="$2"

  printf '#!/bin/bash\nprintf "%%s\\n" %q\n' "$version_line" >"$path"
  chmod +x "$path"
}

# Creates the fake commands the installer variant tests share in DIR:
# gnome-extensions logs its arguments to DIR/gnome-extensions.log,
# gnome-extensions-fail also fails "enable" the way a running Shell does for an
# extension it has not scanned yet, and systemd-inhibit logs its arguments to
# DIR/systemd-inhibit.log and reports no inhibitors, so the `nosleep off`
# issued by uninstall.sh never reaches logind.
make_installer_fakes() {
  local dir="$1"

  cat >"$dir/gnome-extensions" <<'FAKE_GNOME_EXTENSIONS'
#!/bin/bash
printf '%s\n' "$*" >>"${0%/*}/gnome-extensions.log"
FAKE_GNOME_EXTENSIONS
  cat >"$dir/gnome-extensions-fail" <<'FAKE_GNOME_EXTENSIONS'
#!/bin/bash
printf '%s\n' "$*" >>"${0%/*}/gnome-extensions.log"
if [[ "${1:-}" == "enable" ]]; then
  printf 'Extension does not exist\n' >&2
  exit 2
fi
FAKE_GNOME_EXTENSIONS
  cat >"$dir/systemd-inhibit" <<'FAKE_INHIBIT'
#!/bin/bash
printf '%s\n' "$*" >>"${0%/*}/systemd-inhibit.log"
if [[ "${1:-}" == "--list" ]]; then
  exit 0
fi
exit 77
FAKE_INHIBIT
  chmod +x "$dir/gnome-extensions" "$dir/gnome-extensions-fail" "$dir/systemd-inhibit"
  write_fake_gnome_shell "$dir/gnome-shell-42" 'GNOME Shell 42.9'
  write_fake_gnome_shell "$dir/gnome-shell-46" 'GNOME Shell 46.0'
}

# run_install HOME GNOME_SHELL_CMD GNOME_EXTENSIONS_CMD
# Prints the combined output of install.sh. Both commands are mandatory: an
# empty value would make install.sh fall back to the host's GNOME Shell and
# gnome-extensions.
run_install() {
  local home_dir="$1"
  local shell_cmd="$2"
  local extensions_cmd="$3"
  local output

  [[ -n "$shell_cmd" && -n "$extensions_cmd" ]] || {
    printf 'FAIL: installer test does not pin the GNOME commands\n' >&2
    exit 1
  }

  if ! output="$(HOME="$home_dir" \
    NOSLEEP_GNOME_SHELL_CMD="$shell_cmd" \
    NOSLEEP_GNOME_EXTENSIONS_CMD="$extensions_cmd" \
    "$repo_root/install.sh" 2>&1)"; then
    printf 'FAIL: install.sh failed with %s:\n%s\n' "${shell_cmd##*/}" "$output" >&2
    exit 1
  fi
  printf '%s\n' "$output"
}

# run_uninstall HOME FAKE_BIN
# Uses the fake systemd-inhibit and gnome-extensions from FAKE_BIN.
run_uninstall() {
  local home_dir="$1"
  local fake_bin="$2"
  local output

  mkdir -p "$home_dir/runtime"
  if ! output="$(HOME="$home_dir" XDG_RUNTIME_DIR="$home_dir/runtime" \
    NOSLEEP_TRUSTED_PATH="$fake_bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    NOSLEEP_GNOME_EXTENSIONS_CMD="$fake_bin/gnome-extensions" \
    "$repo_root/uninstall.sh" 2>&1)"; then
    printf 'FAIL: uninstall.sh failed:\n%s\n' "$output" >&2
    exit 1
  fi
}

assert_output_contains() {
  local output="$1"
  local fragment="$2"
  local label="$3"

  grep -F -e "$fragment" <<<"$output" >/dev/null || {
    printf 'FAIL: %s: output lacks "%s":\n%s\n' "$label" "$fragment" "$output" >&2
    exit 1
  }
}

assert_output_lacks() {
  local output="$1"
  local fragment="$2"
  local label="$3"

  if grep -F -e "$fragment" <<<"$output" >/dev/null; then
    printf 'FAIL: %s: output contains "%s":\n%s\n' "$label" "$fragment" "$output" >&2
    exit 1
  fi
}

assert_no_path() {
  local path="$1"
  local label="$2"

  if [[ -e "$path" || -L "$path" ]]; then
    printf 'FAIL: %s: %s exists\n' "$label" "$path" >&2
    exit 1
  fi
}

# The extensions directory must hold the extension link and nothing else:
# GNOME Shell tries to load every entry, including *.bak.* backups.
assert_only_extension_link() {
  local home_dir="$1"
  local label="$2"

  assert_eq "$installer_uuid" \
    "$(find "$home_dir/$installer_extension_root" -mindepth 1 -maxdepth 1 -printf '%f\n')" \
    "$label"
}

test_install_variant_selection() {
  local fake_bin home_dir incomplete_checkout major output root unsupported variant version
  local -a majors

  root="$(make_tmp_dir)"
  fake_bin="$root/bin"
  mkdir -p "$fake_bin"
  make_installer_fakes "$fake_bin"

  # Every Shell major a variant declares must make install.sh pick that variant.
  for variant in extension extension-legacy; do
    mapfile -t majors < <(sed -n 's/.*"shell-version": *\[\(.*\)\].*/\1/p' "$repo_root/$variant/metadata.json" |
      tr -d '" ' | tr ',' '\n')
    [[ "${#majors[@]}" -gt 0 ]] || {
      printf 'FAIL: no shell-version found in %s/metadata.json\n' "$variant" >&2
      exit 1
    }

    for major in "${majors[@]}"; do
      home_dir="$root/home-$variant-$major"
      mkdir -p "$home_dir"
      write_fake_gnome_shell "$fake_bin/gnome-shell-declared" "GNOME Shell $major.9"
      output="$(run_install "$home_dir" "$fake_bin/gnome-shell-declared" "$fake_bin/gnome-extensions")"
      assert_eq "$repo_root/$variant" "$(readlink "$home_dir/$installer_extension_link")" "extension link for declared GNOME Shell $major"
      assert_eq "$repo_root/bin/nosleep" "$(readlink "$home_dir/.local/bin/nosleep")" "CLI link for declared GNOME Shell $major"
      assert_output_lacks "$output" 'not a supported version' "install for declared GNOME Shell $major"
    done
  done

  # Undeclared majors still get the variant their loader needs, with a warning.
  for unsupported in '3.36.9|extension-legacy' '44.9|extension-legacy' '45.0|extension' '47.alpha|extension'; do
    version="${unsupported%%|*}"
    variant="${unsupported#*|}"
    home_dir="$root/home-unsupported-$version"
    mkdir -p "$home_dir"
    write_fake_gnome_shell "$fake_bin/gnome-shell-undeclared" "GNOME Shell $version"
    output="$(run_install "$home_dir" "$fake_bin/gnome-shell-undeclared" "$fake_bin/gnome-extensions")"
    assert_eq "$repo_root/$variant" "$(readlink "$home_dir/$installer_extension_link")" "extension link for GNOME Shell $version"
    assert_output_contains "$output" 'not a supported version' "install for GNOME Shell $version"
  done

  # Only stdout of `gnome-shell --version` counts, and it is read with LC_ALL=C.
  home_dir="$root/home-stdout-only"
  mkdir -p "$home_dir"
  cat >"$fake_bin/gnome-shell-noisy" <<'FAKE_GNOME_SHELL'
#!/bin/bash
printf 'GNOME Shell 46.0\n' >&2
[[ "${1:-}" == "--version" && "${LC_ALL:-}" == "C" ]] || exit 1
printf 'GNOME Shell 42.9\n'
FAKE_GNOME_SHELL
  chmod +x "$fake_bin/gnome-shell-noisy"
  run_install "$home_dir" "$fake_bin/gnome-shell-noisy" "$fake_bin/gnome-extensions" >/dev/null
  assert_eq "$repo_root/extension-legacy" "$(readlink "$home_dir/$installer_extension_link")" 'extension link from gnome-shell stdout'

  # The variant is decided before any link is created: a checkout without the
  # variant it needs installs nothing, not even the CLI link.
  home_dir="$root/home-incomplete-checkout"
  incomplete_checkout="$root/incomplete-checkout"
  mkdir -p "$home_dir" "$incomplete_checkout/bin"
  cp "$repo_root/install.sh" "$incomplete_checkout/install.sh"
  cp "$repo_root/bin/nosleep" "$incomplete_checkout/bin/nosleep"
  cp -R "$repo_root/extension" "$incomplete_checkout/extension"
  if HOME="$home_dir" \
    NOSLEEP_GNOME_SHELL_CMD="$fake_bin/gnome-shell-42" \
    NOSLEEP_GNOME_EXTENSIONS_CMD="$fake_bin/gnome-extensions" \
    "$incomplete_checkout/install.sh" >/dev/null 2>&1; then
    printf 'FAIL: install succeeded without the extension variant it needs\n' >&2
    exit 1
  fi
  assert_no_path "$home_dir/.local" 'install from a checkout without extension-legacy'
}

test_install_undetectable_shell() {
  local fake_bin home_dir output root shell_cmd

  root="$(make_tmp_dir)"
  fake_bin="$root/bin"
  mkdir -p "$fake_bin" "$root/foreign-extension"
  make_installer_fakes "$fake_bin"
  write_fake_gnome_shell "$fake_bin/gnome-shell-unparsable" 'mutter 42.9'
  printf '#!/bin/bash\nprintf "GNOME Shell 42.9\\n"\nexit 1\n' >"$fake_bin/gnome-shell-failing"
  printf '#!/bin/bash\nprintf "GNOME Shell 42.9\\n" >&2\n' >"$fake_bin/gnome-shell-stderr"
  chmod +x "$fake_bin/gnome-shell-failing" "$fake_bin/gnome-shell-stderr"

  # gnome-shell-missing does not exist.
  for shell_cmd in gnome-shell-unparsable gnome-shell-failing gnome-shell-stderr gnome-shell-missing; do
    home_dir="$root/home-$shell_cmd"
    mkdir -p "$home_dir"
    output="$(run_install "$home_dir" "$fake_bin/$shell_cmd" "$fake_bin/gnome-extensions")"
    assert_eq "$repo_root/bin/nosleep" "$(readlink "$home_dir/.local/bin/nosleep")" "CLI link with $shell_cmd"
    assert_no_path "$home_dir/$installer_extension_link" "install with $shell_cmd"
    assert_output_contains "$output" 'NOSLEEP_GNOME_SHELL_CMD' "install with $shell_cmd"
    assert_no_path "$fake_bin/gnome-extensions.log" "gnome-extensions calls with $shell_cmd"
  done

  # An existing extension link is left alone as well, owned or not.
  home_dir="$root/home-existing-owned"
  mkdir -p "$home_dir"
  run_install "$home_dir" "$fake_bin/gnome-shell-42" "$fake_bin/gnome-extensions" >/dev/null
  rm -f "$fake_bin/gnome-extensions.log"
  run_install "$home_dir" "$fake_bin/gnome-shell-unparsable" "$fake_bin/gnome-extensions" >/dev/null
  assert_eq "$repo_root/extension-legacy" "$(readlink "$home_dir/$installer_extension_link")" 'owned extension link without a detectable Shell'

  home_dir="$root/home-existing-foreign"
  mkdir -p "$home_dir/$installer_extension_root"
  ln -s "$root/foreign-extension" "$home_dir/$installer_extension_link"
  run_install "$home_dir" "$fake_bin/gnome-shell-unparsable" "$fake_bin/gnome-extensions" >/dev/null
  assert_eq "$root/foreign-extension" "$(readlink "$home_dir/$installer_extension_link")" 'foreign extension link without a detectable Shell'
  assert_only_extension_link "$home_dir" 'extensions directory without a detectable Shell'

  assert_no_path "$fake_bin/gnome-extensions.log" 'gnome-extensions calls without a detectable Shell'
}

test_install_variant_switch() {
  local fake_bin home_dir root shell_major step variant

  root="$(make_tmp_dir)"
  fake_bin="$root/bin"
  home_dir="$root/home"
  mkdir -p "$fake_bin" "$home_dir"
  make_installer_fakes "$fake_bin"

  # A link to the other variant of this checkout is switched in place.
  for step in '42|extension-legacy' '46|extension' '42|extension-legacy' '46|extension'; do
    shell_major="${step%%|*}"
    variant="${step#*|}"
    run_install "$home_dir" "$fake_bin/gnome-shell-$shell_major" "$fake_bin/gnome-extensions" >/dev/null
    assert_eq "$repo_root/$variant" "$(readlink "$home_dir/$installer_extension_link")" "extension link after switching to GNOME Shell $shell_major"
    assert_only_extension_link "$home_dir" "extensions directory after switching to GNOME Shell $shell_major"
  done

  assert_eq nosleep "$(find "$home_dir/.local/bin" -mindepth 1 -maxdepth 1 -printf '%f\n')" 'CLI directory after switching variants'
}

test_install_foreign_extension_links() {
  local backup fake_bin foreign home_dir index other_checkout root shell_major step variant

  root="$(make_tmp_dir)"
  fake_bin="$root/bin"
  other_checkout="$root/other-checkout"
  mkdir -p "$fake_bin" "$root/foreign-extension" "$other_checkout/extension" "$other_checkout/extension-legacy"
  make_installer_fakes "$fake_bin"

  # Links that are not owned by this checkout are backed up, including links
  # to the variant directories of another checkout.
  index=0
  for step in '42|extension-legacy' '46|extension'; do
    shell_major="${step%%|*}"
    variant="${step#*|}"
    for foreign in "$root/foreign-extension" "$other_checkout/extension" "$other_checkout/extension-legacy"; do
      index=$((index + 1))
      home_dir="$root/home-link-$index"
      mkdir -p "$home_dir/$installer_extension_root"
      ln -s "$foreign" "$home_dir/$installer_extension_link"
      run_install "$home_dir" "$fake_bin/gnome-shell-$shell_major" "$fake_bin/gnome-extensions" >/dev/null
      assert_eq "$repo_root/$variant" "$(readlink "$home_dir/$installer_extension_link")" "extension link replacing ${foreign#"$root"/}"
      backup="$(compgen -G "$home_dir/$installer_extension_link.bak.*/$installer_uuid")" || {
        printf 'FAIL: install did not back up the link to %s\n' "${foreign#"$root"/}" >&2
        exit 1
      }
      assert_eq "$foreign" "$(readlink "$backup")" "backup of the link to ${foreign#"$root"/}"
    done
  done

  # A real directory in the way is backed up too.
  home_dir="$root/home-directory"
  mkdir -p "$home_dir/$installer_extension_link"
  touch "$home_dir/$installer_extension_link/metadata.json"
  run_install "$home_dir" "$fake_bin/gnome-shell-42" "$fake_bin/gnome-extensions" >/dev/null
  assert_eq "$repo_root/extension-legacy" "$(readlink "$home_dir/$installer_extension_link")" 'extension link replacing a directory'
  compgen -G "$home_dir/$installer_extension_link.bak.*/$installer_uuid/metadata.json" >/dev/null || {
    printf 'FAIL: install did not back up a foreign extension directory\n' >&2
    exit 1
  }
}

test_uninstall_variant_ownership() {
  local fake_bin foreign home_dir index other_checkout root shell_major step variant

  root="$(make_tmp_dir)"
  fake_bin="$root/bin"
  other_checkout="$root/other-checkout"
  mkdir -p "$fake_bin" "$root/foreign-extension" "$other_checkout/extension" "$other_checkout/extension-legacy"
  make_installer_fakes "$fake_bin"

  # A link to either variant of this checkout is owned: disabled and removed.
  for step in '42|extension-legacy' '46|extension'; do
    shell_major="${step%%|*}"
    variant="${step#*|}"
    home_dir="$root/home-owned-$variant"
    mkdir -p "$home_dir"
    run_install "$home_dir" "$fake_bin/gnome-shell-$shell_major" "$fake_bin/gnome-extensions" >/dev/null
    assert_eq "$repo_root/$variant" "$(readlink "$home_dir/$installer_extension_link")" "installed $variant link"
    rm -f "$fake_bin/gnome-extensions.log" "$fake_bin/systemd-inhibit.log"
    run_uninstall "$home_dir" "$fake_bin"
    assert_no_path "$home_dir/$installer_extension_link" "uninstall of the $variant link"
    assert_no_path "$home_dir/.local/bin/nosleep" "uninstall of the CLI link next to $variant"
    assert_eq "disable $installer_uuid" "$(cat "$fake_bin/gnome-extensions.log")" "gnome-extensions calls when uninstalling $variant"
    [[ -s "$fake_bin/systemd-inhibit.log" ]] || {
      printf 'FAIL: uninstall of the %s link did not stop NoSleep through the fake systemd-inhibit\n' "$variant" >&2
      exit 1
    }
  done

  # Foreign links and links into another checkout are neither disabled nor removed.
  rm -f "$fake_bin/gnome-extensions.log"
  index=0
  for foreign in "$root/foreign-extension" "$other_checkout/extension" "$other_checkout/extension-legacy"; do
    index=$((index + 1))
    home_dir="$root/home-foreign-$index"
    mkdir -p "$home_dir/$installer_extension_root"
    ln -s "$foreign" "$home_dir/$installer_extension_link"
    run_uninstall "$home_dir" "$fake_bin"
    assert_eq "$foreign" "$(readlink "$home_dir/$installer_extension_link")" "uninstall preserves the link to ${foreign#"$root"/}"
  done
  assert_no_path "$fake_bin/gnome-extensions.log" 'gnome-extensions calls for links not owned by this checkout'
}

test_install_guidance() {
  local enable_line enable_step fake_bin home_dir output restart_line restart_step root run

  root="$(make_tmp_dir)"
  fake_bin="$root/bin"
  mkdir -p "$fake_bin"
  make_installer_fakes "$fake_bin"
  restart_step='Restart GNOME Shell'
  enable_step="gnome-extensions enable $installer_uuid"

  # A failed enable needs both steps in order, also when the link is unchanged:
  # nothing was recorded, so the extension stays disabled after the restart.
  home_dir="$root/home-enable-fails"
  mkdir -p "$home_dir"
  for run in first unchanged; do
    output="$(run_install "$home_dir" "$fake_bin/gnome-shell-42" "$fake_bin/gnome-extensions-fail")"
    assert_output_contains "$output" "$restart_step" "$run install with a failing enable"
    assert_output_contains "$output" "$enable_step" "$run install with a failing enable"
    assert_output_lacks "$output" 'Try:' "$run install with a failing enable"
    restart_line="$(grep -n -m 1 -F -e "$restart_step" <<<"$output")"
    enable_line="$(grep -n -m 1 -F -e "$enable_step" <<<"$output")"
    [[ "${restart_line%%:*}" -lt "${enable_line%%:*}" ]] || {
      printf 'FAIL: %s install with a failing enable: restart step is not first:\n%s\n' "$run" "$output" >&2
      exit 1
    }
  done

  # Without any gnome-extensions command the extension is not enabled either.
  home_dir="$root/home-no-gnome-extensions"
  mkdir -p "$home_dir"
  for run in first unchanged; do
    output="$(run_install "$home_dir" "$fake_bin/gnome-shell-46" "$fake_bin/gnome-extensions-missing")"
    assert_eq "$repo_root/extension" "$(readlink "$home_dir/$installer_extension_link")" "$run install without gnome-extensions"
    assert_output_contains "$output" 'gnome-extensions was not found' "$run install without gnome-extensions"
    assert_output_contains "$output" "$restart_step" "$run install without gnome-extensions"
    assert_output_contains "$output" "$enable_step" "$run install without gnome-extensions"
  done

  # A new or changed link with a successful enable only needs the restart.
  home_dir="$root/home-enable-works"
  mkdir -p "$home_dir"
  output="$(run_install "$home_dir" "$fake_bin/gnome-shell-42" "$fake_bin/gnome-extensions")"
  assert_output_contains "$output" "$restart_step" 'first install with a working enable'
  assert_output_lacks "$output" "$enable_step" 'first install with a working enable'

  output="$(run_install "$home_dir" "$fake_bin/gnome-shell-42" "$fake_bin/gnome-extensions")"
  assert_output_lacks "$output" "$restart_step" 'unchanged install with a working enable'
  assert_output_lacks "$output" "$enable_step" 'unchanged install with a working enable'

  output="$(run_install "$home_dir" "$fake_bin/gnome-shell-46" "$fake_bin/gnome-extensions")"
  assert_output_contains "$output" "$restart_step" 'variant switch with a working enable'
  assert_output_lacks "$output" "$enable_step" 'variant switch with a working enable'
}

# Enabling stays with gnome-extensions: with a mismatched HOME and session bus,
# writing org.gnome.shell settings could clobber the real enabled list.
test_installer_leaves_shell_settings_alone() {
  if grep -n -E 'gsettings|dconf' "$repo_root/install.sh" "$repo_root/uninstall.sh" >&2; then
    printf 'FAIL: installer scripts must not touch GNOME Shell settings\n' >&2
    exit 1
  fi
}

test_syntax
test_js_lint
test_status_list_failure
test_path_poisoning
test_lock_symlink
test_state_dir_symlink
test_state_dir_concurrent_create
test_cli_state
test_extension_metadata
test_extension_variants
test_install_uninstall
test_install_variant_selection
test_install_undetectable_shell
test_install_variant_switch
test_install_foreign_extension_links
test_uninstall_variant_ownership
test_install_guidance
test_installer_leaves_shell_settings_alone

printf 'All tests passed.\n'

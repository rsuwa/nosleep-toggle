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
  local runtime_dir fake_bin marker

  runtime_dir="$(make_tmp_dir)"
  fake_bin="$(make_tmp_dir)"
  marker="$runtime_dir/path-command-called"
  printf '#!/bin/sh\ntouch %q\nexec /bin/bash "$@"\n' "$marker" >"$fake_bin/bash"
  printf '#!/usr/bin/env bash\nexit 77\n' >"$fake_bin/systemd-inhibit"
  printf '#!/usr/bin/env bash\ntouch %q\nexit 77\n' "$marker" >"$fake_bin/mkdir"
  printf '#!/usr/bin/env bash\ntouch %q\nexit 77\n' "$marker" >"$fake_bin/chmod"
  chmod +x "$fake_bin/bash"
  chmod +x "$fake_bin/systemd-inhibit"
  chmod +x "$fake_bin/mkdir" "$fake_bin/chmod"

  assert_eq off "$(PATH="$fake_bin:$PATH" XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" status)" 'status ignores poisoned PATH'
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

test_cli_state() {
  local blocker_pid cli_pid counter fake_bin fields pid proc_stat real_inhibit runtime_dir
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

test_extension_metadata() {
  local extension_uuid metadata_uuid icon

  extension_uuid="nosleep-toggle@systemd-inhibit.local"
  metadata_uuid="$(sed -n 's/.*"uuid": *"\([^"]*\)".*/\1/p' "$repo_root/extension/metadata.json")"
  assert_eq "$extension_uuid" "$metadata_uuid" 'metadata UUID'

  grep -F '"shell-version": ["46"]' "$repo_root/extension/metadata.json" >/dev/null || {
    printf 'FAIL: metadata shell-version does not include GNOME Shell 46\n' >&2
    exit 1
  }

  while IFS= read -r icon; do
    [[ -f "$repo_root/extension/icons/$icon" ]] || {
      printf 'FAIL: missing extension icon: %s\n' "$icon" >&2
      exit 1
    }
  done < <(grep -o 'nosleep-[a-z]*-symbolic\.svg' "$repo_root/extension/extension.js" | sort -u)

  grep -F '_signalControl(control, SIGTERM)' "$repo_root/extension/extension.js" >/dev/null || {
    printf 'FAIL: extension does not terminate subprocesses gracefully first\n' >&2
    exit 1
  }
  grep -F "const SETSID_PATH = '/usr/bin/setsid';" "$repo_root/extension/extension.js" >/dev/null || {
    printf 'FAIL: extension does not launch controls in a new session\n' >&2
    exit 1
  }
  grep -F 'get_identifier' "$repo_root/extension/extension.js" >/dev/null || {
    printf 'FAIL: extension does not track the subprocess process group\n' >&2
    exit 1
  }
  grep -F 'processGroupId' "$repo_root/extension/extension.js" >/dev/null || {
    printf 'FAIL: extension does not signal subprocess process groups\n' >&2
    exit 1
  }
  grep -F 'SIGKILL' "$repo_root/extension/extension.js" >/dev/null || {
    printf 'FAIL: extension does not keep a process group force-kill fallback\n' >&2
    exit 1
  }
  grep -F 'FORCE_EXIT_DELAY_SECONDS' "$repo_root/extension/extension.js" >/dev/null || {
    printf 'FAIL: extension does not keep a delayed force-exit fallback\n' >&2
    exit 1
  }
  grep -F '_stateGeneration' "$repo_root/extension/extension.js" >/dev/null || {
    printf 'FAIL: extension does not guard stale refresh results\n' >&2
    exit 1
  }
}

test_install_uninstall() {
  local home_dir runtime_dir fake_bin marker

  home_dir="$(make_tmp_dir)"
  runtime_dir="$(make_tmp_dir)"
  fake_bin="$(make_tmp_dir)"
  marker="$home_dir/path-nosleep-called"

  mkdir -p "$home_dir/.local/bin"
  ln -s /tmp/foreign-nosleep "$home_dir/.local/bin/nosleep"
  printf '#!/usr/bin/env bash\necho enable failed >&2\nexit 1\n' >"$fake_bin/gnome-extensions"
  chmod +x "$fake_bin/gnome-extensions"

  HOME="$home_dir" PATH="$fake_bin:$PATH" "$repo_root/install.sh" >/dev/null 2>/dev/null
  assert_eq "$repo_root/bin/nosleep" "$(readlink "$home_dir/.local/bin/nosleep")" 'installed CLI link'
  compgen -G "$home_dir/.local/bin/nosleep.bak.*/nosleep" >/dev/null || {
    printf 'FAIL: install did not back up foreign symlink\n' >&2
    exit 1
  }

  printf '#!/usr/bin/env bash\ntouch %q\n' "$marker" >"$fake_bin/nosleep"
  chmod +x "$fake_bin/nosleep"

  HOME="$home_dir" XDG_RUNTIME_DIR="$runtime_dir" PATH="$fake_bin:$PATH" "$repo_root/uninstall.sh" >/dev/null 2>/dev/null
  [[ ! -e "$marker" ]] || {
    printf 'FAIL: uninstall called nosleep from PATH\n' >&2
    exit 1
  }
  [[ ! -e "$home_dir/.local/bin/nosleep" ]] || {
    printf 'FAIL: uninstall left CLI link behind\n' >&2
    exit 1
  }
}

test_syntax
test_status_list_failure
test_path_poisoning
test_lock_symlink
test_cli_state
test_extension_metadata
test_install_uninstall

printf 'All tests passed.\n'

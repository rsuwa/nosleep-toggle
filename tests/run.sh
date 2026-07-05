#!/usr/bin/env bash
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

  if PATH="$fake_bin:$PATH" XDG_RUNTIME_DIR="$runtime_dir" "$repo_root/bin/nosleep" status >/dev/null 2>&1; then
    printf 'FAIL: status succeeded when systemd-inhibit --list failed\n' >&2
    exit 1
  fi
}

test_cli_state() {
  local fake_bin runtime_dir pid spoof_pid

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
  compgen -G "$home_dir/.local/bin/nosleep.bak.*" >/dev/null || {
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
test_cli_state
test_install_uninstall

printf 'All tests passed.\n'

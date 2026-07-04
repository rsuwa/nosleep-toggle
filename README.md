# nosleep-toggle

Ubuntu GNOME の上バーから、蓋閉じスリープとアイドルスリープの抑止を ON/OFF する小さなツールです。

`systemd-inhibit` を使っているため、設定を書き換えずに一時的にスリープを止められます。
Claude Code や Codex CLI などの長めのCLI処理を動かしたまま、短時間だけPCを移動したい用途を想定しています。

## 対応環境

- Ubuntu 24.04
- GNOME Shell 46
- systemd 環境

Ubuntu 22.04 / GNOME Shell 42 はまだ未対応です。

## インストール

```bash
git clone git@github.com:rsuwa/nosleep-toggle.git ~/oss/nosleep-toggle
cd ~/oss/nosleep-toggle
./install.sh
```

GNOME Shell が新しい拡張をすぐ認識しない場合は、一度ログアウトしてログインしてください。

## 使い方

上バー右側の `OFF` / `ON` 表示をクリックします。

- `ON`: 蓋閉じスリープ、通常スリープ、アイドルスリープを抑止します
- `OFF`: 通常どおりスリープする状態に戻します

CLI からも操作できます。

```bash
nosleep on
nosleep off
nosleep toggle
nosleep status
```

コマンド実行中だけ抑止したい場合も同じ `nosleep` を使います。

```bash
nosleep run codex
nosleep codex
nosleep shell
```

## 注意

バッグ内でPCを動かし続けると発熱します。
短時間の移動向けに使ってください。

## English

`nosleep-toggle` is a small Ubuntu GNOME tool that toggles lid-close suspend and idle sleep inhibition from the top bar.

It uses `systemd-inhibit`, so it temporarily blocks sleep without changing permanent power settings.
It is intended for short moves while long-running CLI tools such as Claude Code or Codex CLI keep running.

### Supported Environment

- Ubuntu 24.04
- GNOME Shell 46
- systemd

Ubuntu 22.04 / GNOME Shell 42 is not supported yet.

### Install

```bash
git clone git@github.com:rsuwa/nosleep-toggle.git ~/oss/nosleep-toggle
cd ~/oss/nosleep-toggle
./install.sh
```

If GNOME Shell does not detect the new extension immediately, log out and log back in.

### Usage

Click the `OFF` / `ON` indicator in the top bar.

- `ON`: blocks lid-close suspend, normal sleep, and idle sleep
- `OFF`: restores normal sleep behavior

CLI usage:

```bash
nosleep on
nosleep off
nosleep toggle
nosleep status
```

Use the same `nosleep` command to inhibit sleep only while a command runs:

```bash
nosleep run codex
nosleep codex
nosleep shell
```

### Safety

Running a laptop while it is inside a bag can generate heat.
Use this for short moves, not long unattended runs.

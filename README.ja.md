# nosleep-toggle

[English README](README.md)

`nosleep-toggle` は、Ubuntu GNOME の上バーから蓋閉じスリープとアイドルスリープの抑止を切り替えるツールです。

`systemd-inhibit` を使うため、電源設定を書き換えずに一時的にスリープを止められます。
長時間動くCLIコマンドを実行したまま、短時間だけPCを移動したい用途を想定しています。

## 対応環境

- Ubuntu 24.04
- GNOME Shell 46
- systemd 環境

Ubuntu 22.04 / GNOME Shell 42 にはまだ対応していません。

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

コマンド実行中だけ抑止したい場合も、同じ `nosleep` を使います。

```bash
nosleep long-command --option
nosleep run long-command --option
nosleep shell
```

`nosleep run ...` は明示形です。
実行したいコマンド名が `nosleep` のサブコマンド名と衝突する場合に使います。

## 注意

バッグ内でPCを動かし続けると発熱します。
短時間の移動向けに使ってください。

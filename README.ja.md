# nosleep-toggle

[English README](README.md)

`nosleep-toggle` は、Ubuntu GNOME の上バーから蓋閉じスリープとアイドルスリープの抑止を切り替えるツールです。

`systemd-inhibit` を使うため、電源設定を書き換えずに一時的にスリープを止められます。
長時間動くCLIコマンドを実行したまま、短時間だけPCを移動したい用途を想定しています。

## 対応環境

- Ubuntu 24.04 / GNOME Shell 46
- Ubuntu 22.04 / GNOME Shell 42
- systemd 環境
- `systemd-inhibit`、`setsid`、`flock`

これ以外の GNOME Shell バージョンには対応していません。
その場合、インストーラは警告を表示したうえで拡張をリンクしますが、GNOME Shell が拡張を非互換（out of date）と判定することがあります。

## インストール

```bash
git clone https://github.com/rsuwa/nosleep-toggle.git
cd nosleep-toggle
./install.sh
```

インストーラは、このチェックアウトへのシンボリックリンクを作成します。
インストール後も、clone したリポジトリは残してください。
インストールされた CLI と拡張はシンボリックリンクなので、このチェックアウトでの編集、ブランチ切り替え、`git pull` はインストール済みの動作へすぐ反映されます。
自分で管理しているチェックアウトからだけインストールしてください。

拡張のリンクは、インストールされている GNOME Shell のバージョンに合ったディレクトリを指します（GNOME Shell 46 では `extension/`、GNOME Shell 42 では `extension-legacy/`）。
Ubuntu や GNOME Shell をアップグレードしたとき（たとえば Ubuntu 22.04 から 24.04）は、`./install.sh` をもう一度実行してください。
Ubuntu 22.04 に対応する前の nosleep-toggle を Ubuntu 22.04 でインストールしていた場合も、一度だけ再実行してください。

GNOME Shell が新しい拡張や変更された拡張を認識するのは、起動時だけです。
初回インストール後は、まず GNOME Shell を再起動してください。
再起動するには、一度ログアウトしてログインします（X11 セッションでは、代わりに Alt+F2 を押し、`r` と入力して Enter を押す方法も使えます）。
再起動後に、次のコマンドで拡張を有効化するか、`./install.sh` をもう一度実行してください。

```bash
gnome-extensions enable nosleep-toggle@systemd-inhibit.local
```

すでに有効になっていた拡張のリンク先をインストーラが切り替えただけの場合は、GNOME Shell を再起動するだけで済みます。
どの手順が必要かは、インストーラが表示します。

## アンインストール

```bash
./uninstall.sh
```

アンインストーラは、永続的な NoSleep を無効化し、可能であれば拡張を無効化し、このチェックアウトを指すシンボリックリンクだけを削除します。

## 使い方

上バー右側の状態表示をクリックします。

- `Sleep`: 通常どおりスリープします
- `Awake`: `nosleep off` するまでスリープを抑止します
- `Run`: `nosleep` 経由で実行したコマンドが動いている間だけスリープを抑止します

`Sleep` をクリックすると、NoSleep が有効になります。
`Awake` をクリックすると、通常どおりスリープする状態に戻ります。
`Run` をクリックすると、実行中のコマンドはそのままにして、NoSleep を `Awake` に切り替えます。

CLI からも操作できます。

```bash
nosleep on
nosleep off
nosleep toggle
nosleep status
```

`nosleep status` は `off`、`on`、`running` のいずれかを出力します。
`nosleep --raw-status` は、トラブルシュート用にシステム全体の生の `systemd-inhibit` 一覧を出力します。
古い `nosleep --status` も引き続き使えます。

コマンド実行中だけ抑止したい場合も、同じ `nosleep` を使います。

```bash
nosleep long-command --option
nosleep run long-command --option
nosleep shell
nosleep
```

`nosleep run ...` は明示形です。
実行したいコマンド名が `nosleep` のサブコマンド名と衝突する場合に使います。
引数なしで `nosleep` を実行すると、抑止されたシェルを起動します。

## テスト

```bash
npm install
npm run lint:js
./tests/run.sh
```

lint ツール（ESLint 9）には Node.js 18.18 以降（`^18.18.0 || ^20.9.0 || >=21.1.0`）が必要です。
Ubuntu 22.04 の apt 版 Node.js 12 は古すぎて lint ツールが動かないため、nvm などで新しい Node.js を使ってください。
nosleep-toggle を使うだけなら Node.js は不要です。

テストスクリプトは、一時的なランタイムディレクトリとホームディレクトリを使います。
npm 依存関係がインストール済みで、対応バージョンの Node.js を検出できた場合は JavaScript lint も実行し、そうでない場合は理由を表示してそのステップをスキップします。
別の `nosleep` inhibitor がすでに有効な場合、CLI 状態テストはスキップします。

## 注意

バッグ内でPCを動かし続けると発熱します。
短時間の移動向けに使ってください。

NoSleep は、蓋スイッチ、スリープ/ハイバネート、アイドルスリープに対する logind inhibitor を要求します。
シャットダウン、バッテリー危険時の動作、熱保護による停止、管理者ポリシー、クラッシュ、ログアウト、システム更新を止めるものではありません。
GNOME 拡張を無効化すると上バーの操作UIは消えますが、すでに有効な永続 inhibitor が必ず停止するわけではありません。
NoSleep が有効な場合は、拡張を無効化する前に `nosleep off` を実行してください。

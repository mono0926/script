# Skills Optimizer CLI

Anthropics/GitHub上のスキルを簡単に管理・最適化するためのDart CLIツールです。

## 特徴

- **スキルの簡単インストール**: `skills.yaml` に記述されたスキルを、AnthropicsやGitHubから一括でインストール・同期します。
- **ワイルドカード/除外サポート**: スキル名にワイルドカード（`*`）や除外（`!`）を使用して、柔軟に構成を管理できます。
- **並列インストール**: 複数のリポジトリからのスキルインストールを並列で実行し、高速にセットアップを完了します。
- **Skills Optimizerスキルの同梱**: スキルの構成自体を最適化するための `skills-optimizer` スキルが標準で同梱されており、自動的にインストールされます。

## インストール

Dart SDKがインストールされている環境で、以下のコマンドを実行してください。

```bash
dart pub global activate skills_optimizer
```

## 使い方

初めて使用する場合は、まず `init` コマンドで設定ファイルの雛形を生成します。

```bash
skills_optimizer init
```

次に設定ファイルを編集します（デフォルトのエディタで開きます）。

```bash
skills_optimizer config
```

設定が完了したら、`setup` コマンドでスキルをインストールします。

```bash
skills_optimizer setup
```

### サブコマンド一覧

- `init`: `~/.config/skills_optimizer/config.yaml` を生成します。
- `config`: 設定ファイルをエディタで開きます。
- `setup`: 設定に基づいてスキルをインストール・同期します。
- `list`: 現在の設定内容とインストール状況を表示します。

### 環境要件

- **Node.js**: `npx` コマンドを使用するため、Node.js がインストールされている必要があります。
- **Git**: 外部リポジトリからスキルを取得する場合に必要です。

### 設定ファイルの場所

デフォルトで以下の場所を探索します：

- `~/.config/skills_optimizer/config.yaml`

また、`-c` または `--config` オプションを使用して、明示的にパスを指定することも可能です。

```bash
skills_optimizer setup --config my-skills.yaml
```

### 設定ファイルの例

```yaml
global:
  anthropics/skills:
    - '*' # 全スキル
    - '!recipe-*' # recipeで始まるスキルを除外

./path/to/project:
  mono0926/skills:
    - flutter-* # flutter関連のスキルのみ
```

### オプション

- `--dry-run`: 実際にインストールを行わず、実行されるコマンドの確認のみ行います。

## ライセンス

MIT

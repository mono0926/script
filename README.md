- 様々なスクリプトの置き場
- `bin/`にはコマンドのエントリポイントを配置
- `lib/src/commands/` などに実際のコマンド処理や共通ロジックを配置し、`CommandRunner`などを活用してテスタビリティと拡張性を高める設計を推奨
- スクリプトの実行やタスク管理には [Task](https://taskfile.dev/) を使用 (`Taskfile.yaml` に定義)

## 主要コマンド

### `setup_skills`

`config/skills.yaml` を読み込み、必要なスキルを一括インストール・同期します。

#### インストール仕様

- **ワイルドカード指定**: `*` を含むパターンを記述すると、リポジトリ内の合致するスキルをすべてインストールします。
- **除外指定**: `!` プレフィックスを使用すると、特定のスキル（またはパターンに一致するもの）をインストール対象から外します。
- **ロックファイル同期**: インストール状況は `~/.agents/.skill-lock.json`（グローバル）または各ディレクトリの `skills-lock.json` と同期されます。

#### `skills.yaml` の書き方例

```yaml
global:
  # 全スキル対象
  mono0926/skills:

  # 特定コンポーネントのみ（ワイルドカード）
  googleworkspace/cli:
    - '*calendar*'
    - '*docs*'

  # すべて対象だが一部除外
  firebase/agent-skills:
    - '*'
    - '!recipe-*'

  # 個別指定
  github/awesome-copilot:
    - gh-cli
```

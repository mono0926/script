- 様々なスクリプトの置き場
- `bin/`にはコマンドのエントリポイントを配置
- `lib/src/commands/` などに実際のコマンド処理や共通ロジックを配置し、`CommandRunner`などを活用してテスタビリティと拡張性を高める設計を推奨
- スクリプトの実行やタスク管理には [Task](https://taskfile.dev/) を使用 (`Taskfile.yaml` に定義)

## 主要コマンド

### `skills_sync` (旧 `setup_skills`)

`setup_skills` コマンドはより汎用的な **`skills-sync`** ツールとして独立・リリースされました。
今後のスキルの過不足ない同期・管理には、以下の新しいツールを利用してください。

- **GitHub**: [mono0926/skills-sync](https://github.com/mono0926/skills-sync)
- **pub.dev**: [skills_sync](https://pub.dev/packages/skills_sync)

#### インストール方法

```bash
dart pub global activate skills_sync
```

#### 使い方

```bash
skills_sync sync
```

詳細な使い方は、提供されている各ドキュメントを参照してください。

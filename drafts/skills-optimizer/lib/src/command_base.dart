import 'dart:io';
import 'dart:isolate';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

abstract class SkillsOptimizerCommand extends Command<int> {
  SkillsOptimizerCommand() {
    argParser.addOption(
      'config',
      abbr: 'c',
      help: 'skills.yaml のパスを指定します',
    );
  }

  /// インインストールされているスキルの内容を埋め込んだ定数
  /// `dart compile exe` 等でバイナリ化された際も利用可能にするため
  static const String bundledSkillContent = r'''
# Skills Optimizer Skill

... (スキルの内容をここに埋め込む) ...
''';

  Future<bool> checkNpx() async {
    try {
      final result = await Process.run('npx', ['--version'], runInShell: true);
      return result.exitCode == 0;
    } on Exception catch (_) {
      return false;
    }
  }

  File? findConfigFile(String? explicitPath) {
    if (explicitPath != null) {
      final file = File(explicitPath);
      return file.existsSync() ? file : null;
    }

    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) {
      return null;
    }

    final file = File(
      p.join(home, '.config', 'skills_optimizer', 'config.yaml'),
    );
    return file.existsSync() ? file : null;
  }

  String expandPath(String path) {
    if (path.startsWith('~/')) {
      final home = Platform.environment['HOME'] ?? '';
      return path.replaceFirst('~/', '$home/');
    }
    return path;
  }

  /// 同梱スキルのパス（取得できない場合は null）
  /// 正式版ではアセットとして埋め込むのが確実
  Future<String?> getBundledSkillPath() async {
    // 1. まず package URI での解決を試みる (pub global activate 用)
    try {
      final uri = await Isolate.resolvePackageUri(
        Uri.parse(
          'package:skills_optimizer/src/skills/skills-optimizer/SKILL.md',
        ),
      );
      if (uri != null) {
        return File(uri.toFilePath()).parent.path;
      }
    } on Exception catch (_) {}

    // 2. 解決できない場合（バイナリ配布など）、
    // ~ /.config/skills_optimizer/.internal/skills-optimizer/SKILL.md に書き出してそのパスを返す
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) {
        return null;
      }

      final dir = Directory(
        p.join(
          home,
          '.config',
          'skills_optimizer',
          '.internal',
          'skills-optimizer',
        ),
      );
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final file = File(p.join(dir.path, 'SKILL.md'));
      if (!file.existsSync() || file.lengthSync() == 0) {
        file.writeAsStringSync(_bundledSkillContent);
      }
      return dir.path;
    } on Exception catch (_) {}

    return null;
  }

  static const String _bundledSkillContent = r'''---
name: skills-optimizer
description: ユーザーのskills.yaml設定を最適化し、整理・管理します。重要: ユーザーが「スキルを整理して」「スキルを最適化して」「スキルをクリーンアップして」と求めた場合や、コンテキストが散らかっていると感じてインストール済みのスキルを見直したい場合にこのスキルをトリガーしてください。ユーザーの普段の開発スタックを把握（または質問して確認）した上で、最適な新しいスキルを提案したり、使われていないスキルを指摘したり、安全な設定を保ちます。手動のファイル編集を促されるのを待たず、直接このスキルを使用してください。
---

# Skills Optimizer (スキル最適化)

`config/skills.yaml` ファイルを最適化する専属スキルです。不要なスキルを整理し、ユーザーのプロファイルに合った高品質なスキルを補填しつつ、クリーンで安全な環境を維持します。

## コンテキスト: ユーザー設定の把握

最適化を行う前に、ユーザーの**主要な技術スタック、好むアーキテクチャ（ライブラリなど）、開発スタイル**を把握する必要があります。
事前に共有されているプロファイル情報や会話履歴からユーザーの特性を読み取ってください。
**【重要】** もし理解が不足している（どんな技術をメインで使っているか不明な）場合は、最適化の提案を作る前に必ずユーザーに質問してください。

- **共通の目標**: インストール済みスキルが初期コンテキストに与える影響（汚染）は「名前と説明文」のみでわずかである点も加味しつつ、ユーザーの意向（発動時の有益性を優先するか、わずかなノイズも削るか）を含めてバランスの良い提案をすること。

## ワークフロー

このスキルが呼び出された際は、厳密に以下の手順に従ってください：

### 1. 現状の分析

現在の `config/skills.yaml` を読み取ります。インストールされているリポジトリ、ワイルドカードインストール (`*`)、除外されているスキル (`!`) に注目してください。

### 2. 足りない高品質スキルの特定とセキュリティ監査

ユーザーの技術スタック（例: Anthropic, Gemini, その他ユーザーが好んでいるフレームワークの公式リポジトリ等）に関連する最高品質のスキルを考慮します。ユーザーのアーキテクチャやコード品質の方針に最も貢献できる追加スキルに焦点を当ててください。

【重要：セキュリティと品質の事前監査】
`npx skills` 自体は対象のリポジトリから構成ファイルをダウンロードするだけであり、中身の安全性や意図を深く検証する仕組みは持っていません。そのため、**提案する前に対象スキルのリポジトリ内容（SKILL.md、および scripts/ 以下の実行ファイル等）をツールを使って実際に読みに行き、以下の点を入念に監査してください。**

- **安全性の確認**: 不正な外部通信（データ送出）、破壊的なコマンド実行（`rm -rf` 等の過剰な削除権限）、難読化された怪しいスクリプトが含まれていないか。
- **品質の確認**: プロンプトの内容がユーザーの開発スタイル（モダン・高品質）と合致しているか。雑な命令やプロンプトインジェクションのリスクがないか。
  ※ この監査なしに新しいスキルをユーザーに提案してはいけません。

### 3. 不要なスキルのスクリーニングとユーザー確認

理解したユーザーのコアスタックから外れるスキルを探します。

- **絶対に自動で削除しないでください**。
- 明らかに重複している、または完全に無関係で有害な場合にのみ削除候補としてリストアップします（※「念のため入れておく」レベルのものは残して構みます）。

### 4. 最適化プランの提案

分析・監査結果をユーザーに伝えてください：

- **追加の提案**: 新しく発見したおすすめの追加スキルとその理由（ユーザーのスタックにどう適合するか）をリストアップします。**ソースの監査を実施し、セキュリティリスクがなかった旨**も併せて伝えます。
- **削除 / 保持の確認**: 「スタック外」と判断したスキルをリストアップし、ユーザーに明確に尋ねます：「たまに使うために残しておきますか？それともコンテキスト節約のために基本は削りますか？（コンテキスト節約をする場合、必要になった時に都度導入できます）」
- **改善案**: 冗長なスキルや、制限すべき広すぎるワイルドカードインポートがあれば指摘します。

### 5. 変更の適用

ユーザーから希望する対応の回答があったら：

1. ユーザーが選んだ追加・削除内容に合わせて `config/skills.yaml` を更新します。
2. 既存のYAMLコメントやフォーマットの構造は維持してください。
3. task setup-skills` を実行して変更を反映するよう、ユーザーに伝えます。

## ベストプラクティス

- **提案に対するユーザーの明確な同意がない限り、絶対に `skills.yaml` を変更しないでください**。
- コミュニケーションは役に立つ内容で簡潔丁寧に行い、言語や振る舞いはユーザー固有のルールに従ってください。
''';

  List<SkillEntry> parseSkillEntries(YamlMap yaml) {
    final entries = <SkillEntry>[];

    if (yaml['global'] is YamlMap) {
      entries.addAll(_parseSourceMap(yaml['global'] as YamlMap, null));
    }

    for (final MapEntry(key: pathStr, value: pathValue) in yaml.entries) {
      if (pathStr == 'global') {
        continue;
      }
      if (pathStr is! String || pathValue is! YamlMap) {
        continue;
      }
      entries.addAll(_parseSourceMap(pathValue, pathStr));
    }

    return entries;
  }

  Iterable<SkillEntry> _parseSourceMap(YamlMap map, String? targetPath) sync* {
    for (final MapEntry(:key, :value) in map.entries) {
      if (key is! String) {
        continue;
      }

      final source = key;
      final skills = <String>[];
      final patterns = <String>[];
      final excludes = <String>[];
      final excludePatterns = <String>[];

      void processValue(dynamic v) {
        if (v is String) {
          if (v.startsWith('!')) {
            final p = v.substring(1);
            if (p.contains('*')) {
              excludePatterns.add(p);
            } else {
              excludes.add(p);
            }
          } else if (v.contains('*')) {
            patterns.add(v);
          } else {
            skills.add(v);
          }
        }
      }

      if (value is YamlList) {
        value.forEach(processValue);
      } else if (value != null) {
        continue;
      }

      yield SkillEntry(
        source: source,
        skills: skills,
        patterns: patterns,
        excludes: excludes,
        excludePatterns: excludePatterns,
        targetPath: targetPath,
      );
    }
  }

  RegExp patternToRegExp(String pattern) {
    final escaped = pattern
        .replaceAll('.', r'\.')
        .replaceAll('+', r'\+')
        .replaceAll('?', r'\?')
        .replaceAll('(', r'\(')
        .replaceAll(')', r'\)')
        .replaceAll('[', r'\[')
        .replaceAll(']', r'\]')
        .replaceAll('{', r'\{')
        .replaceAll('}', r'\}')
        .replaceAll('^', r'\^')
        .replaceAll(r'$', r'\$')
        .replaceAll('|', r'\|')
        .replaceAll('*', '.*');
    return RegExp('^$escaped\$', caseSensitive: false);
  }
}

class SkillEntry {
  SkillEntry({
    required this.source,
    this.skills = const [],
    this.patterns = const [],
    this.excludes = const [],
    this.excludePatterns = const [],
    this.targetPath,
  });

  final String source;
  final List<String> skills;
  final List<String> patterns;
  final List<String> excludes;
  final List<String> excludePatterns;
  final String? targetPath;
}

import 'dart:io';

import 'package:script/logger.dart';
import 'package:yaml/yaml.dart';

/// skills.yaml を読み込み、各スキルをインストールするスクリプト。
///
/// 使い方:
///   dart run bin/setup_skills.dart          # 実行
///   dart run bin/setup_skills.dart --dry-run # コマンド確認のみ
void main(List<String> arguments) async {
  setupLogger();

  final dryRun = arguments.contains('--dry-run');

  final configFile = File('config/skills.yaml');
  if (!configFile.existsSync()) {
    logger.severe('config/skills.yaml が見つかりません');
    exit(1);
  }

  final yaml = loadYaml(configFile.readAsStringSync()) as YamlMap;
  final entries = _parseSkillEntries(yaml);

  if (dryRun) {
    logger.info('=== Dry Run: 以下のコマンドを実行します ===\n');
  }

  var hasError = false;
  for (final entry in entries) {
    final command = _buildCommand(entry);
    final commandStr = command.join(' ');

    if (dryRun) {
      logger.info(commandStr);
      continue;
    }

    logger.info('\n📦 $commandStr');
    final result = await Process.run(
      command.first,
      command.sublist(1),
      runInShell: true,
    );

    stdout.write(result.stdout);
    if (result.exitCode != 0) {
      stderr.write(result.stderr);
      logger.warning('⚠️  終了コード: ${result.exitCode}');
      hasError = true;
    }
  }

  if (!dryRun) {
    if (hasError) {
      logger.warning('\n⚠️  一部のスキルでエラーが発生しました');
    } else {
      logger.info('\n✅ 全てのスキルをインストールしました');
    }
  }

  if (hasError) {
    exit(1);
  }
}

/// skills.yaml のエントリをパースする。
///
/// YAML構造:
/// ```yaml
/// google-gemini/gemini-skills:         # 全スキル
/// firebase/skills:                      # 全スキル
/// vercel-labs/skills:                   # 指定スキルのみ
///   - find-skills
/// ```
List<_SkillEntry> _parseSkillEntries(YamlMap yaml) {
  final entries = <_SkillEntry>[];

  for (final MapEntry(:key, :value) in yaml.entries) {
    if (key is! String) {
      logger.warning('不正なキーをスキップ: $key');
      continue;
    }

    final source = key;
    final skills = <String>[];

    if (value is YamlList) {
      for (final skill in value) {
        skills.add(skill as String);
      }
    } else if (value != null) {
      logger.warning('不正な値をスキップ ($source): $value');
      continue;
    }

    entries.add(_SkillEntry(source: source, skills: skills));
  }

  return entries;
}

/// npx skills add コマンドを組み立てる。
List<String> _buildCommand(_SkillEntry entry) {
  final args = [
    'npx',
    'skills',
    'add',
    entry.source,
    '--global',
    '--agent',
    'antigravity',
    '-y',
  ];

  if (entry.skills.isNotEmpty) {
    args.addAll(['--skill', ...entry.skills]);
  }

  return args;
}

class _SkillEntry {
  _SkillEntry({required this.source, this.skills = const []});

  final String source;
  final List<String> skills;
}

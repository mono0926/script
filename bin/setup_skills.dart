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

  final yaml = loadYaml(configFile.readAsStringSync()) as YamlList;
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
/// - source: google-gemini/gemini-skills       # 全スキル
/// - source: firebase/skills                    # 全スキル
/// - source: vercel-labs/skills                 # 指定スキルのみ
///   skills:
///     - find-skills
/// ```
List<_SkillEntry> _parseSkillEntries(YamlList yaml) {
  final entries = <_SkillEntry>[];

  for (final item in yaml) {
    if (item is! YamlMap) {
      logger.warning('不正なエントリをスキップ: $item');
      continue;
    }

    final source = item['source'] as String?;
    if (source == null) {
      logger.warning('source が未指定のエントリをスキップ: $item');
      continue;
    }

    final skillsYaml = item['skills'];
    final skills = <String>[];
    if (skillsYaml is YamlList) {
      for (final skill in skillsYaml) {
        skills.add(skill as String);
      }
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

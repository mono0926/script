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
  final skippedPaths = <String>[];
  final installedSkills = <String?, List<_SkillEntry>>{};

  for (final entry in entries) {
    String? workingDirectory;
    if (entry.targetPath != null) {
      workingDirectory = _expandPath(entry.targetPath!);
      if (!Directory(workingDirectory).existsSync()) {
        if (!skippedPaths.contains(entry.targetPath)) {
          skippedPaths.add(entry.targetPath!);
        }
        continue;
      }
    }

    final command = _buildCommand(entry);
    final commandStr = command.join(' ');

    if (dryRun) {
      final wdStr = workingDirectory != null ? ' (in $workingDirectory)' : '';
      logger.info('$commandStr$wdStr');
      installedSkills.putIfAbsent(entry.targetPath, () => []).add(entry);
      continue;
    }

    logger.info(
      '\n📦 $commandStr${workingDirectory != null ? ' (in ${entry.targetPath})' : ''}',
    );
    final process = await Process.start(
      command.first,
      command.sublist(1),
      runInShell: true,
      mode: ProcessStartMode.inheritStdio,
      workingDirectory: workingDirectory,
    );

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      logger.warning('⚠️  終了コード: $exitCode');
      hasError = true;
    } else {
      installedSkills.putIfAbsent(entry.targetPath, () => []).add(entry);
    }
  }

  if (!dryRun) {
    if (hasError) {
      logger.warning('\n⚠️  一部のスキルでエラーが発生しました');
    } else {
      logger.info('\n✅ 全てのスキルをインストール/確認しました');
    }
  }

  if (installedSkills.isNotEmpty) {
    logger.info('\n=== インストール結果一覧 ===');
    for (final mapEntry in installedSkills.entries) {
      final target = mapEntry.key ?? 'global';
      logger.info('📍 $target:');
      for (final skillEntry in mapEntry.value) {
        final skillStr = skillEntry.skills.isEmpty
            ? skillEntry.source
            : '${skillEntry.source} (${skillEntry.skills.join(', ')})';
        logger.info('  - $skillStr');
      }
    }
  }

  if (skippedPaths.isNotEmpty) {
    logger.info('\n⏭️  以下のパスは存在しなかったためスキップされました:');
    for (final path in skippedPaths) {
      logger.info('  - $path');
    }
  }

  if (hasError) {
    exit(1);
  }
}

String _expandPath(String path) {
  if (path.startsWith('~/')) {
    final home = Platform.environment['HOME'] ?? '';
    return path.replaceFirst('~/', '$home/');
  }
  return path;
}

/// skills.yaml のエントリをパースする。
///
/// YAML構造:
/// ```yaml
/// global:
///   google-gemini/gemini-skills:         # 全スキル
///   vercel-labs/skills:                   # 指定スキルのみ
///     - find-skills
/// ~/Git/tax-return:                     # global以外のトップレベルキーはパス扱い
///   kazukinagata/shinkoku:
/// ```
List<_SkillEntry> _parseSkillEntries(YamlMap yaml) {
  final entries = <_SkillEntry>[];

  if (yaml['global'] is YamlMap) {
    entries.addAll(_parseSourceMap(yaml['global'] as YamlMap, null));
  } else if (yaml['global'] != null) {
    logger.warning('global が不正な形式です');
  }

  for (final MapEntry(key: pathStr, value: pathValue) in yaml.entries) {
    if (pathStr == 'global') continue;

    if (pathStr is! String || pathValue is! YamlMap) {
      logger.warning('トップレベルの $pathStr が不正な形式です');
      continue;
    }
    entries.addAll(_parseSourceMap(pathValue, pathStr));
  }

  return entries;
}

Iterable<_SkillEntry> _parseSourceMap(YamlMap map, String? targetPath) sync* {
  for (final MapEntry(:key, :value) in map.entries) {
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

    yield _SkillEntry(source: source, skills: skills, targetPath: targetPath);
  }
}

/// npx skills add コマンドを組み立てる。
List<String> _buildCommand(_SkillEntry entry) {
  final args = [
    'npx',
    'skills',
    'add',
    entry.source,
  ];

  if (entry.targetPath == null) {
    args.add('--global');
  }

  args.addAll([
    '--agent',
    'antigravity',
    '-y',
  ]);

  if (entry.skills.isNotEmpty) {
    args.addAll(['--skill', ...entry.skills]);
  }

  return args;
}

class _SkillEntry {
  _SkillEntry({required this.source, this.skills = const [], this.targetPath});

  final String source;
  final List<String> skills;
  final String? targetPath;
}

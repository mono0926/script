import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:script/logger.dart';
import 'package:yaml/yaml.dart';

/// skills.yaml を読み込み、各スキルをインストールするスクリプト。
///
/// 使い方:
///   dart run :setup_skills          # 実行
///   dart run :setup_skills --dry-run # コマンド確認のみ
void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'ヘルプを表示します')
    ..addFlag('dry-run', negatable: false, help: 'コマンド確認のみ行います');

  final argResults = parser.parse(arguments);

  if (argResults['help'] as bool) {
    logger
      ..info('使い方: dart run :setup_skills [オプション]\n')
      ..info(parser.usage);
    exit(0);
  }

  final dryRun = argResults['dry-run'] as bool;

  final configFile = File('config/skills.yaml');
  if (!configFile.existsSync()) {
    logger.err('config/skills.yaml が見つかりません');
    exit(1);
  }

  final yaml = loadYaml(configFile.readAsStringSync()) as YamlMap;
  final entries = _parseSkillEntries(yaml);

  if (dryRun) {
    logger.info('=== Dry Run: 以下のコマンドを実行します ===\n');
  }

  var hasError = false;
  final skippedPaths = <String>[];
  final validPaths = <String?>{null}; // null は global を表す

  // 事前に有効なパスを収集
  for (final entry in entries) {
    if (entry.targetPath != null) {
      final expandedPath = _expandPath(entry.targetPath!);
      if (Directory(expandedPath).existsSync()) {
        validPaths.add(entry.targetPath);
      } else {
        if (!skippedPaths.contains(entry.targetPath)) {
          skippedPaths.add(entry.targetPath!);
        }
      }
    }
  }

  if (!dryRun) {
    logger.info('=== 既存のスキルを削除しています ===');
    for (final path in validPaths) {
      final targetDir = path == null
          ? _expandPath('~/.agents/skills')
          : '${_expandPath(path)}/.agents/skills';

      final lockfilePath = path == null
          ? _expandPath('~/.agents/.skill-lock.json')
          : '${_expandPath(path)}/skills-lock.json';

      final dir = Directory(targetDir);
      final lockfile = File(lockfilePath);

      if (dir.existsSync()) {
        logger.info('🗑️  $targetDir');
        dir.deleteSync(recursive: true);
      }
      if (lockfile.existsSync()) {
        lockfile.deleteSync();
      }
    }
    logger.success('削除完了\n');
  }

  for (final entry in entries) {
    if (entry.targetPath != null && skippedPaths.contains(entry.targetPath)) {
      continue;
    }

    final workingDirectory = entry.targetPath != null
        ? _expandPath(entry.targetPath!)
        : null;

    final command = _buildCommand(entry);
    final commandStr = command.join(' ');

    if (dryRun) {
      final wdStr = workingDirectory != null ? ' (in $workingDirectory)' : '';
      logger.info('$commandStr$wdStr');
      continue;
    }

    logger.info(
      '\n📦 $commandStr'
      '${workingDirectory != null ? ' (in ${entry.targetPath})' : ''}',
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
      logger.warn('⚠️  終了コード: $exitCode');
      hasError = true;
    }
  }

  if (!dryRun) {
    if (hasError) {
      logger.warn('\n⚠️  一部のスキルでエラーが発生しました');
    } else {
      logger.success('\n全てのスキルをインストール/確認しました');
    }
  }

  if (!dryRun) {
    logger.info('\n=== インストール結果一覧 ===');

    for (final path in validPaths) {
      final targetName = path ?? 'global';
      logger.info('📍 $targetName:');

      final lockfilePath = path == null
          ? _expandPath('~/.agents/.skill-lock.json')
          : '${_expandPath(path)}/skills-lock.json';
      final lockfile = File(lockfilePath);
      final skillsPerSource = <String, List<String>>{};

      if (lockfile.existsSync()) {
        try {
          final content = lockfile.readAsStringSync();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final skills = json['skills'] as Map<String, dynamic>? ?? {};

          for (final entry in skills.entries) {
            final skillName = entry.key;
            final skillData = entry.value as Map<String, dynamic>;
            final source = skillData['source'] as String? ?? 'unknown';

            skillsPerSource.putIfAbsent(source, () => []).add(skillName);
          }
        } catch (e) {
          logger.warn('    ⚠️  ロックファイルのパースに失敗しました: $lockfilePath ($e)');
        }
      }

      if (skillsPerSource.isEmpty) {
        logger.info('  - (インストールされたスキルはありません)');
      } else {
        final sources = skillsPerSource.keys.toList()..sort();
        for (final source in sources) {
          logger.info('  - $source');
          final skills = skillsPerSource[source]!..sort();
          for (final skill in skills) {
            logger.info('    - $skill');
          }
        }
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
    logger.warn('global が不正な形式です');
  }

  for (final MapEntry(key: pathStr, value: pathValue) in yaml.entries) {
    if (pathStr == 'global') {
      continue;
    }

    if (pathStr is! String || pathValue is! YamlMap) {
      logger.warn('トップレベルの $pathStr が不正な形式です');
      continue;
    }
    entries.addAll(_parseSourceMap(pathValue, pathStr));
  }

  return entries;
}

Iterable<_SkillEntry> _parseSourceMap(YamlMap map, String? targetPath) sync* {
  for (final MapEntry(:key, :value) in map.entries) {
    if (key is! String) {
      logger.warn('不正なキーをスキップ: $key');
      continue;
    }

    final source = key;
    final skills = <String>[];

    if (value is YamlList) {
      for (final skill in value) {
        skills.add(skill as String);
      }
    } else if (value != null) {
      logger.warn('不正な値をスキップ ($source): $value');
      continue;
    }

    yield _SkillEntry(source: source, skills: skills, targetPath: targetPath);
  }
}

/// npx skills add コマンドを組み立てる。
List<String> _buildCommand(_SkillEntry entry) {
  return [
    'npx',
    'skills',
    'add',
    entry.source,
    if (entry.targetPath == null) '--global',
    '--agent',
    'antigravity',
    '-y',
    if (entry.skills.isNotEmpty) ...[
      '--skill',
      ...entry.skills,
    ],
  ];
}

class _SkillEntry {
  _SkillEntry({required this.source, this.skills = const [], this.targetPath});

  final String source;
  final List<String> skills;
  final String? targetPath;
}

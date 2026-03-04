import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:script/logger.dart';
import 'package:yaml/yaml.dart';

class SetupSkillsCommand extends Command<int> {
  SetupSkillsCommand() {
    argParser.addFlag(
      'dry-run',
      negatable: false,
      help: 'コマンド確認のみ行います',
    );
  }

  @override
  String get description => 'skills.yaml を読み込み、各スキルをインストールします';

  @override
  String get name => 'setup_skills';

  @override
  Future<int> run() async {
    final dryRun = argResults?['dry-run'] as bool? ?? false;

    final configFile = File('config/skills.yaml');
    if (!configFile.existsSync()) {
      logger.err('config/skills.yaml が見つかりません');
      return 1;
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
        final workingDirectory = path != null ? _expandPath(path) : null;
        final targetName = path ?? 'global';
        final progress = logger.progress('🗑️  $targetName のスキルを削除中...');

        final command = [
          'npx',
          'skills',
          'remove',
          '--all',
          if (path == null) '--global',
          '-y',
        ];

        final result = await Process.run(
          command.first,
          command.sublist(1),
          runInShell: true,
          workingDirectory: workingDirectory,
        );

        if (result.exitCode == 0) {
          progress.complete('🗑️  $targetName のスキルを削除しました');
        } else {
          progress.fail('🗑️  $targetName のスキル削除に失敗しました\n${result.stderr}');
          hasError = true;
        }
      }
      logger.success('既存のスキル削除完了\n');
    }

    final results = <ProcessResult>[];

    // --- Before Lock ---
    Map<String, dynamic> readLock(String? path) {
      final lockPath = path == null
          ? _expandPath('~/.agents/.skill-lock.json')
          : '${_expandPath(path)}/skills-lock.json';
      final file = File(lockPath);
      if (!file.existsSync()) {
        return {
          'version': 3,
          'skills': <String, dynamic>{},
          'dismissed': <String, dynamic>{},
        };
      }
      try {
        return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      } on Exception catch (_) {
        return {
          'version': 3,
          'skills': <String, dynamic>{},
          'dismissed': <String, dynamic>{},
        };
      }
    }

    void writeLock(String? path, Map<String, dynamic> data) {
      final lockPath = path == null
          ? _expandPath('~/.agents/.skill-lock.json')
          : '${_expandPath(path)}/skills-lock.json';
      final file = File(lockPath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
    }

    final beforeLocks = <String?, Map<String, dynamic>>{};
    for (final path in validPaths) {
      beforeLocks[path] = readLock(path);
    }

    final progress = dryRun ? null : logger.progress('インストールを実行中(並列)...');

    // --- Parallel Install ---
    final futures = <Future<ProcessResult>>[];
    for (final entry in entries) {
      if (entry.targetPath != null && skippedPaths.contains(entry.targetPath)) {
        continue;
      }
      final workingDirectory = entry.targetPath != null
          ? _expandPath(entry.targetPath!)
          : null;
      final command = _buildCommand(entry);

      if (dryRun) {
        final wdStr = workingDirectory != null ? ' (in $workingDirectory)' : '';
        logger.info('${command.join(' ')}$wdStr');
        continue;
      }

      futures.add(
        Process.run(
          command.first,
          command.sublist(1),
          runInShell: true,
          workingDirectory: workingDirectory,
        ).then((r) {
          results.add(r);
          return r;
        }),
      );
    }

    if (!dryRun) {
      await Future.wait(futures);
    }

    // --- Merge & Fix Locks ---
    if (!dryRun) {
      final afterLocks = <String?, Map<String, dynamic>>{};
      for (final path in validPaths) {
        afterLocks[path] = readLock(path);
      }

      for (final path in validPaths) {
        final before = beforeLocks[path]!;
        final after = afterLocks[path]!;
        final targetEntries = entries
            .where((e) => e.targetPath == path)
            .toList();

        final allPossible = <String, dynamic>{
          ...(before['skills'] as Map<String, dynamic>? ?? <String, dynamic>{}),
          ...(after['skills'] as Map<String, dynamic>? ?? <String, dynamic>{}),
        };

        final mergedSkills = <String, dynamic>{};
        for (final skillName in allPossible.keys) {
          final skillData = allPossible[skillName] as Map<String, dynamic>;
          final source = skillData['source'] as String?;
          final matchingEntry = targetEntries
              .where((e) => e.source == source)
              .firstOrNull;
          if (matchingEntry != null) {
            if (matchingEntry.skills.isEmpty ||
                matchingEntry.skills.contains(skillName)) {
              mergedSkills[skillName] = skillData;
            }
          }
        }

        // Write the merged lock to disk for this path
        final finalLock = <String, dynamic>{
          'version': before['version'] ?? 3,
          'skills': mergedSkills,
          'dismissed': <String, dynamic>{},
        };
        writeLock(path, finalLock);

        // Check for completely missing entries
        // (lost in race & not in before lock)
        for (final entry in targetEntries) {
          var satisfied = false;
          if (entry.skills.isNotEmpty) {
            satisfied = entry.skills.every(
              (s) => mergedSkills.keys.contains(s),
            );
          } else {
            satisfied = mergedSkills.values.any(
              (s) => (s as Map<String, dynamic>)['source'] == entry.source,
            );
          }

          if (!satisfied) {
            // Install sequentially to fix the missing skills
            final workingDirectory = path != null ? _expandPath(path) : null;
            final command = _buildCommand(entry);
            final r = await Process.run(
              command.first,
              command.sublist(1),
              runInShell: true,
              workingDirectory: workingDirectory,
            );
            results.add(r);
          }
        }
      }
      progress?.complete('インストール処理が完了しました');

      for (final result in results) {
        if (result.stdout.toString().isNotEmpty) {
          logger.info((result.stdout as String).trim());
        }
        if (result.stderr.toString().isNotEmpty) {
          logger.warn((result.stderr as String).trim());
        }
        if (result.exitCode != 0) {
          logger.warn('⚠️  終了コード: ${result.exitCode}');
          hasError = true;
        }
      }

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
          } on FormatException catch (e) {
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
      return 1;
    }
    return 0;
  }

  String _expandPath(String path) {
    if (path.startsWith('~/')) {
      final home = Platform.environment['HOME'] ?? '';
      return path.replaceFirst('~/', '$home/');
    }
    return path;
  }

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

  Iterable<_SkillEntry> _parseSourceMap(
    YamlMap map,
    String? targetPath,
  ) sync* {
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
}

class _SkillEntry {
  _SkillEntry({
    required this.source,
    this.skills = const [],
    this.targetPath,
  });

  final String source;
  final List<String> skills;
  final String? targetPath;
}

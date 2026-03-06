import 'dart:convert';
import 'dart:io';

import 'package:skills_optimizer/src/command_base.dart';
import 'package:skills_optimizer/src/logger.dart';
import 'package:yaml/yaml.dart';

class SetupCommand extends SkillsOptimizerCommand {
  SetupCommand() {
    argParser.addFlag(
      'dry-run',
      negatable: false,
      help: 'コマンド確認のみ行います',
    );
  }

  @override
  String get description => '''
skills.yaml を読み込み、各スキルをインストールします。

スキルの指定方法:
  - 全インストール: スキーマ名の後に何も書かない、あるいは空リスト `[]` 指定します。
  - 個別指定: インストールしたいスキル名をリストで記述します。
  - ワイルドカード指定: `*` を含むパターンを記述すると、合致する全スキルを対象にします (例: `*calendar*`)。
  - 除外指定: `!` プレフィックスを使用すると、そのパターンに合致するスキルを除外します (例: `!recipe-*`)。
''';

  @override
  String get name => 'setup';

  @override
  Future<int> run() async {
    if (!await checkNpx()) {
      logger
        ..err('npx コマンドが見つかりません。')
        ..info('\nNode.js と npm をインストールしてください: https://nodejs.org/');
      return 1;
    }

    final dryRun = argResults?['dry-run'] as bool? ?? false;
    final configPath = argResults?['config'] as String?;
    final configFile = findConfigFile(configPath);

    if (configFile == null) {
      logger
        ..err('設定ファイルが見つかりませんでした。')
        ..info('\nデフォルトの場所 (~/.config/skills_optimizer/config.yaml) に配置するか、')
        ..info(
          '`skills_optimizer init` で生成してください。または --config オプションでパスを指定してください。',
        );
      return 1;
    }

    final yamlString = await configFile.readAsString();
    final yaml = loadYaml(yamlString) as YamlMap;
    final entries = parseSkillEntries(yaml);

    // 同梱された skills-optimizer 自体を一覧に追加（まだ存在しない場合）
    final bundledSkillPath = await getBundledSkillPath();
    if (bundledSkillPath != null) {
      final alreadyHasOptimizer = entries.any(
        (e) => e.source.contains('skills-optimizer'),
      );
      if (!alreadyHasOptimizer) {
        entries.add(
          SkillEntry(
            source: bundledSkillPath,
            skills: ['skills-optimizer'],
          ),
        );
      }
    }

    if (dryRun) {
      logger.info('=== Dry Run: 以下のコマンドを実行します ===\n');
    }

    var hasError = false;
    final skippedPaths = <String>[];
    final validPaths = <String?>{null}; // null は global を表す

    for (final entry in entries) {
      if (entry.targetPath != null) {
        final expandedPath = expandPath(entry.targetPath!);
        if (Directory(expandedPath).existsSync()) {
          validPaths.add(entry.targetPath);
        } else {
          if (!skippedPaths.contains(entry.targetPath)) {
            skippedPaths.add(entry.targetPath!);
          }
        }
      }
    }

    // --- Before Lock ---
    Map<String, dynamic> readLock(String? path) {
      final lockPath = path == null
          ? expandPath('~/.agents/.skill-lock.json')
          : '${expandPath(path)}/skills-lock.json';
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
          ? expandPath('~/.agents/.skill-lock.json')
          : '${expandPath(path)}/skills-lock.json';
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

    final diffs = <String?, Map<String, Map<String, String>>>{};

    if (!dryRun) {
      logger.info('=== 既存のスキルを削除しています ===');
      for (final path in validPaths) {
        final workingDirectory = path != null ? expandPath(path) : null;
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

    // --- Resolve Patterns ---
    final resolvedEntries = <SkillEntry>[];
    for (final entry in entries) {
      if (entry.patterns.isEmpty) {
        resolvedEntries.add(entry);
        continue;
      }

      final targetName = entry.targetPath ?? 'global';
      final progress = logger.progress(
        '🔍 $targetName の利用可能なスキルを確認中 (${entry.source})...',
      );

      final listResult = await Process.run('npx', [
        'skills',
        'add',
        entry.source,
        '--list',
      ], runInShell: true);

      if (listResult.exitCode != 0) {
        progress.fail('❌ スキルリストの取得に失敗しました: ${entry.source}');
        resolvedEntries.add(entry);
        continue;
      }

      final availableSkills = _extractSkillNames(listResult.stdout.toString());
      final matchedSkills = <String>{...entry.skills};

      for (final pattern in entry.patterns) {
        final regExp = patternToRegExp(pattern);
        for (final skill in availableSkills) {
          if (regExp.hasMatch(skill)) {
            matchedSkills.add(skill);
          }
        }
      }

      for (final pattern in entry.excludePatterns) {
        final regExp = patternToRegExp(pattern);
        matchedSkills.removeWhere(regExp.hasMatch);
      }

      entry.excludes.forEach(matchedSkills.remove);

      if (matchedSkills.isEmpty) {
        progress.fail(
          '⚠️  パターンに合致するスキルが見つかりませんでした: ${entry.patterns.join(', ')}',
        );
        continue;
      }

      progress.complete(
        '🔍 $targetName (${entry.source}) で '
        '${matchedSkills.length} 個のスキルが見つかりました',
      );

      resolvedEntries.add(
        SkillEntry(
          source: entry.source,
          skills: matchedSkills.toList(),
          excludes: entry.excludes,
          excludePatterns: entry.excludePatterns,
          targetPath: entry.targetPath,
        ),
      );
    }

    final progress = dryRun ? null : logger.progress('インストールを実行中(並列)...');

    // --- Parallel Install ---
    final activeEntries = <SkillEntry>[];
    final processFutures = <Future<Process>>[];
    for (final entry in resolvedEntries) {
      if (entry.targetPath != null && skippedPaths.contains(entry.targetPath)) {
        continue;
      }
      activeEntries.add(entry);
      final workingDirectory = entry.targetPath != null
          ? expandPath(entry.targetPath!)
          : null;
      final command = _buildCommand(entry);

      if (dryRun) {
        final wdStr = workingDirectory != null ? ' (in $workingDirectory)' : '';
        logger.info('${command.join(' ')}$wdStr');
        continue;
      }

      processFutures.add(
        Process.start(
          command.first,
          command.sublist(1),
          runInShell: true,
          workingDirectory: workingDirectory,
        ),
      );
    }

    if (!dryRun) {
      final runningProcesses = await Future.wait(processFutures);
      final results = <ProcessResult>[];

      for (var i = 0; i < runningProcesses.length; i++) {
        final p = runningProcesses[i];
        final entry = activeEntries[i];
        final targetName = entry.targetPath ?? 'global';

        final stdoutLines = <String>[];
        final stderrLines = <String>[];

        p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) {
            if (line.trim().isEmpty) {
              return;
            }
            stdoutLines.add(line);
            logger.detail('[$targetName] $line');
          },
        );

        p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) {
            if (line.trim().isEmpty) {
              return;
            }
            stderrLines.add(line);
            logger.warn('[$targetName:stderr] $line');
          },
        );

        final exitCode = await p.exitCode;
        results.add(
          ProcessResult(
            p.pid,
            exitCode,
            stdoutLines.join('\n'),
            stderrLines.join('\n'),
          ),
        );
      }
      final afterLocks = <String?, Map<String, dynamic>>{};
      for (final path in validPaths) {
        afterLocks[path] = readLock(path);
      }

      var hasError = false;
      for (final result in results) {
        final stdoutStr = result.stdout.toString();
        final stderrStr = result.stderr.toString();
        if (stdoutStr.isNotEmpty) {
          logger.info(stdoutStr.trim());
        }
        if (stderrStr.isNotEmpty) {
          logger.warn(stderrStr.trim());
        }
        if (result.exitCode != 0) {
          logger.warn('⚠️  終了コード: ${result.exitCode}');
          hasError = true;
        }
      }

      for (final path in validPaths) {
        final before = beforeLocks[path]!;
        final after = afterLocks[path]!;

        final allPossible = <String, dynamic>{
          ...(before['skills'] as Map<String, dynamic>? ?? <String, dynamic>{}),
          ...(after['skills'] as Map<String, dynamic>? ?? <String, dynamic>{}),
        };

        final mergedSkills = <String, dynamic>{};

        for (var i = 0; i < activeEntries.length; i++) {
          final entry = activeEntries[i];
          if (entry.targetPath != path) {
            continue;
          }

          final result = results[i];
          if (result.exitCode != 0) {
            continue;
          }

          final stdoutStr = result.stdout.toString();
          final regex = RegExp(r'\.agents/skills/([\w\-]+)');
          final matches = regex.allMatches(stdoutStr);
          var extractedSkills = matches.map((m) => m.group(1)!).toSet()
            ..addAll(entry.skills);

          if (entry.excludes.isNotEmpty || entry.excludePatterns.isNotEmpty) {
            final allExcludeRegExps = [
              ...entry.excludePatterns.map(patternToRegExp),
            ];

            extractedSkills = extractedSkills.where((skill) {
              if (entry.excludes.contains(skill)) {
                return false;
              }
              for (final regex in allExcludeRegExps) {
                if (regex.hasMatch(skill)) {
                  return false;
                }
              }
              return true;
            }).toSet();

            for (final exclude in entry.excludes) {
              _deleteSkillDir(entry, exclude);
            }
            final regexes = entry.excludePatterns.map(patternToRegExp).toList();
            if (regexes.isNotEmpty) {
              final skillDir = entry.targetPath == null
                  ? expandPath('~/.agents/skills')
                  : '${expandPath(entry.targetPath!)}/.agents/skills';
              final dir = Directory(skillDir);
              if (dir.existsSync()) {
                for (final entity in dir.listSync()) {
                  if (entity is Directory) {
                    final skillName = entity.uri.pathSegments
                        .where((s) => s.isNotEmpty)
                        .last;
                    for (final regex in regexes) {
                      if (regex.hasMatch(skillName)) {
                        entity.deleteSync(recursive: true);
                        break;
                      }
                    }
                  }
                }
              }
            }
          }

          for (final skill in extractedSkills) {
            final existing = allPossible[skill] as Map<String, dynamic>?;
            mergedSkills[skill] = <String, dynamic>{
              'source': entry.source,
              'sourceType': existing?['sourceType'] ?? 'github',
              'computedHash': existing?['computedHash'] ?? '',
            };
          }
        }

        final addedSkills = <String, String>{};
        final removedSkills = <String, String>{};

        final beforeSkills = before['skills'] as Map<String, dynamic>? ?? {};

        for (final skill in mergedSkills.keys) {
          final afterSource =
              (mergedSkills[skill] as Map<String, dynamic>)['source']
                  as String? ??
              'unknown';
          if (!beforeSkills.containsKey(skill)) {
            addedSkills[skill] = afterSource;
          }
        }
        for (final skill in beforeSkills.keys) {
          if (!mergedSkills.containsKey(skill)) {
            removedSkills[skill] =
                (beforeSkills[skill] as Map<String, dynamic>)['source']
                    as String? ??
                'unknown';
          }
        }

        diffs[path] = {'added': addedSkills, 'removed': removedSkills};

        final finalLock = <String, dynamic>{
          'version': before['version'] ?? 3,
          'skills': mergedSkills,
          'dismissed': <String, dynamic>{},
        };
        writeLock(path, finalLock);
      }
      progress?.complete('インストール処理が完了しました');

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
            ? expandPath('~/.agents/.skill-lock.json')
            : '${expandPath(path)}/skills-lock.json';
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

        final pathDiff = diffs[path] ?? {};
        final added = pathDiff['added'] ?? {};
        final removed = pathDiff['removed'] ?? {};

        if (added.isNotEmpty || removed.isNotEmpty) {
          logger.info('\n    [前回の状態からの変更点]');
          if (added.isNotEmpty) {
            final sortedAdded = added.keys.toList()..sort();
            for (final skill in sortedAdded) {
              logger.info('    ✨ 追加: $skill (${added[skill]})');
            }
          }
          if (removed.isNotEmpty) {
            final sortedRemoved = removed.keys.toList()..sort();
            for (final skill in sortedRemoved) {
              logger.info('    🗑️  削除: $skill (${removed[skill]})');
            }
          }
        } else {
          logger
            ..info('\n    [変更点]')
            ..info('    🔄 すべての既存スキルを最新状態に同期しました (差分なし)');
        }
      }
    }

    if (skippedPaths.isNotEmpty) {
      logger.info('\n⏭️  以下のパスは存在しなかったためスキップされました:');
      for (final path in skippedPaths) {
        logger.info('  - $path');
      }
    }

    return hasError ? 1 : 0;
  }

  List<String> _buildCommand(SkillEntry entry) {
    return [
      'npx',
      'skills',
      'add',
      entry.source,
      if (entry.targetPath == null) '--global',
      '--agent',
      'antigravity',
      '-y',
      if (entry.skills.isNotEmpty) ...['--skill', ...entry.skills],
    ];
  }

  List<String> _extractSkillNames(String output) {
    final cleanOutput = output.replaceAll(
      RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'),
      '',
    );
    final names = <String>{};
    final regex = RegExp(r'(?:│\s{4}|-\s+|│\s+-\s+)([\w\d\-]+)(?:\s|$)');
    for (final match in regex.allMatches(cleanOutput)) {
      final name = match.group(1)!;
      if (name.length > 2 && !name.contains(' ')) {
        names.add(name);
      }
    }
    return names.toList();
  }

  void _deleteSkillDir(SkillEntry entry, String skillName) {
    final excludePath = entry.targetPath == null
        ? expandPath('~/.agents/skills/$skillName')
        : '${expandPath(entry.targetPath!)}/.agents/skills/$skillName';
    final excludeDir = Directory(excludePath);
    if (excludeDir.existsSync()) {
      excludeDir.deleteSync(recursive: true);
    }
  }
}

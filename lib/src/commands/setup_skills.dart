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

    final diffs = <String?, Map<String, Map<String, String>>>{};

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

    // --- Resolve Patterns ---
    final resolvedEntries = <_SkillEntry>[];
    for (final entry in entries) {
      if (entry.patterns.isEmpty) {
        resolvedEntries.add(entry);
        continue;
      }

      final targetName = entry.targetPath ?? 'global';
      final progress = logger.progress(
        '🔍 $targetName の利用可能なスキルを確認中 (${entry.source})...',
      );

      final listResult = await Process.run(
        'npx',
        ['skills', 'add', entry.source, '--list'],
        runInShell: true,
      );

      if (listResult.exitCode != 0) {
        progress.fail('❌ スキルリストの取得に失敗しました: ${entry.source}');
        resolvedEntries.add(entry);
        continue;
      }

      final availableSkills = _extractSkillNames(listResult.stdout.toString());
      final matchedSkills = <String>{...entry.skills};

      // 包含パターンの処理
      for (final pattern in entry.patterns) {
        final regExp = _patternToRegExp(pattern);
        for (final skill in availableSkills) {
          if (regExp.hasMatch(skill)) {
            matchedSkills.add(skill);
          }
        }
      }

      // 除外パターンの処理 (ワイルドカード)
      for (final pattern in entry.excludePatterns) {
        final regExp = _patternToRegExp(pattern);
        matchedSkills.removeWhere(regExp.hasMatch);
      }

      // 除外の処理 (完全一致)
      for (final exclude in entry.excludes) {
        matchedSkills.remove(exclude);
      }

      if (matchedSkills.isEmpty) {
        progress.fail(
          '⚠️  パターンに合致するスキルが見つかりませんでした: ${entry.patterns.join(', ')}',
        );
        continue;
      }

      progress.complete('🔍 ${matchedSkills.length} 個のスキルが見つかりました');

      resolvedEntries.add(
        _SkillEntry(
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
    final activeEntries = <_SkillEntry>[];
    final futures = <Future<ProcessResult>>[];
    for (final entry in resolvedEntries) {
      if (entry.targetPath != null && skippedPaths.contains(entry.targetPath)) {
        continue;
      }
      activeEntries.add(entry);
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
        ),
      );
    }

    if (!dryRun) {
      final results = await Future.wait(futures);

      // --- Merge & Fix Locks via Output Parsing ---
      // 注意: なぜ「並列処理が全て終わった後に .skill-lock.json を読み直すだけ」ではダメなのか
      // `npx skills add` を複数プロセスで同時に実行すると、同一の .skill-lock.json への
      // 書き込み競合 (Race Condition) が発生します。
      // その結果、「一部のスキルが記録から抜け落ちる」「JSONファイル自体が破損する」といった
      // クリティカルな問題が頻発します。
      //
      // この問題を回避しつつ並列処理の恩恵(高速化)を得るため、ファイルへの競合書き込みは
      // いったん「壊れても仕方ない」と割り切り、プロセス実行時の標準出力(stdout)から
      // 「実際にインストールに成功したスキル名」を正規表現で抽出しています。
      // そして最後に、集約した完全な情報を競合のない安全な状態でファイルに1回だけ上書き(マージ)します。
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
            continue; // Skip failed installations
          }

          final stdoutStr = result.stdout.toString();
          final regex = RegExp(r'\.agents/skills/([\w\-]+)');
          final matches = regex.allMatches(stdoutStr);
          var extractedSkills = matches.map((m) => m.group(1)!).toSet()
            ..addAll(entry.skills);

          if (entry.excludes.isNotEmpty || entry.excludePatterns.isNotEmpty) {
            final allExcludeRegExps = [
              ...entry.excludePatterns.map(_patternToRegExp),
            ];

            extractedSkills = extractedSkills.where((skill) {
              if (entry.excludes.contains(skill)) return false;
              for (final regex in allExcludeRegExps) {
                if (regex.hasMatch(skill)) return false;
              }
              return true;
            }).toSet();

            // 念のため、マッチした（除外されるべき）ディレクトリを削除
            for (final exclude in entry.excludes) {
              _deleteSkillDir(entry, exclude);
            }
            // ワイルドカード除外対象も、もし存在していれば削除
            final regexes = entry.excludePatterns
                .map(_patternToRegExp)
                .toList();
            if (regexes.isNotEmpty) {
              final skillDir = entry.targetPath == null
                  ? _expandPath('~/.agents/skills')
                  : '${_expandPath(entry.targetPath!)}/.agents/skills';
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

        diffs[path] = {
          'added': addedSkills,
          'removed': removedSkills,
        };

        // Write the merged lock to disk for this path
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
        for (final item in value) {
          processValue(item);
        }
      } else if (value is YamlMap) {
        final excludesList = value['excludes'];
        if (excludesList is YamlList) {
          for (final exclude in excludesList) {
            if (exclude is String) {
              if (exclude.contains('*')) {
                excludePatterns.add(exclude);
              } else {
                excludes.add(exclude);
              }
            }
          }
        }
      } else if (value != null) {
        logger.warn('不正な値をスキップ ($source): $value');
        continue;
      }

      yield _SkillEntry(
        source: source,
        skills: skills,
        patterns: patterns,
        excludes: excludes,
        excludePatterns: excludePatterns,
        targetPath: targetPath,
      );
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

  List<String> _extractSkillNames(String output) {
    // ANSI エスケープシーケンスを削除
    final cleanOutput = output.replaceAll(
      RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'),
      '',
    );

    // スキル名を抽出
    final names = <String>{};

    // 形式 1: "│    skill-name" (npx skills add --list)
    // 形式 2: "│    - skill-name" (エラー時のリスト)
    // 形式 3: "    - skill-name" (シンプルなリスト)
    final regex = RegExp(r'(?:│\s{4}|-\s+|│\s+-\s+)([\w\d\-]+)(?:\s|$)');
    for (final match in regex.allMatches(cleanOutput)) {
      final name = match.group(1)!;
      // 名前の長さや形式でノイズ（説明文の単語など）を除去
      if (name.length > 2 && !name.contains(' ')) {
        names.add(name);
      }
    }
    return names.toList();
  }

  RegExp _patternToRegExp(String pattern) {
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

  void _deleteSkillDir(_SkillEntry entry, String skillName) {
    final excludePath = entry.targetPath == null
        ? _expandPath('~/.agents/skills/$skillName')
        : '${_expandPath(entry.targetPath!)}/.agents/skills/$skillName';
    final excludeDir = Directory(excludePath);
    if (excludeDir.existsSync()) {
      excludeDir.deleteSync(recursive: true);
    }
  }
}

class _SkillEntry {
  _SkillEntry({
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

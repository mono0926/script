import 'dart:convert';
import 'dart:io';

import 'package:skills_optimizer/src/command_base.dart';
import 'package:skills_optimizer/src/logger.dart';
import 'package:yaml/yaml.dart';

class ListCommand extends SkillsOptimizerCommand {
  @override
  String get description => '現在の設定とインストール済みのスキルを一覧表示します。';

  @override
  String get name => 'list';

  @override
  Future<int> run() async {
    if (!await checkNpx()) {
      logger
        ..err('npx コマンドが見つかりません。')
        ..info('\nNode.js と npm をインストールしてください: https://nodejs.org/');
      return 1;
    }

    final configPath = argResults?['config'] as String?;
    final configFile = findConfigFile(configPath);

    if (configFile == null) {
      logger.err('設定ファイルが見つかりませんでした。');
      return 1;
    }

    logger.info('📖 設定ファイル: ${configFile.path}');

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

    final validPaths = <String?>{null};
    for (final entry in entries) {
      if (entry.targetPath != null) {
        final expandedPath = expandPath(entry.targetPath!);
        if (Directory(expandedPath).existsSync()) {
          validPaths.add(entry.targetPath);
        }
      }
    }

    logger.info('\n=== インストール状況 ===');

    for (final path in validPaths) {
      final targetName = path ?? 'global';
      logger.info('\n📍 $targetName:');

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
    }

    return 0;
  }
}

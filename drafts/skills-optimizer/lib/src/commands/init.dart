import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:skills_optimizer/src/command_base.dart';
import 'package:skills_optimizer/src/logger.dart';

class InitCommand extends SkillsOptimizerCommand {
  @override
  String get description =>
      'デフォルト設定ファイル (~/.config/skills_optimizer/config.yaml) を生成します。';

  @override
  String get name => 'init';

  @override
  Future<int> run() async {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) {
      logger.err('HOME ディレクトリが特定できません。');
      return 1;
    }

    final configDir = Directory(p.join(home, '.config', 'skills_optimizer'));
    final configFile = File(p.join(configDir.path, 'config.yaml'));

    if (configFile.existsSync()) {
      logger.warn('設定ファイルは既に存在します: ${configFile.path}');
      return 0;
    }

    if (!configDir.existsSync()) {
      configDir.createSync(recursive: true);
    }

    const template = r'''# skills_optimizer configuration file
#
# 配置場所: ~/.config/skills_optimizer/config.yaml
#
# 記法例:
# global:
#   # インストールしたスキルを ~ / .agents / skills / 配下にグローバルに配置します。
#   # スキーマ名: [スキル名1, スキル名2, ...]
#   mono0926/script: [] # 全スキルをインストール
#
# ~/Git/my-project:
#   # 特定のディレクトリ配下にスキルを配置する場合
#   mono0926/script:
#     - skills-optimizer
#     - "!recipe-*" # recipe- で始まるスキルを除外
#   anthropic/skills:
#     - "flutter-*" # flutter- で始まるスキルをワイルドカード指定

global:
  mono0926/script: [] # skills-optimizer を含む基本スキルセット
''';

    configFile.writeAsStringSync(template);
    logger
      ..success('設定ファイルを生成しました: ${configFile.path}')
      ..info('\n次に `skills_optimizer setup` を実行してスキルをインストールしてください。');

    return 0;
  }
}

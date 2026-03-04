import 'package:args/command_runner.dart';
import 'package:cli_completion/cli_completion.dart';
import 'package:script/exceptions.dart';
import 'package:script/logger.dart';
import 'package:script/src/commands/setup_skills.dart';

class ScriptCommandRunner extends CompletionCommandRunner<int> {
  ScriptCommandRunner()
    : super(
        'script',
        '様々なスクリプトの置き場',
      ) {
    addCommand(SetupSkillsCommand());
  }

  @override
  Future<int?> run(Iterable<String> args) async {
    try {
      return await super.run(args);
    } on FormatException catch (e) {
      logger
        ..err(e.message)
        ..info('')
        ..info(usage);
      return 64; // usage error
    } on UsageException catch (e) {
      logger
        ..err(e.message)
        ..info('')
        ..info(e.usage);
      return 64; // EX_USAGE
      // 現在は投げられていないが、将来の拡張を見据えてドメイン固有の例外ハンドリングを準備
    } on AppException catch (e) {
      logger.err(e.message);
      return 1;
    } on Exception catch (e, stackTrace) {
      logger
        ..err('An unexpected error occurred: $e')
        ..err(stackTrace.toString());
      return 1;
    }
  }
}

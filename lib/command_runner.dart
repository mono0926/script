import 'package:args/command_runner.dart';
import 'package:script/logger.dart';
import 'package:script/src/commands/setup_skills.dart';

class ScriptCommandRunner extends CommandRunner<int> {
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
    } on UsageException catch (e) {
      logger
        ..err(e.message)
        ..info('')
        ..info(e.usage);
      return 64; // EX_USAGE
    } on Exception catch (e, stackTrace) {
      logger
        ..err(e.toString())
        ..err(stackTrace.toString());
      return 1;
      // ignore: avoid_catching_errors
    } on Error catch (e, stackTrace) {
      logger
        ..err(e.toString())
        ..err(stackTrace.toString());
      return 1;
    }
  }
}

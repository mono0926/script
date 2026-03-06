import 'package:args/command_runner.dart';
import 'package:cli_completion/cli_completion.dart';
import 'package:skills_optimizer/src/commands/config.dart';
import 'package:skills_optimizer/src/commands/init.dart';
import 'package:skills_optimizer/src/commands/list.dart';
import 'package:skills_optimizer/src/commands/setup.dart';
import 'package:skills_optimizer/src/exceptions.dart';
import 'package:skills_optimizer/src/logger.dart';

class SkillsOptimizerCommandRunner extends CompletionCommandRunner<int> {
  SkillsOptimizerCommandRunner()
    : super('skills_optimizer', 'Anthropics/GitHub上のスキルを簡単に管理・最適化するCLIツール') {
    addCommand(SetupCommand());
    addCommand(ListCommand());
    addCommand(InitCommand());
    addCommand(ConfigCommand());
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

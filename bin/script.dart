import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:script/logger.dart';
import 'package:script/src/commands/setup_skills.dart';

Future<void> main(List<String> arguments) async {
  final runner = CommandRunner<int>(
    'script',
    '様々なスクリプトの置き場',
  )..addCommand(SetupSkillsCommand());

  try {
    final exitCode = await runner.run(arguments);
    exit(exitCode ?? 0);
  } on UsageException catch (e) {
    logger
      ..err(e.message)
      ..info('')
      ..info(e.usage);
    exit(64); // EX_USAGE
  } on Exception catch (e, stackTrace) {
    logger
      ..err(e.toString())
      ..err(stackTrace.toString());
    exit(1);
    // ignore: avoid_catching_errors
  } on Error catch (e, stackTrace) {
    logger
      ..err(e.toString())
      ..err(stackTrace.toString());
    exit(1);
  }
}

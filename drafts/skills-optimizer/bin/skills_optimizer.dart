import 'dart:io';

import 'package:skills_optimizer/src/command_runner.dart';

Future<void> main(List<String> args) async {
  exitCode = await SkillsOptimizerCommandRunner().run(args) ?? 0;
}

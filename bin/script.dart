#!/usr/bin/env dart

import 'dart:io';

import 'package:script/command_runner.dart';

Future<void> main(List<String> arguments) async {
  final exitCode = await ScriptCommandRunner().run(arguments);
  await flushThenExit(exitCode ?? 0);
}

/// [status]をexitCodeに設定し、標準出力/標準エラーのフラッシュを待って終了するヘルパー
Future<void> flushThenExit(int status) async {
  exitCode = status;
  await Future.wait<void>([
    stdout.close(),
    stderr.close(),
  ]);
}

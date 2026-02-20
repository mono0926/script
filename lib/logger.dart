import 'package:logging/logging.dart';

/// アプリケーション共通の [Logger]。
final logger = Logger('script');

/// ログ出力の初期設定を行う。
void setupLogger() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print(record.message);
  });
}

/// ドメイン固有のカスタム例外
class AppException implements Exception {
  const AppException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 네트워크/RPC 호출에서 발생하는 실패를 표현하는 도메인 예외.
///
/// Repository / AnalyticsClient 는 외부 라이브러리의 `PostgrestException`,
/// `SocketException`, `TimeoutException` 등을 모두 [NetworkException] 으로
/// 정규화하여 던진다. 호출자는 단 하나의 예외 타입만 신경 쓰면 된다.
class NetworkException implements Exception {
  final String message;
  final Object? cause;

  NetworkException(this.message, {this.cause});

  @override
  String toString() => 'NetworkException: $message';
}

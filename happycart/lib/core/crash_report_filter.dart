import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// [FlutterError.onError] 로 들어온 프레임워크 오류가, 앱을 죽이지 않는
/// 플랫폼 채널 정리(cleanup) 노이즈인지 판별한다.
///
/// Flutter 엔진은 EventChannel 구독 취소(cancel)가 native 쪽 스트림이 이미
/// 내려간 뒤 도착하면 `PlatformException(error, No active stream to cancel)` 을
/// 만들어 `FlutterError.reportError` 로 전달한다(platform_channel.dart 의
/// onCancel — 예: mobile_scanner stop 시 구독 취소와 native 정리의 경합).
/// 이 오류는 정리 단계의 무해한 잡음이라 앱이 죽지 않으므로, fatal 로 기록하면
/// crash-free 지표만 왜곡한다. 호출측(main.dart)은 이 경우 non-fatal 로만
/// 기록한다.
///
/// 판별은 [FlutterErrorDetails.exception]/[FlutterErrorDetails.library] 같은
/// 순수 값 필드만 본다 — **[FlutterErrorDetails.context] 문자열은 절대 비교에
/// 쓰지 않는다.** `context`는 `DiagnosticsNode`(예: `ErrorDescription`)인데,
/// Flutter SDK 의 `DiagnosticsNode.toString()` 서식 로직 전체가
/// `assert(() { ... }())` 안에 있어(diagnostics.dart) **release 빌드에서는
/// assert 가 통째로 스트립돼 원래 메시지 대신 `super.toString()`(예:
/// 'thrown')로 뭉개진다.** 실제로 v10 프로덕션 이벤트의
/// `flutter_error_reason` 이 'thrown' 한 단어로만 기록돼 필터가 release 에서
/// 항상 실패했던 게 이 문제였다(Crashlytics 실측으로 확인). `exception.message`
/// 와 `library` 는 생성자에 그대로 저장되는 plain String 필드라 release 에서도
/// 안전하며, 이 조합만으로도 충분히 특정적이다(엔진 소스 확인 — 'No active
/// stream to cancel' 메시지는 EventChannel cancel 실패 시에만 나온다).
bool isBenignChannelCleanupError(FlutterErrorDetails details) {
  final exception = details.exception;
  return exception is PlatformException &&
      exception.message == 'No active stream to cancel' &&
      details.library == 'services library';
}

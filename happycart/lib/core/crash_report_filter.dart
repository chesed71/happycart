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
/// 판별은 메시지만 보지 않고 엔진 보고 형태(library='services library' +
/// 'while de-activating platform stream on channel …' 컨텍스트)까지 함께
/// 확인한다 — 같은 메시지가 다른 경로로 FlutterError 에 도달하는 이례적
/// 경우까지 non-fatal 로 삼키지 않도록. 반대로 채널명은 특정 플러그인
/// (mobile_scanner)에 고정하지 않는다: "cancel 도착 시 활성 스트림 없음"은
/// 어느 EventChannel 이든 같은 의미의 정리 노이즈이기 때문.
bool isBenignChannelCleanupError(FlutterErrorDetails details) {
  final exception = details.exception;
  if (exception is! PlatformException ||
      exception.message != 'No active stream to cancel') {
    return false;
  }
  return details.library == 'services library' &&
      (details.context
              ?.toString()
              .contains('while de-activating platform stream on channel') ??
          false);
}

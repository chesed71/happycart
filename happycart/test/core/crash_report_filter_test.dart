import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycart/core/crash_report_filter.dart';

void main() {
  group('isBenignChannelCleanupError', () {
    test('EventChannel cancel 경합 오류(No active stream to cancel)는 benign', () {
      // Flutter 엔진(platform_channel.dart)이 EventChannel 정리 중 native 의
      // "No active stream to cancel" 오류 응답을 FlutterError.reportError 로
      // 전달하는 형태를 재현한다 — mobile_scanner stop 경합의 실제 페이로드.
      final details = FlutterErrorDetails(
        exception: PlatformException(
          code: 'error',
          message: 'No active stream to cancel',
        ),
        library: 'services library',
        context: ErrorDescription(
          'while de-activating platform stream on channel '
          'dev.steenbakker.mobile_scanner/scanner/event',
        ),
      );

      expect(isBenignChannelCleanupError(details), isTrue);
    });

    test('같은 메시지라도 엔진 EventChannel 보고 형태가 아니면 benign 아님', () {
      // 앱/플러그인 코드가 우연히 같은 메시지의 PlatformException 을
      // FlutterError 로 보고하는 경우 — services library 의 de-activation
      // 컨텍스트가 없으므로 fatal 경로를 유지해야 한다.
      final details = FlutterErrorDetails(
        exception: PlatformException(
          code: 'error',
          message: 'No active stream to cancel',
        ),
        library: 'widgets library',
      );

      expect(isBenignChannelCleanupError(details), isFalse);
    });

    test('services library 라도 de-activation 컨텍스트가 없으면 benign 아님', () {
      // context 조건이 조건 완화로 삭제되는 회귀를 잡는다 — widgets library
      // 테스트는 library 조건만으로도 걸러져 context 조건을 고정하지 못한다.
      final details = FlutterErrorDetails(
        exception: PlatformException(
          code: 'error',
          message: 'No active stream to cancel',
        ),
        library: 'services library',
      );

      expect(isBenignChannelCleanupError(details), isFalse);
    });

    test('엔진 보고 형태면 채널이 mobile_scanner 가 아니어도 benign (의도적)', () {
      // "cancel 도착 시 활성 스트림 없음"은 어느 EventChannel 이든 같은 의미의
      // 정리 노이즈다 — 특정 플러그인 채널명에 고정하지 않는다.
      final details = FlutterErrorDetails(
        exception: PlatformException(
          code: 'error',
          message: 'No active stream to cancel',
        ),
        library: 'services library',
        context: ErrorDescription(
          'while de-activating platform stream on channel '
          'some.other.plugin/events',
        ),
      );

      expect(isBenignChannelCleanupError(details), isTrue);
    });

    test('다른 메시지의 PlatformException 은 benign 아님', () {
      final details = FlutterErrorDetails(
        exception: PlatformException(code: 'error', message: 'Camera in use'),
      );

      expect(isBenignChannelCleanupError(details), isFalse);
    });

    test('PlatformException 이 아닌 예외는 benign 아님', () {
      final details = FlutterErrorDetails(
        exception: StateError('No active stream to cancel'),
      );

      expect(isBenignChannelCleanupError(details), isFalse);
    });
  });
}

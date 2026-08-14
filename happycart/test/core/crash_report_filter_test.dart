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

    test('context 가 없어도(release 빌드 재현) library+메시지만으로 benign', () {
      // 회귀 방지 — release 빌드에서는 DiagnosticsNode.toString() 의 실서식
      // 로직이 assert() 안에 있어 스트립되므로 context 가 실제로는 'thrown'
      // 처럼 뭉개진 값이 된다(Crashlytics v10 실측: flutter_error_reason=
      // 'thrown'). 그래서 context 를 판별 조건에서 아예 뺐다 — context 유무와
      // 무관하게 매칭돼야 release 에서도 필터가 동작한다.
      final details = FlutterErrorDetails(
        exception: PlatformException(
          code: 'error',
          message: 'No active stream to cancel',
        ),
        library: 'services library',
      );

      expect(isBenignChannelCleanupError(details), isTrue);
    });

    test('library 가 services library 아니면 benign 아님', () {
      // 앱/플러그인 코드가 우연히 같은 메시지의 PlatformException 을
      // FlutterError 로 보고하는 경우까지 삼키지 않도록 library 는 유지한다.
      final details = FlutterErrorDetails(
        exception: PlatformException(
          code: 'error',
          message: 'No active stream to cancel',
        ),
        library: 'widgets library',
      );

      expect(isBenignChannelCleanupError(details), isFalse);
    });

    test('다른 메시지의 PlatformException 은 benign 아님', () {
      final details = FlutterErrorDetails(
        exception: PlatformException(code: 'error', message: 'Camera in use'),
        library: 'services library',
      );

      expect(isBenignChannelCleanupError(details), isFalse);
    });

    test('PlatformException 이 아닌 예외는 benign 아님', () {
      final details = FlutterErrorDetails(
        exception: StateError('No active stream to cancel'),
        library: 'services library',
      );

      expect(isBenignChannelCleanupError(details), isFalse);
    });
  });
}

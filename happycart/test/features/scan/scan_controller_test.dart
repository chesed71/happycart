import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happycart/data/analytics_client.dart';
import 'package:happycart/data/product_repository.dart';
import 'package:happycart/features/scan/scan_controller.dart';
import 'package:permission_handler/permission_handler.dart';

/// 권한 요청기([requestStatus])와 조회기([checkStatus], 생략 시 요청값과 동일)를
/// 고정한 컨테이너를 만든다.
ProviderContainer _containerWith(
  PermissionStatus requestStatus, {
  PermissionStatus? checkStatus,
}) {
  return ProviderContainer(
    overrides: [
      cameraPermissionRequesterProvider
          .overrideWith((ref) => () async => requestStatus),
      cameraPermissionCheckerProvider
          .overrideWith((ref) => () async => checkStatus ?? requestStatus),
    ],
  );
}

void main() {
  test('requestPermission 승인 → scanning', () async {
    final container = _containerWith(PermissionStatus.granted);
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    await notifier.requestPermission();
    expect(container.read(scanControllerProvider).status, ScanStatus.scanning);
  });

  test('requestPermission 거부 → permissionDenied', () async {
    final container = _containerWith(PermissionStatus.denied);
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    await notifier.requestPermission();
    expect(
      container.read(scanControllerProvider).status,
      ScanStatus.permissionDenied,
    );
  });

  // 복귀 시 refreshPermission 이 스캔 재개를 겸한다: 승인 상태에서 pause 후
  // 재조회하면 scanning 으로 복원된다.
  test('granted 후 pause→refreshPermission 은 scanning 을 복원한다', () async {
    final container = _containerWith(PermissionStatus.granted);
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    await notifier.requestPermission();
    notifier.pause();
    expect(container.read(scanControllerProvider).status, ScanStatus.idle);

    await notifier.refreshPermission();
    expect(container.read(scanControllerProvider).status, ScanStatus.scanning);
  });

  // 설정에서 권한을 승인하고 복귀하면 permissionDenied → scanning 으로 복구된다.
  test('refreshPermission: 설정에서 승인 시 permissionDenied→scanning 복구', () async {
    final container = _containerWith(
      PermissionStatus.denied,
      checkStatus: PermissionStatus.granted,
    );
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    await notifier.requestPermission(); // 최초 거부
    expect(
      container.read(scanControllerProvider).status,
      ScanStatus.permissionDenied,
    );

    await notifier.refreshPermission(); // 설정에서 승인 후 복귀
    expect(container.read(scanControllerProvider).status, ScanStatus.scanning);
  });

  // 설정에서 권한을 철회하고 복귀하면 scanning → permissionDenied 로 바뀐다.
  test('refreshPermission: 설정에서 철회 시 scanning→permissionDenied', () async {
    final container = _containerWith(
      PermissionStatus.granted,
      checkStatus: PermissionStatus.denied,
    );
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    await notifier.requestPermission(); // 최초 승인
    expect(container.read(scanControllerProvider).status, ScanStatus.scanning);

    await notifier.refreshPermission(); // 설정에서 철회 후 복귀
    expect(
      container.read(scanControllerProvider).status,
      ScanStatus.permissionDenied,
    );
  });

  // 결과 화면 도중 권한이 철회(refreshPermission→permissionDenied)됐다면, 화면이
  // 닫히며 호출되는 resumeScanning 이 권한 없이 scanning 으로 되돌리면 안 된다.
  test('철회 후 resumeScanning 은 permissionDenied 를 유지한다', () async {
    final container = _containerWith(
      PermissionStatus.granted,
      checkStatus: PermissionStatus.denied,
    );
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    await notifier.requestPermission(); // 승인 → scanning
    await notifier.refreshPermission(); // 설정에서 철회 → permissionDenied
    expect(
      container.read(scanControllerProvider).status,
      ScanStatus.permissionDenied,
    );

    notifier.resumeScanning(); // 결과 화면 닫힘
    expect(
      container.read(scanControllerProvider).status,
      ScanStatus.permissionDenied,
    );
  });

  // 명시적 권한 요청(다이얼로그)이 진행 중이면 재조회가 이를 무효화하지 않는다:
  // 요청 중 refresh 는 skip 되고, 사용자의 승인 결과가 반영된다.
  test('요청 진행 중 refresh 는 요청 결과를 무효화하지 않는다', () async {
    final requestCompleter = Completer<PermissionStatus>();
    final container = ProviderContainer(
      overrides: [
        cameraPermissionRequesterProvider
            .overrideWith((ref) => () => requestCompleter.future),
        cameraPermissionCheckerProvider
            .overrideWith((ref) => () async => PermissionStatus.denied),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    final requestFuture = notifier.requestPermission(); // 다이얼로그 대기 중
    await notifier.refreshPermission(); // 요청 중 → skip(denied 반영 안 됨)
    expect(container.read(scanControllerProvider).status, ScanStatus.idle);

    requestCompleter.complete(PermissionStatus.granted); // 사용자 승인
    await requestFuture;
    expect(container.read(scanControllerProvider).status, ScanStatus.scanning);
  });

  // 권한 조회가 역순으로 완료돼도(오래된 조회가 나중에 끝남) 최신 결과만 반영한다.
  test('refreshPermission: 오래된 조회가 최신 결과를 덮어쓰지 않는다', () async {
    final completers = <Completer<PermissionStatus>>[Completer(), Completer()];
    var callCount = 0;
    final container = ProviderContainer(
      overrides: [
        cameraPermissionCheckerProvider
            .overrideWith((ref) => () => completers[callCount++].future),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    final f1 = notifier.refreshPermission(); // gen1 (오래된)
    final f2 = notifier.refreshPermission(); // gen2 (최신)

    completers[1].complete(PermissionStatus.granted); // 최신 먼저 완료
    await f2;
    expect(container.read(scanControllerProvider).status, ScanStatus.scanning);

    completers[0].complete(PermissionStatus.denied); // 오래된 나중 완료 → 폐기
    await f1;
    expect(container.read(scanControllerProvider).status, ScanStatus.scanning);
  });

  // 권한 조회 실패는 컨트롤러가 삼키지 않고 전파하며(호출측이 non-fatal 처리),
  // 권한을 미확정(fail-closed)으로 내려 이후 resumeScanning 이 stale 승인값으로
  // 스캔을 재개하지 않도록 한다.
  test('refreshPermission: 조회 실패 시 예외 전파 + 이후 resumeScanning fail-closed', () async {
    final container = ProviderContainer(
      overrides: [
        cameraPermissionRequesterProvider
            .overrideWith((ref) => () async => PermissionStatus.granted),
        cameraPermissionCheckerProvider.overrideWith(
          (ref) => () async => throw Exception('permission check failed'),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    await notifier.requestPermission(); // 승인 → scanning, granted=true
    notifier.pause(); // idle
    expect(container.read(scanControllerProvider).status, ScanStatus.idle);

    // 조회 실패: 예외는 전파되고 권한은 미확정으로 내려간다.
    await expectLater(notifier.refreshPermission(), throwsA(isA<Exception>()));

    // 권한 미확정이므로 결과 화면이 닫혀도 스캔을 재개하지 않는다(카메라 off 유지).
    notifier.resumeScanning();
    expect(container.read(scanControllerProvider).status, ScanStatus.idle);
  });

  // 재조회가 완료되기 전에 결과 화면이 닫혀 resumeScanning 이 stale 승인값으로
  // scanning 을 복원해도, 뒤늦게 도착한 재조회 실패가 permissionGranted 를 내려
  // 카메라가 게이트되도록 한다(status 가 scanning 이어도 permissionGranted=false).
  test('재조회 완료 전 stale scanning 이후 늦은 조회 실패는 permissionGranted 를 내린다', () async {
    final checkCompleter = Completer<PermissionStatus>();
    final container = ProviderContainer(
      overrides: [
        cameraPermissionRequesterProvider
            .overrideWith((ref) => () async => PermissionStatus.granted),
        cameraPermissionCheckerProvider
            .overrideWith((ref) => () => checkCompleter.future),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    await notifier.requestPermission(); // scanning, permissionGranted=true
    final refreshFuture = notifier.refreshPermission(); // 복귀: in-flight

    // 재조회 완료 전 결과 화면 닫힘 → stale 승인값으로 scanning 복원
    notifier.resumeScanning();
    expect(container.read(scanControllerProvider).status, ScanStatus.scanning);
    expect(container.read(scanControllerProvider).permissionGranted, isTrue);

    // 뒤늦게 재조회 실패 도착 → fail-closed 로 permissionGranted 내려감
    checkCompleter.completeError(Exception('permission check failed'));
    await expectLater(refreshFuture, throwsA(isA<Exception>()));
    expect(container.read(scanControllerProvider).permissionGranted, isFalse);
    // status 는 scanning 이라도 permissionGranted=false 라 카메라 제어가 켜지지 않음.
  });

  // 결과 화면(processing) 도중 권한 철회 + 조회 실패로 fail-closed 된 뒤 화면이
  // 닫히면, processing 에 갇히지 않고 안내 화면으로 빠져나온다.
  test('processing 중 조회 실패 후 결과 화면이 닫히면 processing 에 갇히지 않는다', () async {
    Future<dynamic> emptyRpc(String fnName, {Map<String, dynamic>? params}) async {
      return <Map<String, dynamic>>[];
    }

    final container = ProviderContainer(
      overrides: [
        cameraPermissionRequesterProvider
            .overrideWith((ref) => () async => PermissionStatus.granted),
        cameraPermissionCheckerProvider.overrideWith(
          (ref) => () async => throw Exception('permission check failed'),
        ),
        productRepositoryProvider.overrideWith(
          (ref) => ProductRepository.forTesting(rpc: emptyRpc),
        ),
        analyticsClientProvider.overrideWith(
          (ref) => AnalyticsClient.forTesting(
            rpc: emptyRpc,
            appVersion: 'test',
            platform: 'test',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    await notifier.requestPermission(); // 승인 → scanning
    await notifier.processBarcode('4006381333931'); // → processing
    expect(
      container.read(scanControllerProvider).status,
      ScanStatus.processing,
    );

    // 결과 화면 도중 background→복귀, 실제 권한 철회 + 조회 실패 → fail-closed
    await expectLater(notifier.refreshPermission(), throwsA(isA<Exception>()));
    expect(
      container.read(scanControllerProvider).status,
      ScanStatus.processing,
    );

    notifier.resumeScanning(); // 결과 화면 닫힘 → processing 탈출
    expect(
      container.read(scanControllerProvider).status,
      ScanStatus.permissionDenied,
    );
  });
}

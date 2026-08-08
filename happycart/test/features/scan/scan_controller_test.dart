import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
  // 기존 상태는 그대로 유지한다.
  test('refreshPermission: 조회 실패 시 예외를 전파하고 상태를 유지한다', () async {
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

    await notifier.requestPermission(); // scanning
    expect(container.read(scanControllerProvider).status, ScanStatus.scanning);

    await expectLater(notifier.refreshPermission(), throwsA(isA<Exception>()));
    expect(container.read(scanControllerProvider).status, ScanStatus.scanning);
  });
}

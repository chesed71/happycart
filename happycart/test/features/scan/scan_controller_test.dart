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
  // 크래시 방지 핵심 계약: 권한 결과가 오기 전에 lifecycle resumed 가 먼저
  // 전달돼도 스캐너를 조기 시작하지 않는다(최초 idle = 권한 대기).
  test('resume() before permission granted keeps idle', () {
    final container = _containerWith(PermissionStatus.granted);
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    expect(container.read(scanControllerProvider).status, ScanStatus.idle);
    notifier.resume(); // 권한 Future 완료 전 resumed 가 온 상황
    expect(container.read(scanControllerProvider).status, ScanStatus.idle);
  });

  // 권한 승인 후에는 pause→resume 사이클이 scanning 을 정상 복원해야 한다.
  test('granted 후 pause→resume 은 scanning 을 복원한다', () async {
    final container = _containerWith(PermissionStatus.granted);
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    await notifier.requestPermission();
    expect(container.read(scanControllerProvider).status, ScanStatus.scanning);

    notifier.pause();
    expect(container.read(scanControllerProvider).status, ScanStatus.idle);

    notifier.resume();
    expect(container.read(scanControllerProvider).status, ScanStatus.scanning);
  });

  // 권한 거부 시 permissionDenied 로 남고 resume 은 상태를 바꾸지 않는다.
  test('denied 후 resume 은 permissionDenied 를 유지한다', () async {
    final container = _containerWith(PermissionStatus.denied);
    addTearDown(container.dispose);
    final notifier = container.read(scanControllerProvider.notifier);

    await notifier.requestPermission();
    expect(
      container.read(scanControllerProvider).status,
      ScanStatus.permissionDenied,
    );

    notifier.resume();
    expect(
      container.read(scanControllerProvider).status,
      ScanStatus.permissionDenied,
    );
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
}

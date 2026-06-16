import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/barcode_validator.dart';
import '../../data/analytics_client.dart';
import '../../data/exceptions.dart';
import '../../data/product_repository.dart';
import '../result/result_state.dart';

/// 스캔 화면이 가질 수 있는 4가지 상태 (스펙 §6.1).
enum ScanStatus { idle, scanning, permissionDenied, processing }

/// 스캐너 상태 모델.
///
/// `lastResult` 는 결과 화면을 띄우고 다시 스캔 모드로 돌아온 직후 한 번 더
/// 같은 결과를 재사용하고 싶을 때를 대비해 보관한다 (MVP 에서는 단순히
/// 디버깅·로깅 편의용).
@immutable
class ScanState {
  final ScanStatus status;
  final ResultState? lastResult;

  const ScanState({
    required this.status,
    this.lastResult,
  });

  ScanState copyWith({
    ScanStatus? status,
    ResultState? lastResult,
  }) {
    return ScanState(
      status: status ?? this.status,
      lastResult: lastResult ?? this.lastResult,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScanState &&
          runtimeType == other.runtimeType &&
          status == other.status &&
          lastResult == other.lastResult;

  @override
  int get hashCode => Object.hash(status, lastResult);
}

/// 권한 요청을 mock 하기 위한 얇은 추상화.
typedef CameraPermissionRequester = Future<PermissionStatus> Function();

Future<PermissionStatus> _defaultCameraPermissionRequester() {
  return Permission.camera.request();
}

/// 권한 요청기 — 테스트에서는 [overrideWith] 로 mock 한다.
final cameraPermissionRequesterProvider =
    Provider<CameraPermissionRequester>((_) => _defaultCameraPermissionRequester);

/// 스캔 화면 컨트롤러 (스펙 §6.1, §7).
///
/// 책임:
/// - 카메라 권한 요청 → 결과에 따라 상태 전이.
/// - 인식된 바코드 → 검증 → Repository 조회 → ResultState 매핑 →
///   AnalyticsClient 로깅. 라우팅은 UI 레이어가 담당한다.
class ScanController extends Notifier<ScanState> {
  @override
  ScanState build() => const ScanState(status: ScanStatus.idle);

  /// 카메라 권한을 요청하고 결과에 따라 상태를 전이한다.
  Future<void> requestPermission() async {
    final requester = ref.read(cameraPermissionRequesterProvider);
    final result = await requester();
    if (result.isGranted) {
      state = state.copyWith(status: ScanStatus.scanning);
    } else {
      state = state.copyWith(status: ScanStatus.permissionDenied);
    }
  }

  /// 바코드 detection 콜백에서 호출.
  ///
  /// - 잘못된 EAN 체크섬은 무시 (`null` 반환).
  /// - 이미 `processing` 상태면 무시 (디바운스).
  /// - 정상 흐름이면 `processing` 으로 전이 → RPC 조회 → 결과 [ResultState]
  ///   를 반환한다. 호출 측은 이 결과로 `ResultPage` 를 push 한다.
  Future<ResultState?> processBarcode(String code) async {
    if (!BarcodeValidator.isValidEan(code)) return null;
    if (state.status != ScanStatus.scanning) return null;

    state = state.copyWith(status: ScanStatus.processing);

    final format = code.length == 13 ? 'EAN-13' : 'EAN-8';
    final stopwatch = Stopwatch()..start();
    final repo = ref.read(productRepositoryProvider);
    final analytics = ref.read(analyticsClientProvider);

    try {
      final product = await repo.lookupByBarcode(code);
      final latencyMs = stopwatch.elapsedMilliseconds;

      if (product == null) {
        unawaited(repo.logPendingProduct(code));
        analytics.logNotFound(barcodeFormat: format, latencyMs: latencyMs);
        final result = ResultState.notFound(code);
        state = state.copyWith(lastResult: result);
        return result;
      }
      analytics.logScanSuccess(
        barcodeFormat: format,
        verdict: product.verdict,
        latencyMs: latencyMs,
      );
      final result = ResultState.success(product);
      state = state.copyWith(lastResult: result);
      return result;
    } on NetworkException {
      final latencyMs = stopwatch.elapsedMilliseconds;
      analytics.logNetworkError(barcodeFormat: format, latencyMs: latencyMs);
      // onRetry 는 동일 코드를 다시 처리하도록 한다. 결과 화면이 dismiss 되면
      // 호출 측에서 [resumeScanning] 을 부르고, 사용자가 "다시 시도" 를 누르면
      // 화면에서 다시 processBarcode 를 호출하기 때문에 여기서는 빈 콜백만 둔다.
      final result = ResultState.networkError(code, onRetry: () {});
      state = state.copyWith(lastResult: result);
      return result;
    }
  }

  /// 결과 화면이 닫힌 뒤 스캐너를 재개한다.
  void resumeScanning() {
    state = state.copyWith(status: ScanStatus.scanning);
  }

  /// 라이프사이클: 백그라운드 진입 시 호출.
  void pause() {
    if (state.status == ScanStatus.scanning) {
      state = state.copyWith(status: ScanStatus.idle);
    }
  }

  /// 라이프사이클: 포그라운드 복귀 시 호출.
  void resume() {
    if (state.status == ScanStatus.idle) {
      state = state.copyWith(status: ScanStatus.scanning);
    }
  }
}

/// Riverpod: 스캐너 컨트롤러.
final scanControllerProvider =
    NotifierProvider<ScanController, ScanState>(ScanController.new);

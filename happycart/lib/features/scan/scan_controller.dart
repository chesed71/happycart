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

  /// 카메라 권한이 "확인된" 승인 상태인지. 실제 카메라 제어(UI)가 이 값을 함께
  /// 보고 켜지므로, status 가 (경쟁으로) scanning 이더라도 권한이 미확정이면
  /// 카메라를 시작하지 않는다.
  final bool permissionGranted;

  const ScanState({
    required this.status,
    this.lastResult,
    this.permissionGranted = false,
  });

  ScanState copyWith({
    ScanStatus? status,
    ResultState? lastResult,
    bool? permissionGranted,
  }) {
    return ScanState(
      status: status ?? this.status,
      lastResult: lastResult ?? this.lastResult,
      permissionGranted: permissionGranted ?? this.permissionGranted,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScanState &&
          runtimeType == other.runtimeType &&
          status == other.status &&
          lastResult == other.lastResult &&
          permissionGranted == other.permissionGranted;

  @override
  int get hashCode => Object.hash(status, lastResult, permissionGranted);
}

/// 권한 요청을 mock 하기 위한 얇은 추상화.
typedef CameraPermissionRequester = Future<PermissionStatus> Function();

Future<PermissionStatus> _defaultCameraPermissionRequester() {
  return Permission.camera.request();
}

/// 권한 요청기 — 테스트에서는 [overrideWith] 로 mock 한다.
final cameraPermissionRequesterProvider =
    Provider<CameraPermissionRequester>((_) => _defaultCameraPermissionRequester);

/// 권한 "조회"(요청 아님)를 mock 하기 위한 얇은 추상화. foreground 복귀 시
/// 설정 앱에서 바뀐 권한을 다이얼로그 없이 재확인하는 데 쓴다.
typedef CameraPermissionChecker = Future<PermissionStatus> Function();

Future<PermissionStatus> _defaultCameraPermissionChecker() {
  return Permission.camera.status;
}

/// 권한 조회기 — 테스트에서는 [overrideWith] 로 mock 한다.
final cameraPermissionCheckerProvider =
    Provider<CameraPermissionChecker>((_) => _defaultCameraPermissionChecker);

/// 스캔 화면 컨트롤러 (스펙 §6.1, §7).
///
/// 책임:
/// - 카메라 권한 요청 → 결과에 따라 상태 전이.
/// - 인식된 바코드 → 검증 → Repository 조회 → ResultState 매핑 →
///   AnalyticsClient 로깅. 라우팅은 UI 레이어가 담당한다.
class ScanController extends Notifier<ScanState> {
  // 권한 작업(요청/재조회) 세대 토큰. 여러 작업이 겹칠 때 가장 최근에 시작한
  // 작업의 결과만 반영해, 늦게 끝난 오래된 조회가 최신 상태를 덮어쓰지 않게 한다.
  int _permissionGeneration = 0;
  // 진행 중인 명시적 권한 "요청"(다이얼로그) 개수. 요청 결과가 권위이므로 그
  // 사이의 재조회(refresh)가 요청을 무효화하지 않도록 하는 데 쓴다. 중복 요청도
  // 안전하도록 boolean 이 아니라 카운터로 둔다(모두 끝나야 0).
  int _pendingRequests = 0;

  @override
  ScanState build() => const ScanState(status: ScanStatus.idle);

  /// 권한 결과를 상태에 반영한다. 승인이면 대기(idle)/거부(permissionDenied)
  /// 상태에서 scanning 으로, 미승인이면 permissionDenied 로 전이한다.
  /// permissionGranted 는 항상 함께 갱신해 카메라 제어가 반응하도록 한다.
  void _applyPermissionResult(bool granted) {
    if (granted) {
      final resume = state.status == ScanStatus.permissionDenied ||
          state.status == ScanStatus.idle;
      state = state.copyWith(
        status: resume ? ScanStatus.scanning : null,
        permissionGranted: true,
      );
    } else {
      final deny = state.status != ScanStatus.permissionDenied;
      state = state.copyWith(
        status: deny ? ScanStatus.permissionDenied : null,
        permissionGranted: false,
      );
    }
  }

  /// 카메라 권한을 요청하고 결과에 따라 상태를 전이한다.
  Future<void> requestPermission() async {
    _pendingRequests++;
    // 진행 중이던 재조회(refresh)가 있으면 그 결과를 무효화한다(요청 우선).
    final generation = ++_permissionGeneration;
    try {
      final requester = ref.read(cameraPermissionRequesterProvider);
      final result = await requester();
      if (generation != _permissionGeneration) return;
      _applyPermissionResult(result.isGranted);
    } finally {
      _pendingRequests--;
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
    // 결과 화면 도중 설정에서 권한이 철회됐을 수 있으므로, 승인 상태일 때만
    // scanning 으로 되돌린다(권한 없이 카메라를 재시작하지 않도록). 설령 여기서
    // scanning 으로 복원되더라도, 진행 중인 재조회가 실패로 permissionGranted 를
    // 내리면 카메라 제어(_syncCamera)가 이를 보고 카메라를 켜지 않는다.
    if (state.permissionGranted) {
      state = state.copyWith(status: ScanStatus.scanning);
    } else if (state.status == ScanStatus.processing) {
      // 권한 미확정/철회 상태에서 결과 화면이 닫히면 processing 에 갇히지 않도록
      // 안내 화면으로 보낸다(다음 복귀의 재조회가 승인을 확인하면 자동 복구).
      state = state.copyWith(status: ScanStatus.permissionDenied);
    }
  }

  /// 라이프사이클: 백그라운드 진입 시 호출.
  void pause() {
    if (state.status == ScanStatus.scanning) {
      state = state.copyWith(status: ScanStatus.idle);
    }
  }

  /// foreground 복귀 시 실제 카메라 권한을 다이얼로그 없이 재조회해 상태를
  /// 동기화한다. 이 메서드가 복귀 시 스캔 재개도 겸한다(캐시된 권한값으로
  /// 낙관적 복원을 하지 않으므로, 조회가 실패하면 기존 상태를 유지해 권한 없이
  /// 카메라가 켜지지 않는다). 설정 앱에서 권한이 바뀐 경우를 반영한다:
  /// - 거부→승인: permissionDenied/idle → scanning 으로 복구
  /// - 승인→철회: scanning 등 → permissionDenied
  ///
  /// 조회기(`Permission.camera.status`)는 플랫폼 채널을 호출하므로 실패 시
  /// 예외를 던질 수 있다. 예외는 여기서 삼키지 않고 호출측이 non-fatal 로
  /// 기록하도록 전파한다(상태는 그대로 유지됨).
  Future<void> refreshPermission() async {
    // 명시적 권한 요청(다이얼로그)이 진행 중이면 재조회를 건너뛴다 — 요청
    // 결과가 권위이므로 재조회가 이를 무효화하지 않도록.
    if (_pendingRequests > 0) return;
    final generation = ++_permissionGeneration;
    // 재조회 중에는 권한을 "미확인"으로 낮춘다: 조회가 끝나기 전 resumeScanning
    // 등이 stale 승인값으로 카메라를 시작(일시적 stale start)하지 못하게 한다.
    // (복귀 중 카메라는 어차피 꺼져 있어 사용자 눈에 띄는 깜빡임은 없다.)
    // 조회가 실패해도 permissionGranted 는 내려간 채로 남아 fail-closed 이며,
    // 예외는 호출측 non-fatal 기록을 위해 그대로 전파한다.
    if (state.permissionGranted) {
      state = state.copyWith(permissionGranted: false);
    }
    final checker = ref.read(cameraPermissionCheckerProvider);
    final status = await checker();
    // 이 조회 이후 더 최신 권한 작업이 시작됐다면 오래된 결과는 폐기한다.
    if (generation != _permissionGeneration) return;
    _applyPermissionResult(status.isGranted);
  }
}

/// Riverpod: 스캐너 컨트롤러.
final scanControllerProvider =
    NotifierProvider<ScanController, ScanState>(ScanController.new);

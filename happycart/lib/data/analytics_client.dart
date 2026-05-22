import 'dart:io' show Platform;

import 'package:happycart/core/verdict.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'product_repository.dart' show RpcExecutor, supabaseClientProvider;

/// MVP 빌드 식별자. 추후 Task 15(릴리스 준비)에서 `package_info_plus` 로
/// 교체될 예정이다. 지금은 의존성을 늘리지 않고 상수 한 곳에서 관리한다.
const String kAppVersion = '0.1.0+1';

/// 스펙 §4.4 — `scan_events.barcode_format` CHECK 제약.
const _allowedBarcodeFormats = {'EAN-13', 'EAN-8'};

/// 스펙 §4.4 — `scan_events.platform` CHECK 제약.
const _allowedPlatforms = {'ios', 'android'};

/// 스펙 §4.4 — `scan_events.scan_latency_ms` CHECK 0 ≤ x ≤ 60000.
const _maxLatencyMs = 60000;

/// `log_scan_event` RPC 만 호출하는 익명 분석 클라이언트.
///
/// 핵심 계약 (스펙 §8.1):
/// 1. 모든 메서드는 RPC 실패를 삼키고 호출자에게 예외를 전파하지 않는다.
/// 2. RPC 호출 전 사전 검증으로 명백히 잘못된 payload 는 보내지 않는다.
/// 3. `app_version` / `platform` 은 매 호출마다 자동 첨부한다.
class AnalyticsClient {
  final RpcExecutor _rpc;
  final String _appVersion;
  final String _platform;

  AnalyticsClient(
    SupabaseClient client, {
    String appVersion = kAppVersion,
    String? platform,
  })  : _rpc = ((name, {params}) => client.rpc(name, params: params)),
        _appVersion = appVersion,
        _platform = platform ?? _detectPlatform();

  /// 테스트 전용 — RPC 실행기, 버전, 플랫폼을 모두 주입한다.
  @visibleForTesting
  AnalyticsClient.forTesting({
    required RpcExecutor rpc,
    required String appVersion,
    required String platform,
  })  : _rpc = rpc,
        _appVersion = appVersion,
        _platform = platform;

  Future<void> logScanSuccess({
    required String barcodeFormat,
    required Verdict verdict,
    required int latencyMs,
  }) {
    return _send(
      eventType: 'scan_success',
      barcodeFormat: barcodeFormat,
      verdict: verdict.wireName,
      latencyMs: latencyMs,
    );
  }

  Future<void> logNotFound({
    required String barcodeFormat,
    required int latencyMs,
  }) {
    return _send(
      eventType: 'not_found',
      barcodeFormat: barcodeFormat,
      verdict: null,
      latencyMs: latencyMs,
    );
  }

  Future<void> logInsufficient({
    required String barcodeFormat,
    required int latencyMs,
  }) {
    return _send(
      eventType: 'insufficient',
      barcodeFormat: barcodeFormat,
      verdict: Verdict.insufficient.wireName,
      latencyMs: latencyMs,
    );
  }

  Future<void> logNetworkError({
    required String barcodeFormat,
    required int latencyMs,
  }) {
    return _send(
      eventType: 'network_error',
      barcodeFormat: barcodeFormat,
      verdict: null,
      latencyMs: latencyMs,
    );
  }

  Future<void> _send({
    required String eventType,
    required String barcodeFormat,
    required String? verdict,
    required int latencyMs,
  }) async {
    // 사전 검증: RPC 의 CHECK 제약과 동일한 규칙. 실패하면 RPC 를 호출하지
    // 않고 debugPrint 로만 남겨 분석 누락이 사용자 흐름을 방해하지 않게 한다.
    if (!_allowedBarcodeFormats.contains(barcodeFormat)) {
      debugPrint(
        'AnalyticsClient: dropping event — invalid barcode_format '
        '"$barcodeFormat".',
      );
      return;
    }
    if (!_allowedPlatforms.contains(_platform)) {
      debugPrint(
        'AnalyticsClient: dropping event — invalid platform "$_platform".',
      );
      return;
    }
    if (latencyMs < 0 || latencyMs > _maxLatencyMs) {
      debugPrint(
        'AnalyticsClient: dropping event — latency $latencyMs ms out of '
        '[0, $_maxLatencyMs].',
      );
      return;
    }
    if (_appVersion.length > 32) {
      debugPrint(
        'AnalyticsClient: dropping event — app_version exceeds 32 chars.',
      );
      return;
    }

    try {
      await _rpc('log_scan_event', params: {
        'p_event_type': eventType,
        'p_barcode_format': barcodeFormat,
        'p_verdict': verdict,
        'p_scan_latency_ms': latencyMs,
        'p_app_version': _appVersion,
        'p_platform': _platform,
      });
    } catch (e, stack) {
      // 스펙 §8.1: 분석 실패가 사용자 흐름을 막아서는 안 된다.
      debugPrint('AnalyticsClient: log_scan_event failed silently: $e');
      debugPrintStack(stackTrace: stack);
    }
  }

  static String _detectPlatform() {
    if (kIsWeb) return 'web'; // CHECK 위반 → 사전 검증에서 드롭됨.
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    return 'other';
  }
}

/// Riverpod: `AnalyticsClient` 싱글톤.
final analyticsClientProvider = Provider<AnalyticsClient>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return AnalyticsClient(client);
});

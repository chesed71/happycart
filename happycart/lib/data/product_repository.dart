import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'exceptions.dart';
import 'models/data_report.dart';
import 'models/product_lookup_result.dart';

/// RPC 호출 시그니처. `SupabaseClient.rpc` 의 얇은 추상화로, 테스트에서
/// 전체 Supabase 체인 (`rpc → PostgrestFilterBuilder.select() → execute()`)
/// 을 mock 하지 않고 함수 하나만 주입해도 되도록 한다.
typedef RpcExecutor = Future<dynamic> Function(
  String fnName, {
  Map<String, dynamic>? params,
});

/// 스펙 §7 — 네트워크 응답이 5초 안에 오지 않으면 타임아웃 처리.
const Duration _defaultRpcTimeout = Duration(seconds: 5);

/// `lookup_product` RPC 만을 호출하는 얇은 어댑터.
///
/// MVP 에서 클라이언트가 알아야 하는 제품 정보는 RPC 한 번으로 끝난다 (스펙 §4.2).
/// Repository 는 단일 메서드 [lookupByBarcode] 만 노출하고, 외부 예외를
/// [NetworkException] 으로 정규화하는 역할만 한다.
class ProductRepository {
  final RpcExecutor _rpc;
  final Duration _timeout;

  ProductRepository(
    SupabaseClient client, {
    Duration timeout = _defaultRpcTimeout,
  })  : _rpc = ((name, {params}) => client.rpc(name, params: params)),
        _timeout = timeout;

  /// 테스트 전용 생성자 — RPC 실행기를 직접 주입한다.
  @visibleForTesting
  ProductRepository.forTesting({
    required RpcExecutor rpc,
    Duration timeout = _defaultRpcTimeout,
  })  : _rpc = rpc,
        _timeout = timeout;

  /// 미등록 바코드를 pending_products 테이블에 기록한다 (fire-and-forget).
  ///
  /// 실패해도 스캔 흐름에 영향을 주지 않으므로 예외를 삼킨다.
  Future<void> logPendingProduct(String barcode) async {
    try {
      await _rpc(
        'log_pending_product',
        params: {'p_barcode': barcode},
      ).timeout(_timeout);
    } catch (_) {
      // 백그라운드 적재 실패는 무시
    }
  }

  /// 데이터 오류 신고를 1건 적재한다.
  ///
  /// 성공하면 `true`. 실패는 예외를 던지지 않고 `false` 로 돌려준다 —
  /// 호출자(신고 시트)가 할 일은 "다시 시도해주세요" 안내뿐이고, 실패 원인별로
  /// 다르게 행동할 여지가 없기 때문이다.
  Future<bool> reportDataError({
    required String barcode,
    required ReportReason reason,
    List<ReportedIngredient> ingredients = const [],
  }) async {
    try {
      await _rpc(
        'report_data_error',
        params: {
          'p_barcode': barcode,
          'p_reason': reason.code,
          // 0023 의 data_reports_ingredients_len CHECK 과 같은 상한.
          // 넘기면 DB 가 거절하므로 보내기 전에 자른다.
          'p_ingredients':
              ingredients.take(50).map((e) => e.toJson()).toList(),
        },
      ).timeout(_timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 바코드로 제품 1건을 조회한다.
  ///
  /// - 0 행이면 `null` (미등록).
  /// - 네트워크/RPC/타임아웃 실패는 모두 [NetworkException] 으로 래핑.
  Future<ProductLookupResult?> lookupByBarcode(String barcode) async {
    try {
      final response = await _rpc(
        'lookup_product',
        params: {'p_barcode': barcode},
      ).timeout(_timeout);

      if (response is! List) {
        throw NetworkException(
          'lookup_product returned unexpected payload: ${response.runtimeType}',
        );
      }
      if (response.isEmpty) return null;

      final first = response.first;
      if (first is! Map) {
        throw NetworkException(
          'lookup_product row is not a Map: ${first.runtimeType}',
        );
      }
      return ProductLookupResult.fromRpcRow(
        Map<String, dynamic>.from(first),
      );
    } on NetworkException {
      rethrow;
    } on PostgrestException catch (e) {
      throw NetworkException('Supabase RPC failed: ${e.message}', cause: e);
    } on SocketException catch (e) {
      throw NetworkException('Socket failure: ${e.message}', cause: e);
    } on TimeoutException catch (e) {
      throw NetworkException('lookup_product timed out', cause: e);
    }
  }
}

/// Riverpod: 전역으로 초기화된 Supabase 인스턴스를 노출 (스펙 §4.4).
///
/// `main.dart` 가 `Supabase.initialize` 를 호출한 뒤에만 `read` 가능하다.
final supabaseClientProvider = Provider<SupabaseClient>((ref) {
  return Supabase.instance.client;
});

/// Riverpod: `ProductRepository` 싱글톤.
final productRepositoryProvider = Provider<ProductRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return ProductRepository(client);
});

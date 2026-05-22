import 'package:flutter/foundation.dart';

import '../../data/models/product_lookup_result.dart';

/// 결과 화면이 표현할 수 있는 상태 (스펙 §6.2).
///
/// `lookup_product` RPC 결과 + 네트워크 상태를 호출 측에서 sealed 분기로
/// 매핑한 뒤 `ResultPage` 가 이 sealed class 만 보고 렌더링한다.
/// SuccessResultState 안에서 verdict 가 [Verdict.okay] 인지 [Verdict.notOkay]
/// 인지에 따라 5가지 시각 상태(okay / not_okay / not_found / insufficient /
/// network_error) 가 모두 표현된다.
sealed class ResultState {
  const ResultState();

  factory ResultState.success(ProductLookupResult product) =
      SuccessResultState;
  factory ResultState.notFound(String barcode) = NotFoundResultState;
  factory ResultState.insufficient(ProductLookupResult product) =
      InsufficientResultState;
  factory ResultState.networkError(
    String barcode, {
    required VoidCallback onRetry,
  }) = NetworkErrorResultState;
}

final class SuccessResultState extends ResultState {
  final ProductLookupResult product;
  const SuccessResultState(this.product);
}

final class NotFoundResultState extends ResultState {
  final String barcode;
  const NotFoundResultState(this.barcode);
}

final class InsufficientResultState extends ResultState {
  final ProductLookupResult product;
  const InsufficientResultState(this.product);
}

final class NetworkErrorResultState extends ResultState {
  final String barcode;
  final VoidCallback onRetry;
  const NetworkErrorResultState(this.barcode, {required this.onRetry});
}

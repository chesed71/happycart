import 'bad_ingredients.dart';
import 'good_ingredients.dart';

/// 룰 버전 (스펙 §5.1).
///
/// v1.1.0 (2026-05-22): refined_sugar 카테고리 신설 — `설탕` alias 1개.
const String ruleVersion = 'v1.1.0';

/// 최종 평가 결과 (스펙 §5).
///
/// - [okay]: 매칭된 bad ingredient 없음.
/// - [notOkay]: bad ingredient 1개 이상 매칭.
///
/// 미등록(`not_found`)은 DB 행 부재로 표현되므로 enum에 포함하지 않는다.
/// 원재료 정보가 없는 제품은 판정 대상이 아니므로 products 테이블에 적재하지
/// 않는다 ([computeVerdict] 가 빈 토큰에 대해 throw).
enum Verdict { okay, notOkay }

extension VerdictWire on Verdict {
  /// DB enum / RPC 응답에서 사용하는 wire 표기.
  String get wireName {
    switch (this) {
      case Verdict.okay:
        return 'okay';
      case Verdict.notOkay:
        return 'not_okay';
    }
  }
}

/// wire 표기에서 enum으로 복원.
Verdict verdictFromWire(String wire) {
  switch (wire) {
    case 'okay':
      return Verdict.okay;
    case 'not_okay':
      return Verdict.notOkay;
    default:
      throw ArgumentError('Unknown verdict wire: $wire');
  }
}

/// 평가 대상 제품 입력 (스펙 §5.2).
///
/// [tokens] 는 라벨에서 추출·정규화된 원재료 토큰 리스트.
/// 정규화는 시드/관리 파이프라인에서 수행 — 룰 패키지는 비교만 한다.
///
/// 빈 리스트는 판정 불가 — [computeVerdict] 가 ArgumentError 를 던진다.
class IngredientInput {
  final List<String> tokens;

  const IngredientInput({this.tokens = const []});
}

/// 매칭 결과 한 건 (스펙 §5.3 ~ §5.4).
class IngredientMatch {
  /// canonical 키 (예: `aspartame`, `hfcs`, `bha`).
  final String canonicalKey;

  /// 매칭된 원본 alias (사용자 표시용).
  final String matchedAlias;

  /// 카테고리 reason code (예: `artificial_sweetener`).
  final String reasonCode;

  const IngredientMatch({
    required this.canonicalKey,
    required this.matchedAlias,
    required this.reasonCode,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IngredientMatch &&
          runtimeType == other.runtimeType &&
          canonicalKey == other.canonicalKey &&
          matchedAlias == other.matchedAlias &&
          reasonCode == other.reasonCode;

  @override
  int get hashCode =>
      canonicalKey.hashCode ^ matchedAlias.hashCode ^ reasonCode.hashCode;

  @override
  String toString() =>
      'IngredientMatch($reasonCode/$canonicalKey via "$matchedAlias")';
}

/// verdict + 매칭 상세 (스펙 §5.5).
class VerdictResult {
  final Verdict verdict;
  final List<IngredientMatch> badMatches;
  final List<IngredientMatch> goodMatches;

  const VerdictResult({
    required this.verdict,
    this.badMatches = const [],
    this.goodMatches = const [],
  });

  /// reason code 중복 없이 정렬된 리스트. DB `verdict_reason_codes` 컬럼 적재용.
  List<String> get reasonCodes {
    final set = <String>{};
    for (final m in badMatches) {
      set.add(m.reasonCode);
    }
    final list = set.toList()..sort();
    return list;
  }

  /// canonical key 중복 없이 정렬. DB `bad_ingredients_detected` 적재용.
  List<String> get badCanonicalKeys {
    final set = <String>{};
    for (final m in badMatches) {
      set.add(m.canonicalKey);
    }
    final list = set.toList()..sort();
    return list;
  }

  /// canonical key 중복 없이 정렬. DB `good_ingredients_detected` 적재용.
  List<String> get goodCanonicalKeys {
    final set = <String>{};
    for (final m in goodMatches) {
      set.add(m.canonicalKey);
    }
    final list = set.toList()..sort();
    return list;
  }

  @override
  String toString() =>
      'VerdictResult($verdict, bad=${badCanonicalKeys.join(",")}, '
      'good=${goodCanonicalKeys.join(",")})';
}

/// 룰 핵심 — 토큰 리스트 → VerdictResult (스펙 §5.5).
///
/// 알고리즘:
/// 1. tokens 비어있으면 → ArgumentError (판정 불가, 적재 대상 아님).
/// 2. 각 토큰을 normalize 후 bad/good 사전과 매칭.
/// 3. bad 매칭 1개 이상이면 → notOkay. 아니면 → okay.
/// 4. good 매칭은 결과 화면 보조 — verdict 산정에는 영향 없음.
VerdictResult computeVerdict(IngredientInput input) {
  if (input.tokens.isEmpty) {
    throw ArgumentError.value(
      input.tokens,
      'input.tokens',
      '원재료 토큰이 비어 있어 판정할 수 없습니다 (적재 대상 아님)',
    );
  }

  final normalizedTokens = input.tokens
      .map(normalizeIngredientToken)
      .where((t) => t.isNotEmpty)
      .toList(growable: false);

  if (normalizedTokens.isEmpty) {
    throw ArgumentError.value(
      input.tokens,
      'input.tokens',
      '정규화 후 유효한 원재료 토큰이 없어 판정할 수 없습니다',
    );
  }

  final badMatches = <IngredientMatch>[];
  for (final entry in badIngredientCatalog) {
    final hit = _findFirstMatch(normalizedTokens, entry);
    if (hit != null) {
      badMatches.add(
        IngredientMatch(
          canonicalKey: entry.canonicalKey,
          matchedAlias: hit,
          reasonCode: entry.reasonCode,
        ),
      );
    }
  }

  final goodMatches = <IngredientMatch>[];
  for (final entry in goodIngredientCatalog) {
    final hit = _findFirstMatch(normalizedTokens, entry);
    if (hit != null) {
      goodMatches.add(
        IngredientMatch(
          canonicalKey: entry.canonicalKey,
          matchedAlias: hit,
          reasonCode: entry.reasonCode,
        ),
      );
    }
  }

  final verdict = badMatches.isEmpty ? Verdict.okay : Verdict.notOkay;
  return VerdictResult(
    verdict: verdict,
    badMatches: badMatches,
    goodMatches: goodMatches,
  );
}

/// 토큰 정규화: 소문자, 공백·괄호·하이픈 제거.
///
/// 시드 파이프라인이 이미 정규화된 토큰을 넣지만, 안전망으로 룰 함수 내부에서도
/// 한 번 더 정규화한다. alias 도 동일 함수로 정규화해 비교한다.
String normalizeIngredientToken(String raw) {
  final buffer = StringBuffer();
  for (final rune in raw.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == ' ' || ch == '\t' || ch == '\n') continue;
    if (ch == '(' || ch == ')' || ch == '[' || ch == ']') continue;
    if (ch == '-' || ch == '_' || ch == '/' || ch == ',' || ch == '.') continue;
    buffer.write(ch.toLowerCase());
  }
  return buffer.toString();
}

/// 카탈로그 엔트리 한 건과 토큰 리스트를 비교. 매칭된 alias 원본을 반환.
///
/// E-number alias 는 단어 경계 비교 (E1400 ≠ E14000) — alias 가 `e\d+` 형태이면
/// 정확 매칭(token == alias)만 인정한다. 그 외 alias 는 부분 문자열 포함이면 매칭.
String? _findFirstMatch(List<String> normalizedTokens, IngredientEntry entry) {
  for (final alias in entry.aliases) {
    final normAlias = normalizeIngredientToken(alias);
    if (normAlias.isEmpty) continue;
    final isENumber = RegExp(r'^e\d+$').hasMatch(normAlias);
    for (final token in normalizedTokens) {
      if (isENumber) {
        if (token == normAlias) return alias;
      } else {
        if (token.contains(normAlias)) return alias;
      }
    }
  }
  return null;
}

/// `data/ingredient_catalog.json` 엔트리의 위험도 메타데이터
/// (`riskLevel`·`riskReason`·`riskEvidence`) 를 검증하는 순수 함수.
///
/// bad 엔트리: `riskLevel` 이 `high`/`medium`/`low` 중 하나여야 하고,
/// `riskReason` 이 공백이 아닌 문자열이어야 한다. `riskEvidence` 는 선택이며,
/// 값이 있으면 공백이 아닌 문자열이어야 한다.
/// good 엔트리: 세 필드 모두 부재(non-null 값이 오면 예외)여야 한다.
///
/// 위반 시 [FormatException] 을 던진다 — `exit()` 를 호출하지 않는다.
/// `tool/generate_catalog.dart` 의 `buildCatalogParts` 가 카탈로그 생성 경로에
/// 이 함수를 결합해 검증을 우회할 수 없게 한다.
library;

const _allowedRiskLevels = {'high', 'medium', 'low'};

void validateRiskMeta(Map<String, Object?> entry, {required bool isBad}) {
  final canonicalKey = entry['canonicalKey'];

  if (isBad) {
    final riskLevel = entry['riskLevel'];
    if (riskLevel is! String || !_allowedRiskLevels.contains(riskLevel)) {
      throw FormatException(
        'bad 엔트리 "$canonicalKey"의 riskLevel이 high/medium/low 중 하나가 아닙니다: $riskLevel',
      );
    }

    final riskReason = entry['riskReason'];
    if (riskReason is! String || riskReason.trim().isEmpty) {
      throw FormatException(
        'bad 엔트리 "$canonicalKey"의 riskReason이 공백 아닌 문자열이 아닙니다: $riskReason',
      );
    }

    final riskEvidence = entry['riskEvidence'];
    if (riskEvidence != null &&
        (riskEvidence is! String || riskEvidence.trim().isEmpty)) {
      throw FormatException(
        'bad 엔트리 "$canonicalKey"의 riskEvidence가 공백 아닌 문자열이 아닙니다: $riskEvidence',
      );
    }
    return;
  }

  for (final key in const ['riskLevel', 'riskReason', 'riskEvidence']) {
    if (entry[key] != null) {
      throw FormatException(
        'good 엔트리 "$canonicalKey"는 위험도 메타($key)를 가질 수 없습니다: ${entry[key]}',
      );
    }
  }
}

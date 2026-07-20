/// `data/ingredient_catalog.json` (JSON 진실원) → `lib/src/bad_ingredients.g.dart`,
/// `lib/src/good_ingredients.g.dart` (part 파일) 생성 스크립트.
///
/// `dart run tool/generate_catalog.dart` (패키지 루트에서 실행).
/// 입력 경로를 첫 인자로 넘기면 그 파일을 읽는다(테스트용) — 출력 경로는 항상
/// 고정(`lib/src/*.g.dart`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:happycart_rules/src/risk_validation.dart';

/// bad 측 reasonCode 허용값 (`BadReasonCode`와 동일 — lib/src/bad_ingredients.dart 참조).
const _badReasonCodes = {
  'artificial_sweetener',
  'artificial_color',
  'hfcs',
  'seed_oil',
  'hydrogenated_oil',
  'synthetic_preservative',
  'nitrite',
  'carrageenan',
  'emulsifier_concern',
  'opaque_flavor',
  'refined_flour',
  'bromate',
  'maltodextrin',
  'refined_sugar',
};

/// good 측 reasonCode 허용값 (`GoodReasonCode`와 동일 — lib/src/good_ingredients.dart 참조).
const _goodReasonCodes = {
  'clean_fat',
  'natural_sweetener',
  'natural_salt',
  'whole_food',
  'organic',
  'fermented',
  'whole_grain',
  'pasture_raised',
  'grass_fed',
};

void main(List<String> args) {
  final inputFile = args.isNotEmpty
      ? File(args[0])
      : File.fromUri(
          Platform.script.resolve('../data/ingredient_catalog.json'),
        );
  final badOutputFile = File.fromUri(
    Platform.script.resolve('../lib/src/bad_ingredients.g.dart'),
  );
  final goodOutputFile = File.fromUri(
    Platform.script.resolve('../lib/src/good_ingredients.g.dart'),
  );

  final decoded = jsonDecode(inputFile.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    stderr.writeln('${inputFile.path}: top-level JSON은 object여야 합니다.');
    exit(1);
  }

  final Map<String, String> parts;
  try {
    parts = buildCatalogParts(decoded);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }

  badOutputFile.writeAsStringSync(parts['bad']!);
  goodOutputFile.writeAsStringSync(parts['good']!);

  final format = Process.runSync('dart', [
    'format',
    badOutputFile.path,
    goodOutputFile.path,
  ]);
  if (format.exitCode != 0) {
    stderr.writeln('dart format 실패:\n${format.stdout}\n${format.stderr}');
    exit(1);
  }

  stdout.writeln(
    'Generated bad=${_countEntries(decoded, 'bad')}, good=${_countEntries(decoded, 'good')}',
  );
}

int _countEntries(Map<String, Object?> decoded, String key) =>
    (decoded[key] as List).length;

/// 파싱된 카탈로그 맵(`{schemaVersion, bad, good}`)을 검증하고, 두 `.g.dart`
/// 소스 문자열을 `{'bad': ..., 'good': ...}` 로 반환한다.
///
/// **파일 I/O 를 하지 않는 순수 함수** — 검증 위반 시 [FormatException] 을
/// 던진다(`exit()` 호출 없음). 카탈로그 생성 출력이 이 함수를 거쳐서만
/// 나오므로, 검증을 우회하면 출력도 만들 수 없다.
Map<String, String> buildCatalogParts(Map<String, Object?> decoded) {
  if (decoded['schemaVersion'] != 1) {
    throw FormatException(
      'schemaVersion 은 1 이어야 합니다 (실제: ${decoded['schemaVersion']}).',
    );
  }

  final badJson = decoded['bad'];
  final goodJson = decoded['good'];
  if (badJson is! List) throw FormatException('"bad" 는 리스트여야 합니다.');
  if (goodJson is! List) throw FormatException('"good" 는 리스트여야 합니다.');

  final seenKeys = <String>{};
  final badEntries = _validateEntries(
    badJson,
    label: 'bad',
    allowedReasonCodes: _badReasonCodes,
    seenKeys: seenKeys,
    isBad: true,
  );
  final goodEntries = _validateEntries(
    goodJson,
    label: 'good',
    allowedReasonCodes: _goodReasonCodes,
    seenKeys: seenKeys,
    isBad: false,
  );

  return {
    'bad': _partSource(
      partOfFileName: 'bad_ingredients.dart',
      catalogName: 'badIngredientCatalog',
      entries: badEntries,
    ),
    'good': _partSource(
      partOfFileName: 'good_ingredients.dart',
      catalogName: 'goodIngredientCatalog',
      entries: goodEntries,
    ),
  };
}

class _Entry {
  final String canonicalKey;
  final String reasonCode;
  final String label;
  final List<String> aliases;
  final String? riskLevelWire;
  final String? riskReason;
  final String? riskEvidence;

  _Entry({
    required this.canonicalKey,
    required this.reasonCode,
    required this.label,
    required this.aliases,
    this.riskLevelWire,
    this.riskReason,
    this.riskEvidence,
  });
}

List<_Entry> _validateEntries(
  List<Object?> raw, {
  required String label,
  required Set<String> allowedReasonCodes,
  required Set<String> seenKeys,
  required bool isBad,
}) {
  final entries = <_Entry>[];
  for (final item in raw) {
    if (item is! Map<String, Object?>) {
      throw FormatException('"$label" 엔트리는 object여야 합니다: $item');
    }
    final map = item;

    final canonicalKey = map['canonicalKey'];
    if (canonicalKey is! String || canonicalKey.isEmpty) {
      throw FormatException(
        '"$label" 엔트리의 canonicalKey가 비지 않은 문자열이 아닙니다: $map',
      );
    }
    if (!seenKeys.add(canonicalKey)) {
      throw FormatException('중복된 canonicalKey: "$canonicalKey" ($map)');
    }

    final reasonCode = map['reasonCode'];
    if (reasonCode is! String || !allowedReasonCodes.contains(reasonCode)) {
      throw FormatException(
        '"$label" 엔트리 "$canonicalKey"의 reasonCode가 허용집합에 없습니다: $reasonCode',
      );
    }

    final entryLabel = map['label'];
    if (entryLabel is! String || entryLabel.trim().isEmpty) {
      throw FormatException(
        '"$label" 엔트리 "$canonicalKey"의 label 이 공백 아닌 문자열이 아닙니다: $entryLabel',
      );
    }

    final aliasesRaw = map['aliases'];
    if (aliasesRaw is! List || aliasesRaw.isEmpty) {
      throw FormatException(
        '"$label" 엔트리 "$canonicalKey"의 aliases가 비지 않은 리스트가 아닙니다: $aliasesRaw',
      );
    }
    final aliases = <String>[];
    for (final alias in aliasesRaw) {
      if (alias is! String || alias.isEmpty) {
        throw FormatException(
          '"$label" 엔트리 "$canonicalKey"의 alias가 비지 않은 문자열이 아닙니다: $alias',
        );
      }
      aliases.add(alias);
    }

    validateRiskMeta(map, isBad: isBad);

    entries.add(
      _Entry(
        canonicalKey: canonicalKey,
        reasonCode: reasonCode,
        label: entryLabel,
        aliases: aliases,
        riskLevelWire: isBad ? map['riskLevel'] as String : null,
        riskReason: isBad ? map['riskReason'] as String : null,
        riskEvidence: isBad ? map['riskEvidence'] as String? : null,
      ),
    );
  }
  return entries;
}

String _partSource({
  required String partOfFileName,
  required String catalogName,
  required List<_Entry> entries,
}) {
  final buffer = StringBuffer()
    ..writeln('// GENERATED by tool/generate_catalog.dart — DO NOT EDIT.')
    ..writeln('// Source: data/ingredient_catalog.json')
    ..writeln("part of '$partOfFileName';")
    ..writeln()
    ..writeln('const List<IngredientEntry> $catalogName = [');
  for (final entry in entries) {
    buffer
      ..writeln('  IngredientEntry(')
      ..writeln('    canonicalKey: ${_quote(entry.canonicalKey)},')
      ..writeln('    reasonCode: ${_quote(entry.reasonCode)},')
      ..writeln('    label: ${_quote(entry.label)},')
      ..writeln('    aliases: [${entry.aliases.map(_quote).join(', ')}],');
    if (entry.riskLevelWire != null) {
      buffer
        ..writeln('    riskLevel: RiskLevel.${entry.riskLevelWire},')
        ..writeln('    riskReason: ${_quote(entry.riskReason!)},');
      if (entry.riskEvidence != null) {
        buffer.writeln('    riskEvidence: ${_quote(entry.riskEvidence!)},');
      }
    }
    buffer.writeln('  ),');
  }
  buffer.writeln('];');

  return buffer.toString();
}

/// 작은따옴표 문자열 리터럴로 방출 — 역슬래시·작은따옴표·`$`(보간)·제어문자를
/// 방어적으로 이스케이프한다. 역슬래시를 먼저 치환해 이중 이스케이프를 피한다.
String _quote(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll(r'$', r'\$')
      .replaceAll("'", r"\'")
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
  return "'$escaped'";
}

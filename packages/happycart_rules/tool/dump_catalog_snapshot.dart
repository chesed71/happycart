/// 현재(inline) 카탈로그를 golden 스냅샷 JSON으로 덤프하는 1회성 부트스트랩 도구.
///
/// `dart run tool/dump_catalog_snapshot.dart` (패키지 루트에서 실행) 로
/// `test/golden/catalog_snapshot.json` 을 생성한다. 카탈로그 값은 하드코딩하지
/// 않고 라이브 `badIngredientCatalog`·`goodIngredientCatalog` 를 그대로 순회한다.
///
/// golden 은 "리팩터 전 지상진실"로 고정돼야 하므로, 스냅샷이 이미 있으면
/// 덮어쓰기를 거부한다. 의도적 재베이스라인(예: Phase 2 baseline 갱신)에만
/// `--force` 를 넘겨 덮어쓴다 — 실수로 라이브 값을 golden 에 재기록해 보존
/// 가드를 무력화하는 것을 막는다.
library;

import 'dart:convert';
import 'dart:io';

import 'package:happycart_rules/happycart_rules.dart';

Map<String, Object?> _entryToMap(IngredientEntry entry) => {
  'canonicalKey': entry.canonicalKey,
  'reasonCode': entry.reasonCode,
  'label': entry.label,
  'aliases': entry.aliases,
};

void main(List<String> args) {
  final outputFile = File.fromUri(
    Platform.script.resolve('../test/golden/catalog_snapshot.json'),
  );

  if (outputFile.existsSync() && !args.contains('--force')) {
    stderr.writeln('golden 스냅샷이 이미 있습니다: ${outputFile.path}');
    stderr.writeln(
      '재덤프는 지상진실 golden 을 라이브 값으로 재베이스라인합니다. '
      '의도한 경우에만 --force 를 넘기세요.',
    );
    exit(1);
  }

  final snapshot = {
    'bad': badIngredientCatalog.map(_entryToMap).toList(),
    'good': goodIngredientCatalog.map(_entryToMap).toList(),
  };

  const encoder = JsonEncoder.withIndent('  ');
  final json = '${encoder.convert(snapshot)}\n';

  outputFile.parent.createSync(recursive: true);
  outputFile.writeAsStringSync(json);

  stdout.writeln('Wrote ${outputFile.path}');
}

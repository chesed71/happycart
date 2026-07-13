/// 현재(inline) 카탈로그를 golden 스냅샷 JSON으로 덤프하는 1회성 도구.
///
/// `dart run tool/dump_catalog_snapshot.dart` (패키지 루트에서 실행) 로
/// `test/golden/catalog_snapshot.json` 을 생성한다. 카탈로그 값은 하드코딩하지
/// 않고 라이브 `badIngredientCatalog`·`goodIngredientCatalog` 를 그대로 순회한다.
library;

import 'dart:convert';
import 'dart:io';

import 'package:happycart_rules/happycart_rules.dart';

Map<String, Object?> _entryToMap(IngredientEntry entry) => {
  'canonicalKey': entry.canonicalKey,
  'reasonCode': entry.reasonCode,
  'aliases': entry.aliases,
};

void main() {
  final snapshot = {
    'bad': badIngredientCatalog.map(_entryToMap).toList(),
    'good': goodIngredientCatalog.map(_entryToMap).toList(),
  };

  const encoder = JsonEncoder.withIndent('  ');
  final json = '${encoder.convert(snapshot)}\n';

  final goldenDir = Directory.fromUri(
    Platform.script.resolve('../test/golden/'),
  );
  goldenDir.createSync(recursive: true);

  final outputFile = File.fromUri(
    Platform.script.resolve('../test/golden/catalog_snapshot.json'),
  );
  outputFile.writeAsStringSync(json);

  stdout.writeln('Wrote ${outputFile.path}');
}

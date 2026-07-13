import 'dart:convert';
import 'dart:io';

import 'package:happycart_rules/happycart_rules.dart';
import 'package:test/test.dart';

/// Step 1 덤프 도구와 동일한 직렬화 규칙 —
/// `{canonicalKey, reasonCode, aliases}` 순서 맵, 리스트 순서 유지.
Map<String, Object?> _entryToMap(IngredientEntry entry) => {
  'canonicalKey': entry.canonicalKey,
  'reasonCode': entry.reasonCode,
  'aliases': entry.aliases,
};

void main() {
  group('golden roundtrip', () {
    final golden =
        jsonDecode(File('test/golden/catalog_snapshot.json').readAsStringSync())
            as Map<String, Object?>;

    final goldenBad = golden['bad'] as List<Object?>;
    final goldenGood = golden['good'] as List<Object?>;

    final actualBad = badIngredientCatalog.map(_entryToMap).toList();
    final actualGood = goodIngredientCatalog.map(_entryToMap).toList();

    test('bad catalog length matches golden', () {
      expect(actualBad.length, goldenBad.length);
    });

    test('good catalog length matches golden', () {
      expect(actualGood.length, goldenGood.length);
    });

    test('bad catalog matches golden entry-by-entry (order preserved)', () {
      expect(actualBad, equals(goldenBad));
    });

    test('good catalog matches golden entry-by-entry (order preserved)', () {
      expect(actualGood, equals(goldenGood));
    });
  });
}

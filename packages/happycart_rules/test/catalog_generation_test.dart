import 'dart:convert';
import 'dart:io';

import 'package:happycart_rules/happycart_rules.dart';
import 'package:test/test.dart';

import '../tool/generate_catalog.dart' show buildCatalogParts;

/// Step 1 덤프 도구와 동일한 직렬화 규칙 —
/// `{canonicalKey, reasonCode, label, aliases}` 순서 맵, 리스트 순서 유지.
Map<String, Object?> _entryToMap(IngredientEntry entry) => {
  'canonicalKey': entry.canonicalKey,
  'reasonCode': entry.reasonCode,
  'label': entry.label,
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

  group('label coverage', () {
    test('모든 bad/good 엔트리가 공백 아닌 label 을 가진다', () {
      for (final e in [...badIngredientCatalog, ...goodIngredientCatalog]) {
        expect(
          e.label.trim(),
          isNotEmpty,
          reason: 'canonicalKey "${e.canonicalKey}" 의 label 이 비어 있음',
        );
      }
    });
  });

  group('buildCatalogParts 위험도 검증 (fixture seam)', () {
    Map<String, Object?> catalogFixture({
      List<Map<String, Object?>> bad = const [],
      List<Map<String, Object?>> good = const [],
    }) => {'schemaVersion': 1, 'bad': bad, 'good': good};

    test(
      '(a) 정상: bad riskLevel medium + good risk 없음 → bad 소스에 RiskLevel.medium 포함',
      () {
        final parts = buildCatalogParts(
          catalogFixture(
            bad: [
              {
                'canonicalKey': 'fx_bad',
                'reasonCode': 'artificial_sweetener',
                'label': '픽스처',
                'aliases': ['fx'],
                'riskLevel': 'medium',
                'riskReason': '테스트 사유',
              },
            ],
            good: [
              {
                'canonicalKey': 'fx_good',
                'reasonCode': 'clean_fat',
                'label': '픽스처굿',
                'aliases': ['fxg'],
              },
            ],
          ),
        );

        expect(parts['bad'], contains('riskLevel: RiskLevel.medium'));
      },
    );

    test('(b) bad + riskLevel 부재 → 예외', () {
      expect(
        () => buildCatalogParts(
          catalogFixture(
            bad: [
              {
                'canonicalKey': 'fx_bad',
                'reasonCode': 'artificial_sweetener',
                'label': '픽스처',
                'aliases': ['fx'],
                'riskReason': '테스트 사유',
              },
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('(c) bad + 빈 riskReason → 예외', () {
      expect(
        () => buildCatalogParts(
          catalogFixture(
            bad: [
              {
                'canonicalKey': 'fx_bad',
                'reasonCode': 'artificial_sweetener',
                'label': '픽스처',
                'aliases': ['fx'],
                'riskLevel': 'medium',
                'riskReason': '   ',
              },
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('(d) bad + riskLevel severe(allow-list 외) → 예외', () {
      expect(
        () => buildCatalogParts(
          catalogFixture(
            bad: [
              {
                'canonicalKey': 'fx_bad',
                'reasonCode': 'artificial_sweetener',
                'label': '픽스처',
                'aliases': ['fx'],
                'riskLevel': 'severe',
                'riskReason': '테스트 사유',
              },
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('(e) good + risk 메타 존재 → 예외', () {
      expect(
        () => buildCatalogParts(
          catalogFixture(
            good: [
              {
                'canonicalKey': 'fx_good',
                'reasonCode': 'clean_fat',
                'label': '픽스처굿',
                'aliases': ['fxg'],
                'riskLevel': 'low',
              },
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('CLI malformed 게이트 (real gate 회귀)', () {
    test('malformed 카탈로그로 CLI 실행 시 non-zero exit, 추적 .g.dart 는 불변', () async {
      final badGDartFile = File('lib/src/bad_ingredients.g.dart');
      final goodGDartFile = File('lib/src/good_ingredients.g.dart');
      final beforeBad = badGDartFile.readAsStringSync();
      final beforeGood = goodGDartFile.readAsStringSync();

      final tempDir = Directory.systemTemp.createTempSync('catalog_gen_test_');
      final malformedFile = File('${tempDir.path}/malformed_catalog.json')
        ..writeAsStringSync(
          jsonEncode({
            'schemaVersion': 1,
            'bad': [
              {
                'canonicalKey': 'test_key',
                'reasonCode': 'artificial_sweetener',
                'label': '테스트',
                'aliases': ['test'],
                // riskLevel 누락 → 검증 실패를 유도한다.
                'riskReason': '사유',
              },
            ],
            'good': [],
          }),
        );

      try {
        final result = await Process.run('dart', [
          'run',
          'tool/generate_catalog.dart',
          malformedFile.path,
        ]);

        expect(result.exitCode, isNot(0));
        expect(badGDartFile.readAsStringSync(), beforeBad);
        expect(goodGDartFile.readAsStringSync(), beforeGood);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('bad 카탈로그 위험도 무결성 (실 카탈로그)', () {
    // 스펙 §5 표(2026-07-19-notokay-ingredient-risk-display-design.md)에서
    // 손으로 옮긴 canonicalKey → RiskLevel 전체 매핑(32개). 카탈로그와 독립된
    // 기준이므로, 이 맵과 실제 카탈로그가 어긋나면(예: 두 성분의 위험도가
    // 뒤바뀜) 분포 카운트만으로는 못 잡는 오류도 여기서 잡는다.
    const expectedRiskLevels = <String, RiskLevel>{
      'hydrogenated': RiskLevel.high,
      'aspartame': RiskLevel.medium,
      'sucralose': RiskLevel.medium,
      'acesulfame_k': RiskLevel.medium,
      'saccharin': RiskLevel.medium,
      'red_40': RiskLevel.medium,
      'yellow_5': RiskLevel.medium,
      'yellow_6': RiskLevel.medium,
      'blue_1': RiskLevel.medium,
      'red_3': RiskLevel.medium,
      'hfcs': RiskLevel.medium,
      'bha': RiskLevel.medium,
      'bht': RiskLevel.medium,
      'tbhq': RiskLevel.medium,
      'sodium_nitrite': RiskLevel.medium,
      'sodium_nitrate': RiskLevel.medium,
      'polysorbate_80': RiskLevel.medium,
      'artificial_flavors': RiskLevel.medium,
      'potassium_bromate': RiskLevel.medium,
      'maltodextrin': RiskLevel.medium,
      'sugar': RiskLevel.medium,
      'soybean_oil': RiskLevel.low,
      'canola_oil': RiskLevel.low,
      'corn_oil': RiskLevel.low,
      'sunflower_oil_refined': RiskLevel.low,
      'cottonseed_oil': RiskLevel.low,
      'carrageenan': RiskLevel.low,
      'datem': RiskLevel.low,
      'mono_diglycerides': RiskLevel.low,
      'natural_flavors_opaque': RiskLevel.low,
      'bleached_flour': RiskLevel.low,
      'enriched_flour': RiskLevel.low,
    };

    test('expectedRiskLevels 는 32개 전부를 커버한다(무결성 테스트 자체 방어)', () {
      expect(expectedRiskLevels, hasLength(32));
    });

    test('badIngredientCatalog 각 엔트리의 riskLevel 이 §5 표와 정확히 일치한다', () {
      expect(badIngredientCatalog, hasLength(32));
      for (final entry in badIngredientCatalog) {
        expect(
          entry.riskLevel,
          expectedRiskLevels[entry.canonicalKey],
          reason: 'canonicalKey "${entry.canonicalKey}" 의 riskLevel 불일치',
        );
      }
    });

    test('모든 bad 엔트리는 non-null riskLevel + 비공백 riskReason 을 가진다', () {
      for (final entry in badIngredientCatalog) {
        expect(
          entry.riskLevel,
          isNotNull,
          reason: 'canonicalKey "${entry.canonicalKey}" 의 riskLevel 이 null',
        );
        expect(
          entry.riskReason,
          isNotNull,
          reason: 'canonicalKey "${entry.canonicalKey}" 의 riskReason 이 null',
        );
        expect(
          entry.riskReason!.trim(),
          isNotEmpty,
          reason: 'canonicalKey "${entry.canonicalKey}" 의 riskReason 이 비공백이 아님',
        );
      }
    });

    test('goodIngredientCatalog 전 엔트리는 위험도 3필드가 모두 null 이다', () {
      for (final entry in goodIngredientCatalog) {
        expect(
          entry.riskLevel,
          isNull,
          reason: 'canonicalKey "${entry.canonicalKey}" 의 riskLevel 이 non-null',
        );
        expect(
          entry.riskReason,
          isNull,
          reason:
              'canonicalKey "${entry.canonicalKey}" 의 riskReason 이 non-null',
        );
        expect(
          entry.riskEvidence,
          isNull,
          reason:
              'canonicalKey "${entry.canonicalKey}" 의 riskEvidence 가 non-null',
        );
      }
    });

    test('위험도 분포: 높음 1 · 보통 20 · 낮음 11', () {
      final counts = <RiskLevel, int>{};
      for (final entry in badIngredientCatalog) {
        final level = entry.riskLevel;
        if (level == null) continue;
        counts[level] = (counts[level] ?? 0) + 1;
      }
      expect(counts[RiskLevel.high], 1);
      expect(counts[RiskLevel.medium], 20);
      expect(counts[RiskLevel.low], 11);
    });
  });
}

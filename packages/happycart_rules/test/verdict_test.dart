import 'package:happycart_rules/happycart_rules.dart';
import 'package:test/test.dart';

void main() {
  group('computeVerdict — empty / insufficient', () {
    test('empty tokens → insufficient', () {
      final result = computeVerdict(const IngredientInput(tokens: []));
      expect(result.verdict, Verdict.insufficient);
      expect(result.badMatches, isEmpty);
      expect(result.goodMatches, isEmpty);
    });

    test('only blank tokens → insufficient', () {
      final result = computeVerdict(
        const IngredientInput(tokens: ['', '   ', '\n']),
      );
      expect(result.verdict, Verdict.insufficient);
    });
  });

  group('computeVerdict — okay path', () {
    test('단순 자연 원재료만 있으면 okay', () {
      final result = computeVerdict(
        const IngredientInput(
          tokens: ['엑스트라버진 올리브유', '천일염', '꿀'],
        ),
      );
      expect(result.verdict, Verdict.okay);
      expect(result.badMatches, isEmpty);
      expect(result.goodCanonicalKeys, containsAll(<String>[
        'extra_virgin_olive_oil',
        'sea_salt',
        'honey',
      ]));
    });

    test('알 수 없는 자연 원재료는 okay (false positive 방지)', () {
      final result = computeVerdict(
        const IngredientInput(tokens: ['양배추', '사과', '물']),
      );
      expect(result.verdict, Verdict.okay);
      expect(result.badMatches, isEmpty);
    });
  });

  group('computeVerdict — notOkay path', () {
    test('아스파탐 한 건만 있어도 notOkay', () {
      final result = computeVerdict(
        const IngredientInput(tokens: ['정제수', '아스파탐', '구연산']),
      );
      expect(result.verdict, Verdict.notOkay);
      expect(result.badCanonicalKeys, ['aspartame']);
      expect(result.reasonCodes, ['artificial_sweetener']);
    });

    test('HFCS 영문 alias 도 매칭', () {
      final result = computeVerdict(
        const IngredientInput(
          tokens: ['water', 'high fructose corn syrup', 'natural flavors'],
        ),
      );
      expect(result.verdict, Verdict.notOkay);
      expect(result.badCanonicalKeys, containsAll(<String>[
        'hfcs',
        'natural_flavors_opaque',
      ]));
    });

    test('대두유 / 카놀라유 — seed oil 카테고리로 매칭', () {
      final result = computeVerdict(
        const IngredientInput(tokens: ['대두유', '카놀라유', '설탕']),
      );
      expect(result.verdict, Verdict.notOkay);
      expect(result.reasonCodes, ['seed_oil']);
      expect(result.badCanonicalKeys, containsAll(<String>[
        'soybean_oil',
        'canola_oil',
      ]));
    });

    test('합성 보존제 + 색소 — reason code 두 개 누적', () {
      final result = computeVerdict(
        const IngredientInput(
          tokens: ['밀가루', '설탕', 'BHA', '황색5호'],
        ),
      );
      expect(result.verdict, Verdict.notOkay);
      expect(result.reasonCodes, containsAll(<String>[
        'synthetic_preservative',
        'artificial_color',
      ]));
    });

    test('아질산나트륨 (가공육 케이스)', () {
      final result = computeVerdict(
        const IngredientInput(tokens: ['돼지고기', '소금', '아질산나트륨']),
      );
      expect(result.verdict, Verdict.notOkay);
      expect(result.badCanonicalKeys, ['sodium_nitrite']);
    });

    test('트랜스지방 / 부분경화유 alias 매칭', () {
      final result = computeVerdict(
        const IngredientInput(tokens: ['밀가루', '부분경화유']),
      );
      expect(result.verdict, Verdict.notOkay);
      expect(result.badCanonicalKeys, ['hydrogenated']);
    });

    test('카라기난 alias 매칭', () {
      final result = computeVerdict(
        const IngredientInput(tokens: ['우유', '카라기난']),
      );
      expect(result.verdict, Verdict.notOkay);
      expect(result.badCanonicalKeys, ['carrageenan']);
    });
  });

  group('matching robustness', () {
    test('대소문자 무시', () {
      final result = computeVerdict(
        const IngredientInput(tokens: ['Water', 'AsPaRtAmE']),
      );
      expect(result.verdict, Verdict.notOkay);
      expect(result.badCanonicalKeys, ['aspartame']);
    });

    test('공백 / 하이픈 / 괄호 정규화', () {
      final result = computeVerdict(
        const IngredientInput(
          tokens: ['mono- and diglycerides', 'polysorbate-80'],
        ),
      );
      expect(result.verdict, Verdict.notOkay);
      expect(result.badCanonicalKeys, containsAll(<String>[
        'mono_diglycerides',
        'polysorbate_80',
      ]));
    });

    test('E-number 단어 경계 — E1400 ≠ E14000', () {
      final hit = computeVerdict(
        const IngredientInput(tokens: ['E1400']),
      );
      expect(hit.verdict, Verdict.notOkay);
      expect(hit.badCanonicalKeys, ['maltodextrin']);

      final miss = computeVerdict(
        const IngredientInput(tokens: ['E14000']),
      );
      expect(miss.verdict, Verdict.okay);
      expect(miss.badMatches, isEmpty);
    });

    test('Korean 천연향료 vs 영문 natural flavors — 둘 다 매칭', () {
      final kr = computeVerdict(
        const IngredientInput(tokens: ['정제수', '천연향료']),
      );
      expect(kr.badCanonicalKeys, ['natural_flavors_opaque']);

      final en = computeVerdict(
        const IngredientInput(tokens: ['water', 'natural flavors']),
      );
      expect(en.badCanonicalKeys, ['natural_flavors_opaque']);
    });
  });

  group('good ingredients alongside bad', () {
    test('Not Okay 상태에서도 good chip 누적', () {
      final result = computeVerdict(
        const IngredientInput(
          tokens: ['엑스트라버진 올리브유', '아스파탐'],
        ),
      );
      expect(result.verdict, Verdict.notOkay);
      expect(result.badCanonicalKeys, ['aspartame']);
      expect(result.goodCanonicalKeys, ['extra_virgin_olive_oil']);
    });
  });

  group('wire encoding', () {
    test('Verdict ↔ wire round-trip', () {
      for (final v in Verdict.values) {
        expect(verdictFromWire(v.wireName), v);
      }
    });

    test('not_okay wire name', () {
      expect(Verdict.notOkay.wireName, 'not_okay');
    });

    test('unknown wire throws', () {
      expect(() => verdictFromWire('warn'), throwsArgumentError);
    });
  });

  test('ruleVersion is v1.0.0', () {
    expect(ruleVersion, 'v1.0.0');
  });
}

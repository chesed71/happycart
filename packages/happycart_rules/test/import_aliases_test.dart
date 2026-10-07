import 'dart:io';

import 'package:happycart_rules/happycart_rules.dart';
import 'package:test/test.dart';

import '../tool/import_aliases.dart';

/// 소형 인메모리 카탈로그 픽스처 — {canonicalKey, reasonCode, aliases}.
Map<String, dynamic> _catalog() => {
  'schemaVersion': 1,
  'bad': [
    {
      'canonicalKey': 'red_40',
      'reasonCode': 'artificial_color',
      'aliases': ['적색40호', '적색 40호', 'E129'],
    },
    {
      'canonicalKey': 'yellow_6',
      'reasonCode': 'artificial_color',
      'aliases': ['황색6호', 'sunset yellow'],
    },
  ],
  'good': [
    {
      'canonicalKey': 'olive_oil',
      'reasonCode': 'whole_food',
      'aliases': ['올리브오일'],
    },
  ],
};

/// 승인 후보 한 건. preview 를 안 주면 정규화 정본으로 채운다(일치 케이스).
Map<String, dynamic> _cand(String key, String alias, {String? preview}) => {
  'canonicalKey': key,
  'reasonCode': 'artificial_color',
  'proposedAlias': alias,
  'normalizedPreview': preview ?? normalizeIngredientToken(alias),
  'reviewerStatus': '승인',
};

void main() {
  group('verifySnapshot', () {
    test('실제 해시와 일치하면 통과', () {
      final dir = Directory.systemTemp.createTempSync('import_aliases_test');
      try {
        final f = File('${dir.path}/cat.json')
          ..writeAsStringSync('{"schemaVersion":1,"bad":[],"good":[]}');
        final actual = sha256OfFile(f.path);
        expect(
          verifySnapshot({'catalogContentSha256': actual}, f.path),
          isEmpty,
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('해시 불일치면 reject', () {
      final dir = Directory.systemTemp.createTempSync('import_aliases_test');
      try {
        final f = File('${dir.path}/cat.json')
          ..writeAsStringSync('{"schemaVersion":1,"bad":[],"good":[]}');
        expect(
          verifySnapshot({'catalogContentSha256': 'deadbeef'}, f.path),
          isNotEmpty,
        );
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('verifyMembership', () {
    test('실존 canonicalKey 통과', () {
      expect(
        verifyMembership([_cand('red_40', '식용색소적색제40호')], _catalog()),
        isEmpty,
      );
    });
    test('미존재 canonicalKey reject', () {
      expect(verifyMembership([_cand('없는키', 'xxx')], _catalog()), isNotEmpty);
    });
  });

  group('verifyNormalizedPreview', () {
    test('preview 가 정규화 정본과 일치하면 통과', () {
      expect(verifyNormalizedPreview([_cand('red_40', '식용색소적색제40호')]), isEmpty);
    });
    test('preview drift 면 reject', () {
      expect(
        verifyNormalizedPreview([
          _cand('red_40', '식용색소적색제40호', preview: '틀린프리뷰'),
        ]),
        isNotEmpty,
      );
    });
  });

  group('verifyNewUniqueness', () {
    test('신규 정규화형이 유일하면 통과', () {
      expect(
        verifyNewUniqueness([_cand('red_40', '식용색소적색제40호')], _catalog()),
        isEmpty,
      );
    });
    test('기존 alias 와 정규화 충돌하면 reject', () {
      // '적색 40호'(공백변형)는 기존 '적색40호' 와 정규화형이 같다.
      expect(
        verifyNewUniqueness([_cand('red_40', '적색 40호')], _catalog()),
        isNotEmpty,
      );
    });
    test('두 신규 후보가 서로 정규화 충돌하면 reject', () {
      expect(
        verifyNewUniqueness([
          _cand('red_40', '식용색소적색제40호'),
          _cand('yellow_6', '식용색소 적색제40호'),
        ], _catalog()),
        isNotEmpty,
      );
    });
  });

  group('verifyNoOvermatch', () {
    test('다른 키를 커버하지 않으면 통과', () {
      expect(
        verifyNoOvermatch([_cand('red_40', '식용색소적색제40호')], _catalog()),
        isEmpty,
      );
    });
    test('다른 키의 기존 alias 를 커버하면 reject', () {
      // yellow_6 에 red_40 의 기존 alias '적색40호' 를 넣으면 그 키를 shadow → 과매칭.
      expect(
        verifyNoOvermatch([_cand('yellow_6', '적색40호')], _catalog()),
        isNotEmpty,
      );
    });
  });

  group('excludes 반영', () {
    Map<String, dynamic> withSugar() => {
      'schemaVersion': 1,
      'bad': [
        {
          'canonicalKey': 'sugar',
          'reasonCode': 'refined_sugar',
          'aliases': ['설탕', '원당'],
          'excludes': ['환원당'],
        },
        {
          'canonicalKey': 'reducing_x',
          'reasonCode': 'refined_sugar',
          'aliases': ['환원당시럽'],
        },
      ],
      'good': [],
    };
    test('자기 exclude 에 걸리는 신규 alias 는 무효로 reject', () {
      expect(
        verifyNotExcluded([_cand('sugar', '환원당')], withSugar()),
        isNotEmpty,
      );
      expect(verifyNotExcluded([_cand('sugar', '원당가루')], withSugar()), isEmpty);
    });
    test('exclude 로 런타임에 매칭 안 되는 다른 키 alias 는 과매칭 아님', () {
      // '당'은 '환원당시럽'을 커버하지만 sugar 의 exclude '환원당'을 포함하므로 런타임 매칭 없음.
      expect(verifyNoOvermatch([_cand('sugar', '당')], withSugar()), isEmpty);
    });
  });

  group('appendApproved', () {
    test('proposedAlias 원문을 해당 엔트리 aliases 뒤에 append', () {
      final cat = _catalog();
      final out = appendApproved(cat, [_cand('red_40', '식용색소적색제40호')]);
      final red =
          (out['bad'] as List).firstWhere((e) => e['canonicalKey'] == 'red_40')
              as Map;
      expect((red['aliases'] as List).last, '식용색소적색제40호');
      // 원본 카탈로그는 불변(깊은 복사)
      final origRed =
          (cat['bad'] as List).firstWhere((e) => e['canonicalKey'] == 'red_40')
              as Map;
      expect((origRed['aliases'] as List).contains('식용색소적색제40호'), isFalse);
    });

    test('normalizedPreview 가 아니라 proposedAlias 원문(공백 유지)을 반영', () {
      final out = appendApproved(_catalog(), [
        {
          'canonicalKey': 'red_40',
          'reasonCode': 'artificial_color',
          'proposedAlias': '식용색소 적색 제40호',
          'normalizedPreview': '식용색소적색제40호',
          'reviewerStatus': '승인',
        },
      ]);
      final red =
          (out['bad'] as List).firstWhere((e) => e['canonicalKey'] == 'red_40')
              as Map;
      expect((red['aliases'] as List).last, '식용색소 적색 제40호');
    });

    test('이미 존재하는 alias 는 중복 추가 안 함(멱등)', () {
      final once = appendApproved(_catalog(), [_cand('red_40', '식용색소적색제40호')]);
      final twice = appendApproved(once, [_cand('red_40', '식용색소적색제40호')]);
      final red =
          (twice['bad'] as List).firstWhere(
                (e) => e['canonicalKey'] == 'red_40',
              )
              as Map;
      final count = (red['aliases'] as List)
          .where((a) => a == '식용색소적색제40호')
          .length;
      expect(count, 1);
    });

    test('다른 엔트리·순서 불변', () {
      final out = appendApproved(_catalog(), [_cand('red_40', '식용색소적색제40호')]);
      final yellow =
          (out['bad'] as List).firstWhere(
                (e) => e['canonicalKey'] == 'yellow_6',
              )
              as Map;
      expect(yellow['aliases'], ['황색6호', 'sunset yellow']);
    });
  });
}

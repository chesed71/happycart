import 'package:flutter/material.dart';
import 'package:happycart_rules/happycart_rules.dart' as rules;

import '../../app/theme.dart';
import '../../core/disclaimer_card.dart';
import '../../core/verdict.dart';
import '../../data/models/product_lookup_result.dart';
import 'result_state.dart';

/// 결과 화면 (스펙 §6.2) — 5가지 상태 (okay / not_okay / not_found /
/// insufficient / network_error) 를 sealed [ResultState] 분기로 렌더링.
class ResultPage extends StatelessWidget {
  final ResultState state;
  final VoidCallback onRescan;

  const ResultPage({
    required this.state,
    required this.onRescan,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: switch (state) {
          SuccessResultState(:final product) =>
            _SuccessLayout(product: product, onRescan: onRescan),
          NotFoundResultState(:final barcode) =>
            _NotFoundLayout(barcode: barcode, onRescan: onRescan),
          InsufficientResultState(:final product) =>
            _InsufficientLayout(product: product, onRescan: onRescan),
          NetworkErrorResultState(:final onRetry) => _NetworkErrorLayout(
              onRetry: onRetry,
              onRescan: onRescan,
            ),
        },
      ),
    );
  }
}

String _verdictEmoji(Verdict v) {
  switch (v) {
    case Verdict.okay:
      return '✅';
    case Verdict.notOkay:
      return '⚠️';
    case Verdict.insufficient:
      return '❔';
  }
}

String _formatDate(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
}

const TextStyle _monoStyle = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Courier', 'monospace'],
  fontSize: 12,
  color: AppTheme.inkMute,
  letterSpacing: 0.5,
);

/// canonical key 를 한국어 라벨로 매핑 (chip 표시용).
String _canonicalLabel(String canonicalKey) {
  switch (canonicalKey) {
    // Bad
    case 'aspartame':
      return '아스파탐';
    case 'sucralose':
      return '수크랄로스';
    case 'acesulfame_k':
      return '아세설팜칼륨';
    case 'saccharin':
      return '사카린';
    case 'red_40':
      return '적색40호';
    case 'yellow_5':
      return '황색5호';
    case 'yellow_6':
      return '황색6호';
    case 'blue_1':
      return '청색1호';
    case 'red_3':
      return '적색3호';
    case 'hfcs':
      return '고과당 옥수수시럽';
    case 'soybean_oil':
      return '대두유';
    case 'canola_oil':
      return '카놀라유';
    case 'corn_oil':
      return '옥수수유';
    case 'sunflower_oil_refined':
      return '정제 해바라기씨유';
    case 'cottonseed_oil':
      return '면실유';
    case 'hydrogenated':
      return '경화유 / 트랜스지방';
    case 'bha':
      return 'BHA';
    case 'bht':
      return 'BHT';
    case 'tbhq':
      return 'TBHQ';
    case 'sodium_nitrite':
      return '아질산나트륨';
    case 'sodium_nitrate':
      return '질산나트륨';
    case 'carrageenan':
      return '카라기난';
    case 'polysorbate_80':
      return '폴리소르베이트 80';
    case 'datem':
      return 'DATEM';
    case 'mono_diglycerides':
      return '모노/디글리세리드';
    case 'natural_flavors_opaque':
      return '천연향료 (성분 비공개)';
    case 'artificial_flavors':
      return '인공향료';
    case 'bleached_flour':
      return '표백 밀가루';
    case 'enriched_flour':
      return '강화 밀가루';
    case 'potassium_bromate':
      return '브롬산칼륨';
    case 'maltodextrin':
      return '말토덱스트린';
    // Good
    case 'extra_virgin_olive_oil':
      return '엑스트라버진 올리브유';
    case 'avocado_oil':
      return '아보카도 오일';
    case 'coconut_oil':
      return '코코넛 오일';
    case 'grass_fed_butter':
      return '그래스페드 버터 / 기';
    case 'honey':
      return '꿀';
    case 'maple_syrup':
      return '메이플시럽';
    case 'date':
      return '대추야자';
    case 'sea_salt':
      return '천일염';
    case 'whole_grain':
      return '통곡물';
    case 'sprouted_grain':
      return '발아곡물';
    case 'kimchi':
      return '김치';
    case 'kefir':
      return '케피어';
    case 'sauerkraut':
      return '사우어크라우트';
    case 'kombucha':
      return '콤부차';
    case 'organic':
      return '유기농';
    case 'pasture_raised_egg':
      return '방목 달걀';
    case 'grass_fed_beef':
      return '그래스페드 소고기';
    default:
      return canonicalKey;
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  final Color background;
  const _Chip({
    required this.label,
    required this.color,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.1,
        ),
      ),
    );
  }
}

/// reason code 별로 bad ingredient 를 그룹핑해 표시.
class _BadIngredientGroups extends StatelessWidget {
  final List<String> reasonCodes;
  final List<String> badIngredients;

  const _BadIngredientGroups({
    required this.reasonCodes,
    required this.badIngredients,
  });

  @override
  Widget build(BuildContext context) {
    if (badIngredients.isEmpty) return const SizedBox.shrink();

    // canonical key → reason code 매핑 (카탈로그 검색).
    final byReason = <String, List<String>>{};
    for (final key in badIngredients) {
      final entry = rules.badIngredientCatalog
          .where((e) => e.canonicalKey == key)
          .cast<rules.IngredientEntry?>()
          .firstWhere((_) => true, orElse: () => null);
      if (entry == null) continue;
      byReason.putIfAbsent(entry.reasonCode, () => []).add(key);
    }
    // 표시 순서: reasonCodes 의 순서를 우선 사용.
    final orderedCodes = <String>[
      for (final code in reasonCodes)
        if (byReason.containsKey(code)) code,
      for (final code in byReason.keys)
        if (!reasonCodes.contains(code)) code,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final code in orderedCodes) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text(
              rules.reasonCodeLabel(code),
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.inkSoft,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final key in byReason[code]!)
                _Chip(
                  label: _canonicalLabel(key),
                  color: AppTheme.notOkay,
                  background: AppTheme.notOkayBg,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _GoodChipsRow extends StatelessWidget {
  final List<String> goodIngredients;
  const _GoodChipsRow({required this.goodIngredients});

  @override
  Widget build(BuildContext context) {
    if (goodIngredients.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 8, bottom: 6),
          child: Text(
            '좋은 성분',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.inkSoft,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final key in goodIngredients)
              _Chip(
                label: _canonicalLabel(key),
                color: AppTheme.okay,
                background: AppTheme.okayBg,
              ),
          ],
        ),
      ],
    );
  }
}

class _SuccessLayout extends StatelessWidget {
  final ProductLookupResult product;
  final VoidCallback onRescan;
  const _SuccessLayout({required this.product, required this.onRescan});

  @override
  Widget build(BuildContext context) {
    final verdictColor = AppTheme.colorFor(product.verdict);
    final verdictBg = AppTheme.bgColorFor(product.verdict);
    final headline = rules.computeHeadline(
      rules.VerdictResult(verdict: product.verdict),
    );
    final label = rules.verdictLabel(product.verdict);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: verdictBg,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  onPressed: onRescan,
                  icon: const Icon(Icons.close),
                  color: AppTheme.ink,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${product.brand} · ${product.size}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.inkSoft,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          product.name,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.ink,
                            letterSpacing: -0.6,
                            height: 1.15,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(product.barcode, style: _monoStyle),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.shopping_cart_outlined,
                      size: 40,
                      color: AppTheme.brand,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 18,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        color: verdictColor,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _verdictEmoji(product.verdict),
                        style: const TextStyle(fontSize: 28),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            style: TextStyle(
                              fontSize: 13,
                              color: verdictColor,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            headline,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.ink,
                              letterSpacing: -0.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '데이터 업데이트 ${_formatDate(product.sourceCheckedAt)} · 룰 ${product.ruleVersion}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppTheme.inkMute,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (product.badIngredients.isNotEmpty)
                  _BadIngredientGroups(
                    reasonCodes: product.reasonCodes,
                    badIngredients: product.badIngredients,
                  ),
                if (product.goodIngredients.isNotEmpty)
                  _GoodChipsRow(goodIngredients: product.goodIngredients),
                const SizedBox(height: 16),
                const DisclaimerCard(),
                const SizedBox(height: 16),
                _PrimaryButton(label: '다시 스캔하기', onPressed: onRescan),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NotFoundLayout extends StatelessWidget {
  final String barcode;
  final VoidCallback onRescan;
  const _NotFoundLayout({required this.barcode, required this.onRescan});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: IconButton(
              onPressed: onRescan,
              icon: const Icon(Icons.close),
              color: AppTheme.ink,
            ),
          ),
          const SizedBox(height: 24),
          const Icon(
            Icons.search_off,
            size: 72,
            color: AppTheme.brand,
          ),
          const SizedBox(height: 24),
          const Text(
            rules.notFoundMessage,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppTheme.ink,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '아직 등록되지 않은 제품이에요. 점차 늘려갈게요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.inkSoft,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          Text(barcode, textAlign: TextAlign.center, style: _monoStyle),
          const Spacer(),
          const DisclaimerCard(),
          const SizedBox(height: 16),
          _PrimaryButton(label: '다시 스캔하기', onPressed: onRescan),
        ],
      ),
    );
  }
}

class _InsufficientLayout extends StatelessWidget {
  final ProductLookupResult product;
  final VoidCallback onRescan;
  const _InsufficientLayout({required this.product, required this.onRescan});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: IconButton(
              onPressed: onRescan,
              icon: const Icon(Icons.close),
              color: AppTheme.ink,
            ),
          ),
          const SizedBox(height: 24),
          const Icon(
            Icons.info_outline,
            size: 72,
            color: AppTheme.inkMute,
          ),
          const SizedBox(height: 24),
          const Text(
            '이 제품의 원재료 정보를 확인하지 못했어요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppTheme.ink,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '라벨 정보가 일부 누락된 제품이에요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.inkSoft,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          Text(product.barcode, textAlign: TextAlign.center, style: _monoStyle),
          const Spacer(),
          const DisclaimerCard(),
          const SizedBox(height: 16),
          _PrimaryButton(label: '다시 스캔하기', onPressed: onRescan),
        ],
      ),
    );
  }
}

class _NetworkErrorLayout extends StatelessWidget {
  final VoidCallback onRetry;
  final VoidCallback onRescan;
  const _NetworkErrorLayout({required this.onRetry, required this.onRescan});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: IconButton(
              onPressed: onRescan,
              icon: const Icon(Icons.close),
              color: AppTheme.ink,
            ),
          ),
          const SizedBox(height: 24),
          const Icon(
            Icons.wifi_off,
            size: 72,
            color: AppTheme.inkMute,
          ),
          const SizedBox(height: 24),
          const Text(
            '연결을 확인해주세요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppTheme.ink,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '네트워크 상태를 점검한 뒤 다시 시도해주세요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.inkSoft,
              height: 1.5,
            ),
          ),
          const Spacer(),
          const DisclaimerCard(),
          const SizedBox(height: 16),
          _PrimaryButton(label: '다시 시도', onPressed: onRetry),
          const SizedBox(height: 8),
          _SecondaryButton(label: '다시 스캔하기', onPressed: onRescan),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _PrimaryButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppTheme.brand,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _SecondaryButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.ink,
          side: const BorderSide(color: AppTheme.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

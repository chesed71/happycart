import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:happycart_rules/happycart_rules.dart' as rules;

import '../../app/theme.dart';
import '../../core/disclaimer_card.dart';
import '../../core/verdict.dart';
import '../../data/models/product_lookup_result.dart';
import 'result_state.dart';

// ────────────────────────────────────────────────────────────────
// 결과 화면 (스펙 §6.2)
// ────────────────────────────────────────────────────────────────
class ResultPage extends StatelessWidget {
  final ResultState state;
  final VoidCallback onRescan;

  const ResultPage({required this.state, required this.onRescan, super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: switch (state) {
        SuccessResultState(:final product) =>
          _SuccessLayout(product: product, onRescan: onRescan),
        NotFoundResultState(:final barcode) =>
          _NotFoundLayout(barcode: barcode, onRescan: onRescan),
        NetworkErrorResultState(:final onRetry) =>
          _NetworkErrorLayout(onRetry: onRetry, onRescan: onRescan),
      },
    );
  }
}

// ────────────────────────────────────────────────────────────────
// Verdict 테마 (ok / stop / neutral)
// ────────────────────────────────────────────────────────────────
class _VT {
  final Color gradA, gradB, deep, main, soft;
  final String word;
  final String? sub;
  final IconData icon;
  const _VT({
    required this.gradA,
    required this.gradB,
    required this.deep,
    required this.main,
    required this.soft,
    required this.word,
    required this.icon,
    this.sub,
  });
}

_VT _vt(Verdict v) {
  switch (v) {
    case Verdict.okay:
      return const _VT(
        gradA: AppTheme.okGradA,
        gradB: AppTheme.okGradB,
        deep: AppTheme.okDeep,
        main: Color(0xFF1E9E63),
        soft: AppTheme.okSoft,
        word: '괜찮아요',
        icon: Icons.check_rounded,
      );
    case Verdict.notOkay:
      return const _VT(
        gradA: AppTheme.stopGradA,
        gradB: AppTheme.stopGradB,
        deep: AppTheme.stopDeep,
        main: AppTheme.stopMain,
        soft: AppTheme.stopSoft,
        word: '잠깐',
        icon: Icons.block_rounded,
        sub: '초가공·인공 첨가물이 발견됐어요. 성분을 확인해보세요.',
      );
  }
}

// ────────────────────────────────────────────────────────────────
// 헬퍼
// ────────────────────────────────────────────────────────────────
const TextStyle _monoStyle = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Courier', 'monospace'],
  fontSize: 11,
  color: AppTheme.inkMute,
  letterSpacing: 0.5,
);

/// canonical key → 한국어 라벨
String _canonicalLabel(String canonicalKey) {
  switch (canonicalKey) {
    // Bad
    case 'aspartame': return '아스파탐';
    case 'sucralose': return '수크랄로스';
    case 'acesulfame_k': return '아세설팜칼륨';
    case 'saccharin': return '사카린';
    case 'red_40': return '적색40호';
    case 'yellow_5': return '황색5호';
    case 'yellow_6': return '황색6호';
    case 'blue_1': return '청색1호';
    case 'red_3': return '적색3호';
    case 'hfcs': return '고과당 옥수수시럽';
    case 'soybean_oil': return '대두유';
    case 'canola_oil': return '카놀라유';
    case 'corn_oil': return '옥수수유';
    case 'sunflower_oil_refined': return '정제 해바라기씨유';
    case 'cottonseed_oil': return '면실유';
    case 'hydrogenated': return '경화유 / 트랜스지방';
    case 'bha': return 'BHA';
    case 'bht': return 'BHT';
    case 'tbhq': return 'TBHQ';
    case 'sodium_nitrite': return '아질산나트륨';
    case 'sodium_nitrate': return '질산나트륨';
    case 'carrageenan': return '카라기난';
    case 'polysorbate_80': return '폴리소르베이트 80';
    case 'datem': return 'DATEM';
    case 'mono_diglycerides': return '모노/디글리세리드';
    case 'natural_flavors_opaque': return '천연향료 (성분 비공개)';
    case 'artificial_flavors': return '인공향료';
    case 'bleached_flour': return '표백 밀가루';
    case 'enriched_flour': return '강화 밀가루';
    case 'potassium_bromate': return '브롬산칼륨';
    case 'maltodextrin': return '말토덱스트린';
    // Good
    case 'extra_virgin_olive_oil': return '엑스트라버진 올리브유';
    case 'avocado_oil': return '아보카도 오일';
    case 'coconut_oil': return '코코넛 오일';
    case 'grass_fed_butter': return '그래스페드 버터 / 기';
    case 'honey': return '꿀';
    case 'maple_syrup': return '메이플시럽';
    case 'date': return '대추야자';
    case 'sea_salt': return '천일염';
    case 'whole_grain': return '통곡물';
    case 'sprouted_grain': return '발아곡물';
    case 'kimchi': return '김치';
    case 'kefir': return '케피어';
    case 'sauerkraut': return '사우어크라우트';
    case 'kombucha': return '콤부차';
    case 'organic': return '유기농';
    case 'pasture_raised_egg': return '방목 달걀';
    case 'grass_fed_beef': return '그래스페드 소고기';
    default: return canonicalKey;
  }
}

/// reason code → 아코디언 본문 설명
String _reasonDesc(String code) {
  switch (code) {
    case 'artificial_sweetener':
      return '인공 감미료는 장기 섭취 시 장내 미생물 균형에 영향을 줄 수 있어요.';
    case 'artificial_color':
      return '합성 색소로, 어린이 과잉행동과의 연관성이 일부 연구에서 보고됐어요.';
    case 'hfcs':
      return '옥수수에서 추출한 정제 당류로, 혈당을 빠르게 올리는 초가공 성분이에요.';
    case 'seed_oil':
      return '고온 정제 처리된 식물성 유지예요. 자주 드시는 건 권하지 않아요.';
    case 'hydrogenated_oil':
      return '경화 처리 과정에서 트랜스지방이 생성될 수 있어요.';
    case 'synthetic_preservative':
      return '합성 보존제로, 일부 민감한 분들에게 과민반응이 보고됐어요.';
    case 'nitrite':
      return '가공육 발색제로, 고온 조리 시 발암 가능 물질을 형성할 수 있어요.';
    case 'carrageenan':
      return '점도를 높이는 첨가물로, 장 자극 우려가 일부 연구에서 보고됐어요.';
    case 'emulsifier_concern':
      return '일부 유화제는 장 점막에 영향을 줄 수 있다는 연구가 있어요.';
    case 'opaque_flavor':
      return '\'향료\'로만 표기돼 실제 화합물 조성이 공개되지 않았어요.';
    case 'refined_flour':
      return '표백·강화 처리된 정제 밀가루로, 가공 과정에서 영양소가 손실돼요.';
    case 'bromate':
      return '제빵 개량제로 사용되지만 발암 가능성이 우려되는 성분이에요.';
    case 'maltodextrin':
      return '전분을 분해한 정제 탄수화물로, 단맛이 적어도 혈당 지수가 높아요.';
    case 'refined_sugar':
      return '정제 설탕류로, 초가공 식품에 흔히 사용돼요.';
    default:
      return '초가공·인공 첨가물로 분류된 성분이에요.';
  }
}

// ────────────────────────────────────────────────────────────────
// Success 레이아웃
// ────────────────────────────────────────────────────────────────
class _SuccessLayout extends StatefulWidget {
  final ProductLookupResult product;
  final VoidCallback onRescan;
  const _SuccessLayout({required this.product, required this.onRescan});

  @override
  State<_SuccessLayout> createState() => _SuccessLayoutState();
}

class _SuccessLayoutState extends State<_SuccessLayout>
    with SingleTickerProviderStateMixin {
  late final AnimationController _badgeCtrl;
  late final Animation<double> _badgeScale;
  late final List<(String, String)> _badPairs; // (canonicalKey, reasonCode)
  late final List<bool> _expanded;

  @override
  void initState() {
    super.initState();
    _badgeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();
    _badgeScale = CurvedAnimation(
      parent: _badgeCtrl,
      curve: const Cubic(0.2, 0.9, 0.3, 1.4),
    );

    _badPairs = [];
    for (final key in widget.product.badIngredients) {
      final entry = rules.badIngredientCatalog
          .where((e) => e.canonicalKey == key)
          .cast<rules.IngredientEntry?>()
          .firstWhere((_) => true, orElse: () => null);
      if (entry != null) _badPairs.add((key, entry.reasonCode));
    }

    _expanded = List.generate(_badPairs.length, (i) => i == 0);
  }

  @override
  void dispose() {
    _badgeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = _vt(widget.product.verdict);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Column(
        children: [
          _buildHero(theme),
          Expanded(child: _buildBody(theme)),
          _buildFooter(context),
        ],
      ),
    );
  }

  Widget _buildHero(_VT theme) {
    final topPad = MediaQuery.viewPaddingOf(context).top;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [theme.gradA, theme.gradB],
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(0, topPad, 0, 30),
        child: Column(
          children: [
            // TopBar
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  _IconBtn(
                    icon: Icons.chevron_left_rounded,
                    onTap: widget.onRescan,
                  ),
                  const Expanded(
                    child: Text(
                      '스캔 결과',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  _IconBtn(icon: Icons.ios_share_rounded, onTap: () {}),
                ],
              ),
            ),
            // 히어로 콘텐츠
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
              child: Column(
                children: [
                  // Badge (pop 애니메이션)
                  ScaleTransition(
                    scale: _badgeScale,
                    child: Container(
                      width: 104,
                      height: 104,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.18),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.18),
                            blurRadius: 30,
                            offset: const Offset(0, 10),
                          ),
                        ],
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Icon(theme.icon, size: 52, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 18),
                  // Verdict 단어
                  Text(
                    theme.word,
                    style: const TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.8,
                      height: 1.0,
                    ),
                  ),
                  // 서브타이틀
                  if (theme.sub != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      theme.sub!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.92),
                        height: 1.45,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  // 제품 칩
                  _ProductChip(product: widget.product),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(_VT theme) {
    final product = widget.product;
    final hasBad = _badPairs.isNotEmpty;
    final hasGood = product.goodIngredients.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 신경 쓰이는 성분
          if (hasBad) ...[
            _SectionHeader(
              title: '신경 쓰이는 성분',
              count: _badPairs.length,
              hint: '탭하면 이유를 볼 수 있어요',
              countColor: theme.main,
            ),
            for (int i = 0; i < _badPairs.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              _FlagCard(
                name: _canonicalLabel(_badPairs[i].$1),
                tag: rules.reasonCodeLabel(_badPairs[i].$2),
                reason: _reasonDesc(_badPairs[i].$2),
                ruleCode: _badPairs[i].$2,
                dotBg: theme.soft,
                dotFg: theme.deep,
                isOpen: _expanded[i],
                onToggle: () =>
                    setState(() => _expanded[i] = !_expanded[i]),
              ),
            ],
          ],

          // 깨끗한 성분
          if (hasGood) ...[
            SizedBox(height: hasBad ? 22 : 4),
            _SectionHeader(
              title: '깨끗한 성분',
              count: product.goodIngredients.length,
              countColor: theme.main,
            ),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppTheme.line),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF785A28).withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  for (int i = 0; i < product.goodIngredients.length; i++)
                    _CleanRow(
                      name: _canonicalLabel(product.goodIngredients[i]),
                      isLast: i == product.goodIngredients.length - 1,
                    ),
                ],
              ),
            ),
          ],

          // 안내 배너 (괜찮아요 상태)
          if (product.verdict == Verdict.okay) ...[
            const SizedBox(height: 14),
            _NoteBanner(
              text: '신경 쓰이는 성분은 발견되지 않았어요. 초가공·인공 첨가물 회피 기준으로 괜찮아요.',
              bg: AppTheme.okSoft,
              fg: AppTheme.okDeep,
            ),
          ],

          const SizedBox(height: 22),
          const DisclaimerCard(),
          const SizedBox(height: 16),
          const Text(
            '성분 이름 기준으로 판정해요 · 영양 수치가 아니라\n초가공·인공 첨가물 회피 철학에 기반합니다',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              color: AppTheme.inkMute,
              height: 1.6,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final bottomPad = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(18, 12, 18, 14 + bottomPad),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.line)),
        color: AppTheme.bg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextButton(
            onPressed: () {},
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.inkSoft,
              minimumSize: const Size.fromHeight(44),
            ),
            child: const Text(
              '전체 성분표 보기',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
          ),
          SizedBox(
            height: 54,
            child: FilledButton(
              onPressed: widget.onRescan,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.qr_code_scanner_rounded, size: 21),
                  SizedBox(width: 9),
                  Text(
                    '다음 제품 스캔하기',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// 소형 공용 위젯
// ────────────────────────────────────────────────────────────────
class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _IconBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }
}

class _ProductChip extends StatelessWidget {
  final ProductLookupResult product;
  const _ProductChip({required this.product});

  @override
  Widget build(BuildContext context) {
    final imageUrl = product.imageUrl;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(14),
            ),
            clipBehavior: Clip.antiAlias,
            child: imageUrl != null && imageUrl.isNotEmpty
                ? Image.network(
                    imageUrl,
                    semanticLabel: product.name,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.shopping_cart_outlined,
                      size: 28,
                      color: AppTheme.brand,
                    ),
                  )
                : const Icon(
                    Icons.shopping_cart_outlined,
                    size: 28,
                    color: AppTheme.brand,
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        product.name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 1.25,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '· ${product.brand}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  product.category != null
                      ? '${product.size} · ${product.category}'
                      : product.size,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.82),
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Color countColor;
  final String? hint;

  const _SectionHeader({
    required this.title,
    required this.count,
    required this.countColor,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.17,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
            decoration: BoxDecoration(
              color: countColor,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                height: 1.5,
              ),
            ),
          ),
          if (hint != null) ...[
            const Spacer(),
            Text(
              hint!,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.inkMute,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FlagCard extends StatelessWidget {
  final String name, tag, reason, ruleCode;
  final Color dotBg, dotFg;
  final bool isOpen;
  final VoidCallback onToggle;

  const _FlagCard({
    required this.name,
    required this.tag,
    required this.reason,
    required this.ruleCode,
    required this.dotBg,
    required this.dotFg,
    required this.isOpen,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: AppTheme.line),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF785A28).withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            // 헤더 (탭 가능)
            InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: dotBg,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '!',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: dotFg,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.ink,
                          letterSpacing: -0.15,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: dotBg,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: dotFg,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    AnimatedRotation(
                      turns: isOpen ? 0.5 : 0,
                      duration: const Duration(milliseconds: 250),
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 20,
                        color: AppTheme.inkMute,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 본문 (접히는 부분)
            if (isOpen)
              Padding(
                padding: const EdgeInsets.fromLTRB(56, 0, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reason,
                      style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.55,
                        color: AppTheme.inkSoft,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Text(
                      'RULE: $ruleCode',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontFamilyFallback: ['Courier'],
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.inkMute,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CleanRow extends StatelessWidget {
  final String name;
  final bool isLast;
  const _CleanRow({required this.name, required this.isLast});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(bottom: BorderSide(color: AppTheme.line)),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(
              color: AppTheme.okSoft,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_rounded,
              size: 14,
              color: AppTheme.okDeep,
            ),
          ),
          const SizedBox(width: 11),
          Text(
            name,
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteBanner extends StatelessWidget {
  final String text;
  final Color bg, fg;
  const _NoteBanner({required this.text, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                fontWeight: FontWeight.w500,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// 비-성공 레이아웃 (NotFound / NetworkError)
// ────────────────────────────────────────────────────────────────
class _NotFoundLayout extends StatelessWidget {
  final String barcode;
  final VoidCallback onRescan;
  const _NotFoundLayout({required this.barcode, required this.onRescan});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                onPressed: onRescan,
                icon: const Icon(Icons.chevron_left_rounded),
                color: AppTheme.ink,
              ),
            ),
            const SizedBox(height: 24),
            const Icon(Icons.search_off, size: 72, color: AppTheme.brand),
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
            // 미등록 바코드는 사용자가 읽고 제보할 수 있도록 크게 표시한다.
            Text(
              barcode,
              textAlign: TextAlign.center,
              style: _monoStyle.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppTheme.inkSoft,
                letterSpacing: 1.5,
              ),
            ),
            const Spacer(),
            const DisclaimerCard(),
            const SizedBox(height: 16),
            _ScanButton(label: '다시 스캔하기', onPressed: onRescan),
          ],
        ),
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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                onPressed: onRescan,
                icon: const Icon(Icons.chevron_left_rounded),
                color: AppTheme.ink,
              ),
            ),
            const SizedBox(height: 24),
            const Icon(Icons.wifi_off, size: 72, color: AppTheme.inkMute),
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
            _ScanButton(label: '다시 시도', onPressed: onRetry),
            const SizedBox(height: 8),
            _GhostButton(label: '다시 스캔하기', onPressed: onRescan),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────
// 버튼
// ────────────────────────────────────────────────────────────────
class _ScanButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _ScanButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
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
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _GhostButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(foregroundColor: AppTheme.inkSoft),
        child: Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

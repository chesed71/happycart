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
// Verdict 테마 (ok / stop) — 라이트 톤 히어로 + 카트·손 합성 마크
// ────────────────────────────────────────────────────────────────
class _VT {
  /// 히어로 라이트 톤 배경 그라디언트.
  final Color heroA, heroB;

  /// verdict 단어 색 (deep).
  final Color word;

  /// count 배지 등 강조색.
  final Color accent;

  /// flag dot/tag 배경·글자.
  final Color soft, softFg;

  final String wordText;
  final String? sub;

  /// 합성 마크 에셋 (카트·손).
  final String cartAsset, handAsset;

  const _VT({
    required this.heroA,
    required this.heroB,
    required this.word,
    required this.accent,
    required this.soft,
    required this.softFg,
    required this.wordText,
    required this.cartAsset,
    required this.handAsset,
    this.sub,
  });
}

_VT _vt(Verdict v) {
  switch (v) {
    case Verdict.okay:
      return const _VT(
        heroA: Color(0xFFE7F6EE),
        heroB: Color(0xFFFCFBF8),
        word: Color(0xFF0A6B40),
        accent: Color(0xFF00A05B),
        soft: AppTheme.okSoft,
        softFg: Color(0xFF0A6B40),
        wordText: '괜찮아요',
        cartAsset: 'assets/verdict/cart_ok.png',
        handAsset: 'assets/verdict/hand_ok.png',
      );
    case Verdict.notOkay:
      return const _VT(
        heroA: Color(0xFFFCEAE6),
        heroB: Color(0xFFFCFBF8),
        word: AppTheme.stopDeep,
        accent: AppTheme.stopMain,
        soft: AppTheme.stopSoft,
        softFg: AppTheme.stopDeep,
        wordText: '잠깐',
        sub: '초가공·인공 첨가물이 여러 개 들어 있어요.',
        cartAsset: 'assets/verdict/cart_stop.png',
        handAsset: 'assets/verdict/hand_stop.png',
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
    final isOk = widget.product.verdict == Verdict.okay;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 라이트 톤 히어로 — status bar 아이콘은 어둡게.
      value: SystemUiOverlayStyle.dark,
      child: Column(
        children: [
          if (isOk)
            // 괜찮아요: 성분/설명 없이 합성 이미지를 화면 정중앙에.
            Expanded(child: _buildHero(theme, fullscreen: true))
          else ...[
            _buildHero(theme, fullscreen: false),
            Expanded(child: _buildBody(theme)),
          ],
          _buildFooter(context),
        ],
      ),
    );
  }

  Widget _buildHero(_VT theme, {required bool fullscreen}) {
    final topPad = MediaQuery.viewPaddingOf(context).top;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 합성 히어로 (카트 + 제품 + 손, pop 애니메이션)
        ScaleTransition(
          scale: _badgeScale,
          child: _VerdictHeroArt(
            theme: theme,
            imageUrl: widget.product.imageUrl,
            productName: widget.product.name,
            size: fullscreen ? 300 : 264,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          theme.wordText,
          style: TextStyle(
            fontSize: 42,
            fontWeight: FontWeight.w800,
            color: theme.word,
            letterSpacing: -0.84,
            height: 1.0,
          ),
        ),
        if (theme.sub != null) ...[
          const SizedBox(height: 11),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              theme.sub!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: AppTheme.inkSoft,
                height: 1.5,
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        _ProductNamePill(product: widget.product),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [theme.heroA, theme.heroB],
        ),
        borderRadius: fullscreen
            ? null
            : const BorderRadius.vertical(bottom: Radius.circular(30)),
      ),
      child: Column(
        children: [
          SizedBox(height: topPad),
          // TopBar (라이트 배경 위 어두운 아이콘)
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
                      color: AppTheme.ink,
                    ),
                  ),
                ),
                _IconBtn(icon: Icons.ios_share_rounded, onTap: () {}),
              ],
            ),
          ),
          // 히어로 콘텐츠
          if (fullscreen)
            Expanded(child: Center(child: content))
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 26),
              child: content,
            ),
        ],
      ),
    );
  }

  Widget _buildBody(_VT theme) {
    final hasBad = _badPairs.isNotEmpty;

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
              countColor: theme.accent,
            ),
            for (int i = 0; i < _badPairs.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              _FlagCard(
                name: _canonicalLabel(_badPairs[i].$1),
                tag: rules.reasonCodeLabel(_badPairs[i].$2),
                reason: _reasonDesc(_badPairs[i].$2),
                ruleCode: _badPairs[i].$2,
                dotBg: theme.soft,
                dotFg: theme.softFg,
                isOpen: _expanded[i],
                onToggle: () =>
                    setState(() => _expanded[i] = !_expanded[i]),
              ),
            ],
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
        icon: Icon(icon, color: AppTheme.ink, size: 24),
      ),
    );
  }
}

/// 히어로 합성 — 흰 원형 배지 안에 [카트(뒤) · 제품 이미지(가운데 슬롯) · 손(앞)]을
/// verdict 색 마크로 쌓는다. 제품이 바뀌어도 슬롯의 이미지만 교체된다.
class _VerdictHeroArt extends StatelessWidget {
  final _VT theme;
  final String? imageUrl;
  final String productName;
  final double size;
  const _VerdictHeroArt({
    required this.theme,
    required this.imageUrl,
    required this.productName,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    final productImg = Container(
      width: size * 0.40,
      height: size * 0.40,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: url != null && url.isNotEmpty
          ? Image.network(
              url,
              semanticLabel: productName,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _fallback(),
            )
          : _fallback(),
    );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF785A28).withValues(alpha: 0.16),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            children: [
              // 카트 (뒤, 우측 하단 — 제품에 가리지 않게)
              Positioned(
                bottom: size * 0.05,
                right: size * 0.12,
                child: Image.asset(theme.cartAsset, width: size * 0.60),
              ),
              // 제품 이미지 (원 중앙)
              Align(
                alignment: Alignment.center,
                child: productImg,
              ),
              // 손 마크 (앞, 좌상단 — 원 안으로 들어오게 우측 아래로)
              Positioned(
                top: size * 0.13,
                left: size * 0.13,
                child: Image.asset(theme.handAsset, width: size * 0.40),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fallback() => const Center(
    child: Icon(Icons.shopping_bag_outlined, size: 30, color: AppTheme.inkMute),
  );
}

/// 제품 이름 pill — "**제품명** · 브랜드".
class _ProductNamePill extends StatelessWidget {
  final ProductLookupResult product;
  const _ProductNamePill({required this.product});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          border: Border.all(color: AppTheme.line),
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF785A28).withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: product.name,
                style: const TextStyle(
                  color: AppTheme.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              TextSpan(
                text: '  ·  ${product.brand}',
                style: const TextStyle(
                  color: AppTheme.inkSoft,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13.5, height: 1.2),
        ),
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

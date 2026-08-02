import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:happycart_rules/happycart_rules.dart' as rules;

import '../../app/theme.dart';
import '../../core/disclaimer_card.dart';
import '../../core/verdict.dart';
import '../../data/models/product_lookup_result.dart';
import 'ingredient_table.dart';
import 'result_risk_tier.dart';
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
        SuccessResultState(:final product) => _SuccessLayout(
          product: product,
          onRescan: onRescan,
        ),
        NotFoundResultState(:final barcode) => _NotFoundLayout(
          barcode: barcode,
          onRescan: onRescan,
        ),
        NetworkErrorResultState(:final onRetry) => _NetworkErrorLayout(
          onRetry: onRetry,
          onRescan: onRescan,
        ),
      },
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

/// canonical key → 한국어 라벨.
/// 하드코딩 switch 은퇴 — 카탈로그 단일소스 `rules.canonicalLabel` 에 위임한다.
/// 미등록 key 는 key 원문 폴백(옛 default 동작과 동형).
String _canonicalLabel(String canonicalKey) =>
    rules.canonicalLabel(canonicalKey);

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
  late final List<rules.IngredientRiskDisplay> _riskDisplays;
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

    _riskDisplays = rules.buildRiskDisplayList(widget.product.badIngredients);
    _expanded = List.generate(_riskDisplays.length, (i) => i == 0);
  }

  @override
  void dispose() {
    _badgeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tier = widget.product.verdict == Verdict.okay
        ? RiskTier.ok
        : resolveRiskTier(_riskDisplays);
    final data = riskTierData[tier]!;
    final isOk = widget.product.verdict == Verdict.okay;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 라이트 톤 히어로 — status bar 아이콘은 어둡게.
      value: SystemUiOverlayStyle.dark,
      child: Column(
        children: [
          if (isOk)
            // 괜찮아요: 성분/설명 없이 합성 이미지를 화면 정중앙에.
            Expanded(child: _buildHero(data, tier, fullscreen: true))
          else ...[
            _buildHero(data, tier, fullscreen: false),
            Expanded(child: _buildBody(data, tier)),
          ],
          _buildFooter(context),
        ],
      ),
    );
  }

  Widget _buildHero(
    RiskTierData data,
    RiskTier tier, {
    required bool fullscreen,
  }) {
    final topPad = MediaQuery.viewPaddingOf(context).top;
    final wordText = tier == RiskTier.ok ? '괜찮아요' : '잠깐';
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 합성 히어로 (카트 + 제품 + 손, pop 애니메이션)
        ScaleTransition(
          scale: _badgeScale,
          child: _VerdictHeroArt(
            data: data,
            imageUrl: widget.product.imageUrl,
            productName: widget.product.name,
            size: fullscreen ? 300 : 264,
            // 상품 이미지는 `괜찮아요`에서만 노출한다(잠깐 단계는 마크만).
            showProduct: tier == RiskTier.ok,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          wordText,
          style: TextStyle(
            fontSize: 42,
            fontWeight: FontWeight.w800,
            color: data.word,
            letterSpacing: -0.84,
            height: 1.0,
          ),
        ),
        if (tier != RiskTier.ok) ...[
          const SizedBox(height: 10),
          RiskMeter(
            filled: data.gaugeFilled,
            label: data.gaugeLabel!.replaceFirst('위험도 ', ''),
            fillColor: data.accent,
            emptyColor: AppTheme.gaugeEmpty,
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
          colors: [data.heroTop, const Color(0xFFFCFBF8)],
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

  Widget _buildBody(RiskTierData data, RiskTier tier) {
    final hasBad = _riskDisplays.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 단계별 안내 배너 — 성분 목록보다 먼저 안내를 보고 성분을 확인하는 흐름.
          if (tier != RiskTier.ok) ...[
            RiskNoteBanner(
              text: data.bannerText!,
              bg: data.bannerBg,
              fg: data.bannerFg,
            ),
            const SizedBox(height: 16),
          ],

          // 주의 성분
          if (hasBad) ...[
            _SectionHeader(
              title: '주의 성분',
              count: _riskDisplays.length,
              hint: '탭하면 이유를 볼 수 있어요',
              countColor: data.accent,
            ),
            for (int i = 0; i < _riskDisplays.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              FlagCard(
                name: _canonicalLabel(_riskDisplays[i].canonicalKey),
                tag: rules.reasonCodeLabel(_riskDisplays[i].reasonCode),
                reason: _reasonDesc(_riskDisplays[i].reasonCode),
                dotBg: AppTheme.stopSoft,
                dotFg: AppTheme.stopDeep,
                riskLevel: _riskDisplays[i].riskLevel,
                riskReason: _riskDisplays[i].riskReason,
                riskEvidence: _riskDisplays[i].riskEvidence,
                isOpen: _expanded[i],
                onToggle: () => setState(() => _expanded[i] = !_expanded[i]),
              ),
            ],
          ],

          const SizedBox(height: 22),
          const DisclaimerCard(),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// "전체 성분표 보기" → 라벨 원문 성분을 바텀시트로 노출한다.
  void _openIngredientTable(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _IngredientTableSheet(product: widget.product),
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
            onPressed: () => _openIngredientTable(context),
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
  final RiskTierData data;
  final String? imageUrl;
  final String productName;
  final double size;

  /// 중앙 슬롯에 상품 이미지를 노출할지 여부.
  /// `okay`(괜찮아요)에서만 `true`, `잠깐`(위험) 단계에서는 상품 사진을 감추고
  /// 카트·손 마크만 보여준다.
  final bool showProduct;
  const _VerdictHeroArt({
    required this.data,
    required this.imageUrl,
    required this.productName,
    required this.size,
    required this.showProduct,
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
            children: showProduct
                ? [
                    // 괜찮아요: 카트(뒤·우하단) · 제품(중앙) · 손(앞·좌상단) 3겹.
                    Positioned(
                      bottom: size * 0.05,
                      right: size * 0.12,
                      child: Image.asset(data.cartAsset, width: size * 0.60),
                    ),
                    Align(alignment: Alignment.center, child: productImg),
                    Positioned(
                      top: size * 0.13,
                      left: size * 0.13,
                      child: Image.asset(data.handAsset, width: size * 0.40),
                    ),
                  ]
                : [
                    // 잠깐(위험): 상품 슬롯 없이 카트(하단·넓게) 위 중앙에 손(금지)
                    // 마크를 크게 얹는다. 참조 디자인 art-*-noproduct.png 구성.
                    Positioned(
                      left: size * 0.12,
                      top: size * 0.33,
                      width: size * 0.80,
                      child: Image.asset(data.cartAsset),
                    ),
                    Positioned(
                      left: size * 0.22,
                      top: size * 0.16,
                      width: size * 0.56,
                      child: Image.asset(data.handAsset),
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

/// 히어로 위험도 게이지 — 3칸 막대(앞에서부터 [filled]개는 [fillColor], 나머지는
/// [emptyColor]) + 우측 "위험도 **label**" 텍스트. 테스트에서 직접 pump 하기
/// 위해 public.
class RiskMeter extends StatelessWidget {
  final int filled;
  final String label;
  final Color fillColor;
  final Color emptyColor;

  const RiskMeter({
    required this.filled,
    required this.label,
    required this.fillColor,
    required this.emptyColor,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          // 3칸 전부 ValueKey('risk-gauge-bar') 를 공유하므로, Row 의 직속
          // 자식(다중 자식 엘리먼트)에 두면 "Duplicate keys" 단언에 걸린다 —
          // 키를 한 겹 안쪽(SizedBox 의 단일 자식)으로 옮겨 회피한다.
          SizedBox(
            width: 22,
            height: 6,
            child: Container(
              key: const ValueKey('risk-gauge-bar'),
              decoration: BoxDecoration(
                color: i < filled ? fillColor : emptyColor,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ],
        const SizedBox(width: 8),
        Text.rich(
          TextSpan(
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.inkSoft,
            ),
            children: [
              const TextSpan(text: '위험도 '),
              TextSpan(
                text: label,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppTheme.ink,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 성분 목록 위 단계별 안내 배너 — 정보 아이콘 + 문구를 [bg] 배경·[fg] 글자색의
/// 둥근 카드에 담는다. 테스트에서 직접 pump 하기 위해 public.
class RiskNoteBanner extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;

  const RiskNoteBanner({
    required this.text,
    required this.bg,
    required this.fg,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: fg,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
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

/// 전체 성분표 바텀시트 — 라벨 원문 성분을 조각별로 나열하고, 서버가 판정한
/// 주의 성분(빨강)·깨끗한(초록) 성분을 강조한다.
class _IngredientTableSheet extends StatelessWidget {
  final ProductLookupResult product;
  const _IngredientTableSheet({required this.product});

  @override
  Widget build(BuildContext context) {
    final raw = product.ingredientsRaw.trim();
    final entries = raw.isEmpty
        ? const <IngredientTableEntry>[]
        : buildIngredientTable(
            raw,
            badKeys: product.badIngredients,
            goodKeys: product.goodIngredients,
          );
    final badCount = entries
        .where((e) => e.mark == IngredientMark.bad)
        .length;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    final bottomPad = MediaQuery.viewPaddingOf(context).bottom;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: AppTheme.bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 그립 핸들
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              decoration: BoxDecoration(
                color: AppTheme.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // 헤더
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '전체 성분표',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.ink,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${product.name} · ${product.brand}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.inkSoft,
                  ),
                ),
                if (entries.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    badCount > 0
                        ? '총 ${entries.length}개 · 주의 성분 $badCount개'
                        : '총 ${entries.length}개',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.inkMute,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.line),
          // 본문 — 성분을 배지로 나열(주의 성분만 색 강조).
          Flexible(
            child: entries.isEmpty
                ? _EmptyIngredients(bottomPad: bottomPad)
                : SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(18, 14, 18, 16 + bottomPad),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final entry in entries)
                          _IngredientBadge(entry: entry),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 성분 배지 하나 — 주의 성분(bad)만 색을 다르게 주고, 나머지(중립·good)는
/// 동일한 중립 배지로 표시한다.
class _IngredientBadge extends StatelessWidget {
  final IngredientTableEntry entry;
  const _IngredientBadge({required this.entry});

  @override
  Widget build(BuildContext context) {
    final isBad = entry.mark == IngredientMark.bad;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(
        color: isBad ? AppTheme.stopSoft : AppTheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isBad
              ? AppTheme.stopMain.withValues(alpha: 0.35)
              : AppTheme.line,
        ),
      ),
      child: Text(
        entry.text,
        style: TextStyle(
          fontSize: 14,
          height: 1.2,
          fontWeight: isBad ? FontWeight.w700 : FontWeight.w500,
          color: isBad ? AppTheme.stopDeep : AppTheme.ink,
        ),
      ),
    );
  }
}

/// 성분 원문이 아직 없을 때(구 RPC 등)의 안내.
class _EmptyIngredients extends StatelessWidget {
  final double bottomPad;
  const _EmptyIngredients({required this.bottomPad});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 36, 24, 36 + bottomPad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.receipt_long_outlined,
            size: 44,
            color: AppTheme.inkMute,
          ),
          const SizedBox(height: 14),
          const Text(
            '성분 정보를 준비 중이에요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppTheme.ink,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '이 제품의 전체 성분표는 곧 제공될 예정이에요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: AppTheme.inkSoft,
              height: 1.5,
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
          if (hint != null)
            Expanded(
              child: Text(
                hint!,
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.inkMute,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 위험도(높음/보통/낮음)별 배지·컬러바 색 — not_okay 톤(`AppTheme.stop*`)과
/// 조화되는 빨강(높음)·주황(보통)·노랑(낮음) 계열 상수.
class _RiskStyle {
  final Color bar, badgeBg, badgeFg;
  final String label;
  const _RiskStyle({
    required this.bar,
    required this.badgeBg,
    required this.badgeFg,
    required this.label,
  });
}

const Map<rules.RiskLevel, _RiskStyle> _riskStyles = {
  rules.RiskLevel.high: _RiskStyle(
    bar: AppTheme.stopMain,
    badgeBg: AppTheme.stopMain,
    badgeFg: Colors.white,
    label: '높음',
  ),
  rules.RiskLevel.medium: _RiskStyle(
    bar: AppTheme.brand,
    badgeBg: AppTheme.brandSoft,
    badgeFg: AppTheme.brandStrong,
    label: '보통',
  ),
  rules.RiskLevel.low: _RiskStyle(
    bar: Color(0xFFE8B93A),
    badgeBg: Color(0xFFFCF3D9),
    badgeFg: Color(0xFF8A6A12),
    label: '낮음',
  ),
};

class FlagCard extends StatelessWidget {
  final String name, tag, reason;
  final Color dotBg, dotFg;
  final rules.RiskLevel? riskLevel;
  final String? riskReason;
  final String? riskEvidence;
  final bool isOpen;
  final VoidCallback onToggle;

  const FlagCard({
    required this.name,
    required this.tag,
    required this.reason,
    required this.dotBg,
    required this.dotFg,
    required this.riskLevel,
    required this.riskReason,
    required this.riskEvidence,
    required this.isOpen,
    required this.onToggle,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    // riskLevel 이 null 이면(버전 스큐 방어) 배지·컬러바를 렌더하지 않는다 —
    // 데이터 결함을 '낮음'으로 오표시하지 않기 위함. 카드 자체는 정상 렌더.
    final level = riskLevel;
    final riskStyle = level == null ? null : _riskStyles[level];
    // 로컬 변수로 받아야 non-null 승격이 적용된다(공개 필드는 승격 대상 아님).
    final riskReasonText = riskReason;
    final riskEvidenceText = riskEvidence;

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
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 위험도 컬러바 (좌측)
              if (riskStyle != null)
                Container(
                  key: const ValueKey('flagcard-risk-bar'),
                  width: 4,
                  color: riskStyle.bar,
                ),
              Expanded(
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
                            if (riskStyle != null) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: riskStyle.badgeBg,
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Text(
                                  riskStyle.label,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: riskStyle.badgeFg,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            // name과 tag가 같은 문자열이면(예: 카라기난) 헤더에
                            // 성분명이 중복 표시되므로 태그 배지를 숨긴다.
                            if (name != tag) ...[
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
                            ],
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
                            _BulletText(reason),
                            // 건강 근거 병기(대체 아님) — 빈/null 값은 줄 자체를 생략.
                            if (riskReasonText != null &&
                                riskReasonText.trim().isNotEmpty) ...[
                              const SizedBox(height: 10),
                              _BulletText(riskReasonText),
                            ],
                            if (riskEvidenceText != null &&
                                riskEvidenceText.trim().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                '출처: $riskEvidenceText',
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: AppTheme.inkMute,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 불릿(•) + 본문 한 항목. 불릿을 문자열에 이어 붙이지 않고 별도 위젯으로
/// 분리해, 본문이 줄바꿈돼도 둘째 줄이 불릿이 아닌 본문 시작점에 맞춰
/// 정렬되도록(hanging indent) 한다.
class _BulletText extends StatelessWidget {
  final String text;

  const _BulletText(this.text);

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontSize: 13.5,
      height: 1.55,
      color: AppTheme.inkSoft,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('•', style: style),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: style)),
      ],
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

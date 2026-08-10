/// not_okay 결과 화면의 제품 대표 위험도(RiskTier) 모델.
///
/// `okay` 판정은 호출 측에서 [RiskTier.ok] 로 직접 처리하므로 이 파일의
/// [resolveRiskTier] 는 not_okay 전용이다 — 성분별 위험도([rules.RiskLevel])
/// 중 가장 높은 값을 제품 대표 위험도로 환산한다.
library;

import 'package:flutter/material.dart';
import 'package:happycart_rules/happycart_rules.dart' as rules;

import '../../app/theme.dart';

/// 결과 화면 히어로 톤을 결정하는 대표 위험도 4단계.
enum RiskTier { ok, low, medium, high }

/// [displays] 중 `riskLevel` 이 가장 높은 값을 [RiskTier] 로 환산한다.
///
/// `high` > `medium` > `low` 순. `displays` 가 비어 있거나 `riskLevel` 이
/// 전부 `null` 이면 방어적으로 [RiskTier.medium] 을 반환한다.
///
/// [hasUnclassified] 는 서버가 보낸 성분 중 앱 카탈로그에 없어 [displays] 에서
/// 빠진(분류 불가한) 성분이 있는지를 뜻한다. 앱·서버 룰 버전이 어긋나 고위험
/// 성분이 조용히 탈락하면 남은 성분만으로 계산한 대표 위험도가 실제보다 낮게
/// 나올 수 있으므로, 분류 불가 성분이 있으면 안심 톤(low)으로는 내려가지 않게
/// 최소 [RiskTier.medium] 으로 올려 보수적으로 표시한다.
RiskTier resolveRiskTier(
  List<rules.IngredientRiskDisplay> displays, {
  bool hasUnclassified = false,
}) {
  rules.RiskLevel? highest;
  for (final display in displays) {
    final level = display.riskLevel;
    if (level == null) continue;
    // enum 선언 순서(.index)에 기대지 않고 룰 패키지의 명시적 순위 함수를
    // 재사용한다 — rank 가 작을수록 높은 위험(high=0).
    if (highest == null ||
        rules.riskSortRank(level) < rules.riskSortRank(highest)) {
      highest = level;
    }
  }

  final RiskTier tier;
  switch (highest) {
    case rules.RiskLevel.high:
      tier = RiskTier.high;
    case rules.RiskLevel.medium:
      tier = RiskTier.medium;
    case rules.RiskLevel.low:
      tier = RiskTier.low;
    case null:
      tier = RiskTier.medium;
  }

  // 분류 불가 성분이 섞여 있으면 low 로는 과소 표시하지 않는다(최소 medium).
  if (hasUnclassified && tier == RiskTier.low) {
    return RiskTier.medium;
  }
  return tier;
}

/// tier 별 색·문구·에셋 데이터.
class RiskTierData {
  /// 히어로 배경 그라디언트 상단색 (하단은 공통 Color(0xFFFCFBF8)).
  final Color heroTop;

  /// "잠깐" 등 헤드라인 글자색.
  final Color word;

  /// 카트·손 마크, 게이지 채움 등 강조색.
  final Color accent;

  /// 위험도 게이지 채움 칸수 (ok=0, low=1, medium=2, high=3).
  final int gaugeFilled;

  /// 게이지 옆 라벨. ok 는 게이지 자체를 숨기므로 `null`.
  final String? gaugeLabel;

  /// 안내 배너 문구. ok 는 배너를 표시하지 않아 `null`.
  final String? bannerText;

  final Color bannerBg;
  final Color bannerFg;

  /// 합성 마크 에셋 (카트·손).
  final String cartAsset;
  final String handAsset;

  const RiskTierData({
    required this.heroTop,
    required this.word,
    required this.accent,
    required this.gaugeFilled,
    required this.gaugeLabel,
    required this.bannerText,
    required this.bannerBg,
    required this.bannerFg,
    required this.cartAsset,
    required this.handAsset,
  });
}

/// tier → 화면 데이터.
const Map<RiskTier, RiskTierData> riskTierData = {
  RiskTier.ok: RiskTierData(
    // 기존 okay 히어로 값(초록) 그대로 재사용.
    heroTop: Color(0xFFE7F6EE),
    word: Color(0xFF0A6B40),
    accent: Color(0xFF00A05B),
    gaugeFilled: 0,
    gaugeLabel: null,
    bannerText: null,
    bannerBg: AppTheme.okSoft,
    bannerFg: AppTheme.okDeep,
    cartAsset: 'assets/verdict/cart_ok.png',
    handAsset: 'assets/verdict/hand_ok.png',
  ),
  RiskTier.low: RiskTierData(
    heroTop: AppTheme.heroBgLow,
    word: AppTheme.lowDeep,
    accent: AppTheme.lowMain,
    gaugeFilled: 1,
    gaugeLabel: '위험도 낮음',
    bannerText: '낮은 위험이에요. 대부분 안전하지만, 자주 드신다면 아래 성분만 가볍게 확인해보세요.',
    bannerBg: AppTheme.lowSoft,
    bannerFg: AppTheme.lowDeep,
    cartAsset: 'assets/verdict/cart_low.png',
    handAsset: 'assets/verdict/hand_low.png',
  ),
  RiskTier.medium: RiskTierData(
    heroTop: AppTheme.heroBgMed,
    word: AppTheme.medDeep,
    accent: AppTheme.medMain,
    gaugeFilled: 2,
    gaugeLabel: '위험도 중간',
    bannerText: '용량 의존형 위험이에요. 가끔·적당량이면 괜찮지만, 자주·많이 드시는 건 피하세요.',
    bannerBg: AppTheme.medSoft,
    bannerFg: AppTheme.medDeep,
    cartAsset: 'assets/verdict/cart_med.png',
    handAsset: 'assets/verdict/hand_med.png',
  ),
  RiskTier.high: RiskTierData(
    // 높음 단계는 기존 stop 계열을 재사용.
    heroTop: AppTheme.heroBgHigh,
    word: AppTheme.stopDeep,
    accent: AppTheme.stopMain,
    gaugeFilled: 3,
    gaugeLabel: '위험도 높음',
    bannerText: '높은 위험이에요. 안전한 섭취 구간이 없어, 되도록 피하는 걸 권해요.',
    bannerBg: AppTheme.stopSoft,
    bannerFg: AppTheme.stopDeep,
    cartAsset: 'assets/verdict/cart_stop.png',
    handAsset: 'assets/verdict/hand_stop.png',
  ),
};

import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Always-visible disclaimer banner (spec §12).
///
/// Cannot be dismissed: surfaced on every result/scan screen. HappyCart 의
/// clean-eating 평가 기준은 과학적으로 강하게 입증된 항목과 논쟁 중인 항목이
/// 함께 포함되므로, 단정적 안전 보증으로 읽히지 않도록 한다.
class DisclaimerCard extends StatelessWidget {
  const DisclaimerCard({super.key});

  static const String _text =
      "본 앱은 'clean eating' 철학을 기준으로 한 참고 정보입니다. 일부 성분 평가는 과학적으로 논쟁이 있을 수 있으며, 알레르기·질환·임신·영유아 식이는 제품 표시와 전문가 판단을 우선해주세요.";

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: AppTheme.inkSoft),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              _text,
              style: TextStyle(
                color: AppTheme.inkSoft,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

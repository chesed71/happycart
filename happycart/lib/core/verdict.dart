/// Single source of truth for the `Verdict` enum.
///
/// 룰 패키지(`happycart_rules`)가 enum 의 원본 정의를 가지고 있고, 클라이언트는
/// 그대로 re-export 한다. 함께 자주 쓰는 wire-format helper 도 같이 내보낸다.
library;

export 'package:happycart_rules/happycart_rules.dart'
    show Verdict, VerdictWire, verdictFromWire;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/verdict.dart';
import '../../data/models/data_report.dart';
import '../../data/models/product_lookup_result.dart';
import '../../data/product_repository.dart';
import 'ingredient_table.dart';

/// 성분 목록에 없는 성분을 지목했을 때 보내는 표식.
///
/// 운영자에게는 "라벨에는 있는데 우리 데이터에 빠졌다" = 해당 제품을 다시
/// 수집하라는 신호다. 별도 컬럼을 두는 대신 지목 목록의 한 항목으로 적는다.
const String kMissingIngredientMarker = '(목록에 없는 성분)';

/// 신고 접수 안내 — 1인 수동 처리라 소요 기간을 숨기지 않는다.
const String kReportAcceptedMessage = '접수됐어요. 직접 확인한 뒤 고칠게요 (며칠 걸릴 수 있어요)';

/// 데이터 오류 신고 바텀시트를 연다.
Future<void> showReportSheet(
  BuildContext context, {
  required ProductLookupResult product,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ReportSheet(product: product),
  );
}

/// 신고 사유 한 줄.
class ReasonOption {
  final ReportReason reason;
  final String label;

  /// 고른 뒤 "어느 성분인가요?" 단계로 넘어가는지.
  final bool picksIngredients;

  const ReasonOption(
    this.reason,
    this.label, {
    this.picksIngredients = false,
  });
}

/// 판정에 따라 사유 묶음이 다르다.
///
/// `괜찮아요`의 첫 사유만 유일하게 아이를 실제 위험에 노출시키는 오류라
/// 따로 떼어 맨 위에 둔다.
List<ReasonOption> reasonsFor({required bool isOkay}) => isOkay
    ? const [
        ReasonOption(ReportReason.missingRisky, '빠진 주의 성분이 있어요'),
        ReasonOption(
          ReportReason.ingredientsMismatch,
          '성분표가 제품과 달라요',
          picksIngredients: true,
        ),
        ReasonOption(ReportReason.wrongProduct, '다른 제품 정보예요'),
        ReasonOption(ReportReason.other, '그 밖에 달라요'),
      ]
    : const [
        ReasonOption(
          ReportReason.ingredientsMismatch,
          '성분표가 제품과 달라요',
          picksIngredients: true,
        ),
        ReasonOption(
          ReportReason.notRisky,
          '이 성분은 위험하지 않아요',
          picksIngredients: true,
        ),
        ReasonOption(ReportReason.wrongProduct, '다른 제품 정보예요'),
        ReasonOption(ReportReason.other, '그 밖에 달라요'),
      ];

class ReportSheet extends ConsumerStatefulWidget {
  final ProductLookupResult product;

  const ReportSheet({required this.product, super.key});

  @override
  ConsumerState<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<ReportSheet> {
  ReasonOption? _reason;

  /// 지목된 성분 — 라벨 원문 조각(entry.text) 기준.
  /// 목록에 없는 성분은 [kMissingIngredientMarker] 로 들어간다.
  final Set<String> _picked = <String>{};

  bool _pickingIngredients = false;
  bool _sending = false;
  bool _failed = false;

  late final List<IngredientTableEntry> _entries = _buildEntries();

  List<IngredientTableEntry> _buildEntries() {
    final raw = widget.product.ingredientsRaw.trim();
    if (raw.isEmpty) return const [];
    return buildIngredientTable(
      raw,
      badKeys: widget.product.badIngredients,
      goodKeys: widget.product.goodIngredients,
    );
  }

  List<ReportedIngredient> _selectedIngredients() {
    final byText = {for (final e in _entries) e.text: e};
    return [
      for (final text in _picked)
        ReportedIngredient(
          text: text,
          canonicalKey: byText[text]?.canonicalKey,
        ),
    ];
  }

  void _onReasonTap(ReasonOption option) {
    setState(() {
      _reason = option;
      _failed = false;
    });
  }

  void _onPrimaryTap() {
    final reason = _reason;
    if (reason == null) return;
    // 지목할 성분이 있을 때만 2단계로 간다 — 성분표가 비어 있으면 건너뛴다.
    if (!_pickingIngredients && reason.picksIngredients && _entries.isNotEmpty) {
      setState(() => _pickingIngredients = true);
      return;
    }
    _send();
  }

  Future<void> _send() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _sending = true;
      _failed = false;
    });

    final ok = await ref.read(productRepositoryProvider).reportDataError(
          barcode: widget.product.barcode,
          reason: _reason!.reason,
          ingredients: _selectedIngredients(),
        );

    if (!mounted) return;
    if (ok) {
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(content: Text(kReportAcceptedMessage)),
      );
      return;
    }
    setState(() {
      _sending = false;
      _failed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
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
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            decoration: BoxDecoration(
              color: AppTheme.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: _pickingIngredients ? _buildPickStep() : _buildReasonStep(),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 10, 20, 10 + bottomPad),
            child: _buildActions(),
          ),
        ],
      ),
    );
  }

  Widget _buildReasonStep() {
    final isOkay = widget.product.verdict == Verdict.okay;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '무엇이 다른가요?',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            color: AppTheme.ink,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '알려주시면 하나하나 직접 확인해요. 며칠 걸릴 수 있지만 꼭 봅니다.',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: AppTheme.inkSoft,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 14),
        for (final option in reasonsFor(isOkay: isOkay)) ...[
          _ChoiceTile(
            label: option.label,
            selected: _reason?.reason == option.reason,
            onTap: _sending ? null : () => _onReasonTap(option),
          ),
          const SizedBox(height: 9),
        ],
      ],
    );
  }

  Widget _buildPickStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: _sending
              ? null
              : () => setState(() => _pickingIngredients = false),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                const Icon(
                  Icons.chevron_left_rounded,
                  size: 20,
                  color: AppTheme.inkSoft,
                ),
                const SizedBox(width: 2),
                Flexible(
                  child: Text(
                    _reason!.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.inkSoft,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Text(
          '어느 성분이 다른가요?',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            color: AppTheme.ink,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '여러 개 고를 수 있어요. 잘 모르면 건너뛰어도 괜찮아요.',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: AppTheme.inkSoft,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in _entries)
              _PickPill(
                label: entry.text,
                selected: _picked.contains(entry.text),
                onTap: _sending ? null : () => _togglePick(entry.text),
              ),
            _PickPill(
              label: '여기 없는 성분이에요',
              selected: _picked.contains(kMissingIngredientMarker),
              dashed: true,
              onTap: _sending
                  ? null
                  : () => _togglePick(kMissingIngredientMarker),
            ),
          ],
        ),
      ],
    );
  }

  void _togglePick(String text) {
    setState(() {
      if (!_picked.remove(text)) _picked.add(text);
      _failed = false;
    });
  }

  Widget _buildActions() {
    final reason = _reason;
    final goesToPick = !_pickingIngredients &&
        (reason?.picksIngredients ?? false) &&
        _entries.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_failed) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text(
              '지금은 보낼 수 없어요. 연결을 확인하고 다시 시도해주세요.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.stopDeep,
                height: 1.45,
              ),
            ),
          ),
        ],
        SizedBox(
          height: 54,
          child: FilledButton(
            onPressed: (reason == null || _sending) ? null : _onPrimaryTap,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.brandStrong,
              foregroundColor: Colors.white,
              disabledBackgroundColor: AppTheme.gaugeEmpty,
              disabledForegroundColor: AppTheme.inkMute,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
            ),
            child: _sending
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    goesToPick
                        ? '다음'
                        : _failed
                            ? '다시 시도'
                            : '보내기',
                    // 19px w800 = WCAG 'large text'. 흰 글자 on #E85F00 은
                    // 3.46:1 이라 본문 크기로는 미달이고 이 크기에서만 통과한다.
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
          ),
        ),
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: AppTheme.inkSoft,
            minimumSize: const Size.fromHeight(48),
          ),
          child: const Text(
            '닫기',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// 사유 한 줄 — 선택되면 브랜드 테두리 + 체크.
class _ChoiceTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _ChoiceTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppTheme.surfaceAlt : AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            // 선택 테두리 #E85F00 은 배경 대비 3.34:1 — 비텍스트 3:1 을 넘는다.
            color: selected ? AppTheme.brandStrong : AppTheme.line,
            width: selected ? 2 : 1.5,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: AppTheme.ink,
                  height: 1.35,
                ),
              ),
            ),
            if (selected)
              const Icon(
                Icons.check_rounded,
                size: 20,
                color: AppTheme.brandStrong,
              ),
          ],
        ),
      ),
    );
  }
}

/// 성분 지목용 알약 — 전체 성분표의 알약과 같은 모양을 쓴다.
class _PickPill extends StatelessWidget {
  final String label;
  final bool selected;
  final bool dashed;
  final VoidCallback? onTap;

  const _PickPill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.dashed = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppTheme.surfaceAlt : AppTheme.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? AppTheme.brandStrong
                : dashed
                    ? AppTheme.inkMute
                    : AppTheme.line,
            width: selected ? 2 : 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                height: 1.2,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: dashed && !selected ? AppTheme.inkSoft : AppTheme.ink,
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 6),
              const Icon(
                Icons.check_rounded,
                size: 16,
                color: AppTheme.brandStrong,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 미등록 제품 화면의 '이 제품 등록 요청하기' 버튼.
///
/// 스캔만 해도 `log_pending_product` 로 바코드가 자동 적재되지만
/// (`scan_controller.dart`), 이건 사용자가 직접 누른 것이라 의도의 세기가
/// 다르다. `register_request` 로 따로 쌓아 운영자가 구분해서 본다.
class RegisterRequestButton extends ConsumerStatefulWidget {
  final String barcode;

  const RegisterRequestButton({required this.barcode, super.key});

  @override
  ConsumerState<RegisterRequestButton> createState() =>
      _RegisterRequestButtonState();
}

class _RegisterRequestButtonState extends ConsumerState<RegisterRequestButton> {
  bool _sending = false;
  bool _sent = false;

  Future<void> _send() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);

    final ok = await ref.read(productRepositoryProvider).reportDataError(
          barcode: widget.barcode,
          reason: ReportReason.registerRequest,
        );

    if (!mounted) return;
    setState(() {
      _sending = false;
      _sent = ok;
    });
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? '등록 요청을 보냈어요. 확인한 뒤 추가할게요 (며칠 걸릴 수 있어요)'
              : '지금은 보낼 수 없어요. 연결을 확인하고 다시 시도해주세요.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_sent) {
      return SizedBox(
        height: 52,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.check_rounded, size: 19, color: AppTheme.okDeep),
            SizedBox(width: 7),
            Text(
              '등록을 요청했어요',
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.okDeep,
              ),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      height: 52,
      child: OutlinedButton(
        onPressed: _sending ? null : _send,
        style: OutlinedButton.styleFrom(
          backgroundColor: AppTheme.surfaceAlt,
          foregroundColor: AppTheme.ink,
          // #E85F00 테두리는 배경 대비 3.34:1 — 비텍스트 3:1 을 넘는다.
          side: const BorderSide(color: AppTheme.brandStrong, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
        ),
        child: _sending
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: AppTheme.brandStrong,
                ),
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_rounded, size: 19, color: AppTheme.brandStrong),
                  SizedBox(width: 7),
                  Text(
                    '이 제품 등록 요청하기',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app/app.dart';
import '../../app/theme.dart';
import '../result/result_state.dart';
import 'scan_controller.dart';

/// 스캔 화면 (스펙 §6.1).
///
/// 풀스크린 카메라 프리뷰 위에 상단 닫기/플래시, 중앙 260x260 스캔 프레임,
/// 하단 안내 텍스트를 그린다. 권한 거부 / processing 상태는 별도 분기.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen>
    with WidgetsBindingObserver {
  late final MobileScannerController _scannerController;
  bool _torchOn = false;
  bool _permissionRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scannerController = MobileScannerController(
      formats: const [BarcodeFormat.ean13, BarcodeFormat.ean8],
      detectionSpeed: DetectionSpeed.normal,
      detectionTimeoutMs: 250,
      autoStart: false,
    );
    // 위젯이 실제로 빌드된 다음 권한 요청을 시작한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _permissionRequested) return;
      _permissionRequested = true;
      ref.read(scanControllerProvider.notifier).requestPermission();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 스펙 §7 — 백그라운드 진입 시 카메라 stop, 복귀 시 재개.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _scannerController.stop();
      ref.read(scanControllerProvider.notifier).pause();
    } else if (state == AppLifecycleState.resumed) {
      ref.read(scanControllerProvider.notifier).resume();
      final status = ref.read(scanControllerProvider).status;
      if (status == ScanStatus.scanning) {
        _scannerController.start();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (capture.barcodes.isEmpty) return;
    final code = capture.barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;

    final notifier = ref.read(scanControllerProvider.notifier);
    final ResultState? result = await notifier.processBarcode(code);
    if (result == null || !mounted) return;

    HapticFeedback.mediumImpact();
    // 카메라는 비동기로 멈춰도 되지만, context 사용 전에는 await 하지 않는다
    // — analyzer 의 use_build_context_synchronously 룰을 충족시키기 위함.
    unawaited(_scannerController.stop());
    await pushResult(context, result);
    if (!mounted) return;
    notifier.resumeScanning();
    await _scannerController.start();
  }

  Future<void> _toggleTorch() async {
    await _scannerController.toggleTorch();
    if (!mounted) return;
    setState(() {
      _torchOn = !_torchOn;
    });
  }

  Future<void> _close() async {
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('앱을 종료할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('종료'),
          ),
        ],
      ),
    );
    if (shouldExit ?? false) {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scanState = ref.watch(scanControllerProvider);

    // 권한이 부여된 직후에는 한 번만 스캐너를 start 한다.
    ref.listen<ScanState>(scanControllerProvider, (prev, next) {
      if (prev?.status != next.status &&
          next.status == ScanStatus.scanning &&
          (prev?.status == ScanStatus.idle ||
              prev?.status == ScanStatus.permissionDenied ||
              prev == null)) {
        _scannerController.start();
      }
    });

    return Scaffold(
      backgroundColor: Colors.black,
      body: switch (scanState.status) {
        ScanStatus.permissionDenied => const _PermissionDeniedView(),
        _ => _CameraView(
            scannerController: _scannerController,
            torchOn: _torchOn,
            isProcessing: scanState.status == ScanStatus.processing,
            onDetect: _onDetect,
            onToggleTorch: _toggleTorch,
            onClose: _close,
          ),
      },
    );
  }
}

class _CameraView extends StatelessWidget {
  final MobileScannerController scannerController;
  final bool torchOn;
  final bool isProcessing;
  final void Function(BarcodeCapture) onDetect;
  final VoidCallback onToggleTorch;
  final VoidCallback onClose;

  const _CameraView({
    required this.scannerController,
    required this.torchOn,
    required this.isProcessing,
    required this.onDetect,
    required this.onToggleTorch,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: scannerController,
          onDetect: onDetect,
        ),
        // 어둡게 깔리는 비네팅 (스펙: 어두운 배경).
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x99000000),
                Color(0x66000000),
                Color(0x99000000),
              ],
            ),
          ),
          child: SizedBox.expand(),
        ),
        SafeArea(
          child: Column(
            children: [
              _Header(
                torchOn: torchOn,
                onClose: onClose,
                onToggleTorch: onToggleTorch,
              ),
              const Expanded(child: _ScanFrame()),
              const _BottomGuide(),
            ],
          ),
        ),
        if (isProcessing) const _ProcessingOverlay(),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final bool torchOn;
  final VoidCallback onClose;
  final VoidCallback onToggleTorch;
  const _Header({
    required this.torchOn,
    required this.onClose,
    required this.onToggleTorch,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _GlassButton(
            icon: Icons.close,
            onPressed: onClose,
            tooltip: '닫기',
          ),
          _GlassButton(
            icon: torchOn ? Icons.flash_on : Icons.flash_off,
            onPressed: onToggleTorch,
            tooltip: '플래시 토글',
          ),
        ],
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  const _GlassButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.15),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 260,
        height: 260,
        child: Stack(
          children: [
            // 4모서리 머스타드 코너 마커.
            const _CornerMarker(top: 0, left: 0),
            const _CornerMarker(top: 0, right: 0),
            const _CornerMarker(bottom: 0, left: 0),
            const _CornerMarker(bottom: 0, right: 0),
            // 가운데 가로 스캔 라인.
            Positioned(
              left: 8,
              right: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    color: AppTheme.brand,
                    borderRadius: BorderRadius.circular(99),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.brand.withValues(alpha: 0.6),
                        blurRadius: 16,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CornerMarker extends StatelessWidget {
  final double? top;
  final double? bottom;
  final double? left;
  final double? right;
  const _CornerMarker({this.top, this.bottom, this.left, this.right});

  @override
  Widget build(BuildContext context) {
    final isTop = top != null;
    final isLeft = left != null;
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: SizedBox(
        width: 36,
        height: 36,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: isTop
                  ? const BorderSide(color: AppTheme.brand, width: 3)
                  : BorderSide.none,
              bottom: !isTop
                  ? const BorderSide(color: AppTheme.brand, width: 3)
                  : BorderSide.none,
              left: isLeft
                  ? const BorderSide(color: AppTheme.brand, width: 3)
                  : BorderSide.none,
              right: !isLeft
                  ? const BorderSide(color: AppTheme.brand, width: 3)
                  : BorderSide.none,
            ),
            borderRadius: BorderRadius.only(
              topLeft: isTop && isLeft
                  ? const Radius.circular(12)
                  : Radius.zero,
              topRight: isTop && !isLeft
                  ? const Radius.circular(12)
                  : Radius.zero,
              bottomLeft: !isTop && isLeft
                  ? const Radius.circular(12)
                  : Radius.zero,
              bottomRight: !isTop && !isLeft
                  ? const Radius.circular(12)
                  : Radius.zero,
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomGuide extends StatelessWidget {
  const _BottomGuide();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 24, 20, 32),
      child: Column(
        children: [
          Text(
            '바코드를 비춰주세요',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
          SizedBox(height: 6),
          Text(
            '제품 뒷면의 바코드 또는 영양성분표',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProcessingOverlay extends StatelessWidget {
  const _ProcessingOverlay();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0x99000000),
      child: Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
        ),
      ),
    );
  }
}

class _PermissionDeniedView extends StatelessWidget {
  const _PermissionDeniedView();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Spacer(),
            const Icon(
              Icons.no_photography,
              size: 72,
              color: Colors.white70,
            ),
            const SizedBox(height: 24),
            const Text(
              '카메라 권한이 필요해요',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '제품 바코드를 스캔하려면 카메라 권한을 허용해 주세요.\n설정에서 권한을 켤 수 있어요.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const Spacer(),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: () => openAppSettings(),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  '설정 열기',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

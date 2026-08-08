import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
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
  // 앱 lifecycle 이 활성(resumed)인지. 카메라 목표 상태 계산에 쓴다.
  bool _appResumed = true;
  // 카메라가 켜져 있어야 하는지에 대한 목표 상태. 마지막 이벤트 값이 아니라
  // (_appResumed && status==scanning) 결합 조건으로 _syncCamera 가 도출한다.
  bool _cameraShouldRun = false;
  // start/stop/dispose 를 직렬화하기 위한 작업 체인. lifecycle·권한 승인·결과
  // 화면 복귀가 겹쳐도 컨트롤러 작업이 순차적으로 실행되도록 보장한다.
  Future<void> _cameraOp = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // lifecycle 초기값을 실제 상태에서 가져온다(화면이 비활성 중 생성되는 경우
    // 대비). 아직 값이 없으면(null, 콜드 스타트) 활성으로 간주한다.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appResumed = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _scannerController = MobileScannerController(
      formats: const [BarcodeFormat.ean13, BarcodeFormat.ean8],
      detectionSpeed: DetectionSpeed.normal,
      detectionTimeoutMs: 250,
      autoStart: false,
    );
    // 위젯이 실제로 빌드된 다음 권한 요청을 시작한다. 권한 요청은 플랫폼 채널
    // 호출이라 실패할 수 있어 non-fatal 로 기록한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _permissionRequested) return;
      _permissionRequested = true;
      unawaited(
        ref
            .read(scanControllerProvider.notifier)
            .requestPermission()
            .catchError(_recordScannerError),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 스펙 §7 — 백그라운드 진입 시 카메라 stop, 복귀 시 재개.
    // resumed 만 활성으로 보고 나머지(inactive/paused/hidden/detached)는 비활성.
    _appResumed = state == AppLifecycleState.resumed;
    final notifier = ref.read(scanControllerProvider.notifier);
    if (_appResumed) {
      // 캐시된 권한값으로 낙관적 복원을 하지 않고, 실제 권한을 재조회해 상태를
      // 결정한다(설정에서 철회됐는데 조회까지 실패하면 권한 없이 카메라가 켜지는
      // stale scanning 을 방지). status 가 바뀌면 ref.listen 이 _syncCamera 를
      // 다시 호출한다. 조회는 플랫폼 채널 호출이라 실패할 수 있어 non-fatal 기록.
      unawaited(notifier.refreshPermission().catchError(_recordScannerError));
    } else {
      notifier.pause();
    }
    _syncCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraShouldRun = false;
    // dispose 를 체인 밖에서 즉시 호출하면 native start 가 진행 중일 때 stop 이
    // 생략돼 카메라 리소스가 샐 수 있다. 진행 중 start/stop 이 끝난 뒤 정지하고
    // dispose 하도록 체인 끝에 예약한다. dispose() 는 Future<void> 이고 내부
    // native stop 이 throw 할 수 있어 catchError 로 흡수한다(_recordScannerError
    // 는 State 를 참조하지 않아 dispose 이후에도 안전).
    final controller = _scannerController;
    _cameraOp = _cameraOp.then<void>((_) async {
      // stop 이 실패해도 dispose 는 반드시 호출돼야 컨트롤러가 누수되지 않는다.
      try {
        if (controller.value.isRunning) {
          await controller.stop();
        }
      } catch (error, stack) {
        _recordScannerError(error, stack);
      }
      await controller.dispose();
    }).catchError(_recordScannerError);
    super.dispose();
  }

  /// 스캐너 컨트롤러 호출에서 나는 생명주기 예외(이미 시작 중 / dispose 이후 /
  /// 위젯 미부착 등)와 네이티브 카메라 예외는 앱을 죽이면 안 된다. 삼켜서
  /// 비치명적(non-fatal)으로만 기록한다. (web 은 Crashlytics 미지원 — main.dart 참고)
  void _recordScannerError(Object error, StackTrace stack) {
    if (!kIsWeb) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: false);
    }
  }

  /// 현재 lifecycle·스캔 상태로부터 카메라 목표 상태를 도출해 반영한다.
  /// 마지막 이벤트 값이 아니라 (_appResumed && status==scanning &&
  /// permissionGranted) 결합 조건으로 계산한다. permissionGranted 를 함께 봐서,
  /// 재조회가 끝나기 전 resumeScanning 이 status 를 scanning 으로 만든 경쟁
  /// 상황에서도 권한이 확인되지 않았으면 카메라를 켜지 않는다.
  /// 계산된 목표를 _cameraOp 체인에 직렬화해 stop↔start 가 겹치지 않게 한다.
  void _syncCamera() {
    final scanState = ref.read(scanControllerProvider);
    final scanning = scanState.status == ScanStatus.scanning &&
        scanState.permissionGranted;
    _cameraShouldRun = mounted && _appResumed && scanning;
    // 앞 작업이 실패로 끝나도 체인이 rejected 로 굳어 이후 작업이 전부 스킵되지
    // 않도록, 체인 끝에 catchError 안전망을 둬 다음 작업이 계속 실행되게 한다.
    _cameraOp = _cameraOp
        .then((_) => _reconcileCamera())
        .catchError(_recordScannerError);
  }

  /// 목표 상태(_cameraShouldRun)와 컨트롤러 실제 상태가 어긋나면 한 단계 맞춘다.
  /// _syncCamera 를 통해 직렬화되어 호출되므로 앞선 start/stop 이 완료된 뒤
  /// 실행된다 — 진행 중 작업이 끝난 최신 상태를 보고 재조정한다.
  Future<void> _reconcileCamera() async {
    if (!mounted) return; // dispose 이후 큐에 남은 작업은 건너뛴다.
    try {
      final value = _scannerController.value;
      if (_cameraShouldRun) {
        if (!value.isRunning && !value.isStarting) {
          await _scannerController.start();
          // start() 는 native 초기화 실패를 throw 하지 않고 value.error 에
          // 저장한 뒤 정상 반환할 수 있다(패키지 구현). 성공 시 copyWith 가
          // error 를 null 로 지우므로, 실패(!isRunning && error!=null)일 때만
          // 비치명적으로 기록해 관측 가능하게 한다.
          final started = _scannerController.value;
          if (!started.isRunning && started.error != null) {
            _recordScannerError(started.error!, StackTrace.current);
          }
        }
      } else if (value.isRunning) {
        await _scannerController.stop();
      }
    } on MobileScannerException catch (error, stack) {
      _recordScannerError(error, stack);
    } on PlatformException catch (error, stack) {
      _recordScannerError(error, stack);
    } on UnsupportedError catch (error, stack) {
      // web 등 미지원 플랫폼에서 start/stop 이 UnsupportedError 를 던질 수 있다.
      _recordScannerError(error, stack);
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (capture.barcodes.isEmpty) return;
    final code = capture.barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;

    final notifier = ref.read(scanControllerProvider.notifier);
    final ResultState? result = await notifier.processBarcode(code);
    if (result == null || !mounted) return;

    HapticFeedback.mediumImpact();
    // processBarcode 로 status 가 processing 이 됐으므로 _syncCamera 는 카메라를
    // 멈춘다. _syncCamera 는 동기 호출(작업은 체인에 예약)이라 context 사용 전
    // await 하지 않아 use_build_context_synchronously 룰도 충족한다.
    _syncCamera();
    await pushResult(context, result);
    if (!mounted) return;
    notifier.resumeScanning(); // status 를 다시 scanning 으로 → 카메라 재개
    _syncCamera();
  }

  Future<void> _toggleTorch() async {
    try {
      await _scannerController.toggleTorch();
    } on MobileScannerException catch (error, stack) {
      _recordScannerError(error, stack);
      return;
    } on PlatformException catch (error, stack) {
      _recordScannerError(error, stack);
      return;
    } on UnsupportedError catch (error, stack) {
      // web 의 toggleTorch() 는 UnsupportedError 를 던진다(플래시 미지원).
      _recordScannerError(error, stack);
      return;
    }
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

    // status 또는 permissionGranted 가 바뀔 때마다 카메라 목표 상태를 재도출한다
    // (권한 승인 직후 scanning 전이, 재조회 실패로 권한이 내려가는 경우 포함).
    // 목표 계산·직렬화는 _syncCamera 가 담당한다.
    ref.listen<ScanState>(scanControllerProvider, (prev, next) {
      if (prev?.status != next.status ||
          prev?.permissionGranted != next.permissionGranted) {
        _syncCamera();
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

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'ui/chat_screen.dart';
import 'services/model_download_service.dart';
import 'services/inference_service.dart';
import 'services/tts_service.dart';
import 'services/photo_service.dart';
import 'services/wakeup_service.dart';
import 'services/bluetooth_spp_service.dart';
import 'services/bluetooth_receiver.dart';
import 'services/builtin_camera_source.dart';
import 'services/camera_source_manager.dart';
import 'services/hardware_vision_service.dart';
import 'services/uvc_camera_service.dart';
import 'services/uvc_camera_source.dart';
import 'services/warning_center.dart';
import 'services/vision_warning_service.dart';
import 'services/android_tts.dart';
import 'services/fusion_warning_service.dart';
import 'services/guide_state_service.dart';
import 'services/voice_announcer.dart';
import 'ui/guide/onboarding_screen.dart';
import 'ui/guide/guide_widgets.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ModelDownloadService()),
        ChangeNotifierProvider(create: (_) => InferenceService()),
        Provider(create: (_) => TtsService()),
        Provider(create: (_) => PhotoService()),
        ChangeNotifierProvider(create: (_) => VoiceService()),
        ChangeNotifierProvider(create: (_) => BluetoothSppService()),
        ChangeNotifierProvider(create: (_) => HardwareVisionService()),
        ChangeNotifierProvider(create: (_) => UvcCameraService()),
        ChangeNotifierProvider(create: (_) => WarningCenter()),
        // 语音播报模块驱动：Android 原生 TextToSpeech
        Provider(create: (_) => AndroidTts()),
        ChangeNotifierProvider(
          create: (context) =>
              VoiceAnnouncer(engine: context.read<AndroidTts>()),
        ),
        ChangeNotifierProvider(
          create: (context) => BluetoothReceiver(
            bluetoothSpp: context.read<BluetoothSppService>(),
            warningCenter: context.read<WarningCenter>(),
            ttsService: context.read<TtsService>(),
          )..start(),
        ),
        ChangeNotifierProvider(
          create: (context) => VisionWarningService(
            warningCenter: context.read<WarningCenter>(),
            ttsService: context.read<TtsService>(),
          )..start(),
        ),
        // 摄像头取帧模块：导盲杖场景优先 UVC，手机优先内置；异常自动降级
        ChangeNotifierProvider(
          create: (context) => CameraSourceManager(
            builtin: BuiltinCameraSource(context.read<VisionWarningService>()),
            uvc: UvcCameraSource(
              frameHub: context.read<VisionWarningService>(),
              uvcState: context.read<UvcCameraService>(),
            ),
          ),
        ),
        ChangeNotifierProvider(
          create: (context) => FusionWarningService(
            radar: context.read<BluetoothReceiver>(),
            vision: context.read<VisionWarningService>(),
            broadcaster: context.read<VoiceAnnouncer>(),
            ttsService: context.read<TtsService>(),
          ),
        ),
        // 首启引导状态：只记录/查询权限，不触达 YOLO 与摄像头
        ChangeNotifierProvider(create: (_) => GuideStateService()),
      ],
      child: WarningSync(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'zhidao_glass',
          theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
          home: HomeGate(
            child: const ChatScreen(),
          ),
        ),
      ),
    );
  }
}

/// 首启门控：首次启动展示全屏引导，完成后进入主界面。
///
/// 仅做一次 shared_preferences 读取，不初始化任何重资源。
class HomeGate extends StatefulWidget {
  const HomeGate({super.key, required this.child});

  final Widget child;

  @override
  State<HomeGate> createState() => _HomeGateState();
}

class _HomeGateState extends State<HomeGate> {
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    context.read<GuideStateService>().ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<GuideStateService>(
      builder: (context, guide, _) {
        if (!guide.isReady) {
          return const Scaffold(
            backgroundColor: kGuideBackground,
            body: Center(
              child: CircularProgressIndicator(color: kGuidePrimary),
            ),
          );
        }
        if (!guide.firstRunCompleted) {
          return const OnboardingScreen();
        }
        return widget.child;
      },
    );
  }
}

/// 将各硬件服务的实时状态同步到 WarningCenter，
/// 互不解除，只各自独立反映自己来源的报警状态。
class WarningSync extends StatefulWidget {
  const WarningSync({super.key, required this.child});

  final Widget child;

  @override
  State<WarningSync> createState() => _WarningSyncState();
}

class _WarningSyncState extends State<WarningSync> {
  HardwareVisionService? _vision;
  UvcCameraService? _uvc;
  VoidCallback? _onVision;
  VoidCallback? _onUvc;
  bool _wired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_wired) return;
    _wired = true;

    final center = context.read<WarningCenter>();
    final vision = context.read<HardwareVisionService>();
    final uvc = context.read<UvcCameraService>();

    _vision = vision;
    _uvc = uvc;

    void syncVision() => center.setCameraObstacle(
          vision.guidance.action == VisionAction.stop,
        );
    void syncUvc() => center.setUsbCameraFault(uvc.hasFrameStallFault);

    _onVision = syncVision;
    _onUvc = syncUvc;

    vision.addListener(syncVision);
    uvc.addListener(syncUvc);

    // 立即同步一次当前实时状态
    syncVision();
    syncUvc();
  }

  @override
  void dispose() {
    _vision?.removeListener(_onVision!);
    _uvc?.removeListener(_onUvc!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

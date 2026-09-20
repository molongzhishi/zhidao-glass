import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import 'camera_source.dart';
import 'coco_labels_zh.dart';
import 'detection_pipeline.dart';
import 'hardware_vision_service.dart';
import 'tts_service.dart';
import 'vision_alert_engine.dart';
import 'warning_center.dart';

/// 视觉识别通道
///
/// 按节奏截取画面帧 → [DetectionPipeline] 检测（过滤障碍物类别）→ 按面积占比排序
/// → 分级 → 语音播报。
///
/// - 未处于预警状态：每 [idleInterval]（默认 2 秒）截取一次；
/// - 预警状态中（[WarningCenter.hasActiveWarnings]）：每 [warningInterval]（默认 1 秒）截取一次；
/// - 只报告权重最大的物品，格式"前方有[物品名]"；
/// - 同一物品持续存在时每 [VisionAlertEngine.repeatInterval]（默认 2 秒）重复报告。
///
/// 检测结果通过 [onReport] 回调交给上层（融合服务）统一裁减；
/// 未设置 [onReport] 时回退到 [TtsService] 直接播报，保证独立可用。
///
/// 画面帧来源（二者取其一，优先内置摄像头）：
/// - 内置摄像头：由视觉页注册 [YOLOViewController]，本服务调用 captureFrame() 抓帧；
/// - USB 摄像头（UVC）：由 UVC 视觉页通过 [submitFrame] 持续喂入 JPEG 帧。
class VisionWarningService extends ChangeNotifier implements CameraFrameHub {
  VisionWarningService({
    required WarningCenter warningCenter,
    TtsService? ttsService,
    this.onReport,
    this.idleInterval = const Duration(seconds: 2),
    this.warningInterval = const Duration(seconds: 1),
    this.confidenceThreshold = HardwareVisionService.confidenceThreshold,
    this.frameMaxAge = const Duration(seconds: 5),
    DetectionPipeline? pipeline,
  })  : _center = warningCenter,
        _tts = ttsService,
        _pipeline = pipeline ?? DetectionPipeline(),
        _engine = VisionAlertEngine(labelResolver: CocoLabelsZh.resolve);

  final WarningCenter _center;
  final TtsService? _tts;
  final DetectionPipeline _pipeline;

  /// 报告回调。设置后本服务不再直接调用 TTS，交由上层融合服务播报。
  void Function(VisionReport report)? onReport;
  final VisionAlertEngine _engine;

  final Duration idleInterval;
  final Duration warningInterval;
  final double confidenceThreshold;

  /// 推送帧的最大可用时长，超过则认为画面已过期、跳过本次推理
  final Duration frameMaxAge;

  YOLOViewController? _internalController;
  Uint8List? _latestFrame;
  DateTime? _latestFrameAt;

  Timer? _timer;
  bool _running = false;
  bool _busy = false;
  bool _disposed = false;

  VisionReport? _lastReport;
  List<VisionObservation> _lastObservations = const [];
  int _tickCount = 0;

  bool get isRunning => _running;
  bool get isModelReady => _pipeline.isModelReady;
  VisionReport? get lastReport => _lastReport;
  List<VisionObservation> get lastObservations => _lastObservations;

  /// 当前应采用的截屏间隔
  Duration get currentInterval =>
      _center.hasActiveWarnings ? warningInterval : idleInterval;

  /// 启动视觉预警通道（幂等）
  void start() {
    if (_running) return;
    _running = true;
    _engine.reset();
    _scheduleNext(immediate: true);
    notifyListeners();
  }

  void stop() {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    notifyListeners();
  }

  /// USB 摄像头视觉页持续喂入最新帧
  void submitFrame(Uint8List frame) {
    if (frame.isEmpty) return;
    _latestFrame = frame;
    _latestFrameAt = DateTime.now();
  }

  @override
  bool get hasInternalCamera => _internalController?.isInitialized ?? false;

  @override
  Uint8List? get lastUvcFrame => _latestFrame;

  @override
  DateTime? get lastUvcFrameAt => _latestFrameAt;

  /// 内置摄像头控制器是否已注册且初始化
  @override
  Future<Uint8List?> grabBuiltInFrame() async {
    final controller = _internalController;
    if (controller == null || !controller.isInitialized) return null;
    try {
      final bytes = await controller.captureFrame();
      if (bytes == null || bytes.isEmpty) return null;
      return bytes;
    } catch (e) {
      debugPrint('[VisionWarning] 内置摄像头抓帧失败: $e');
      return null;
    }
  }

  /// 内置摄像头视觉页注册控制器，供本服务抓帧
  void attachInternalCamera(YOLOViewController controller) {
    _internalController = controller;
  }

  void detachInternalCamera() {
    _internalController = null;
  }

  void _scheduleNext({bool immediate = false}) {
    if (!_running) return;
    _timer?.cancel();
    _timer = Timer(immediate ? Duration.zero : currentInterval, _tick);
  }

  Future<void> _tick() async {
    if (!_running) return;
    if (_busy) {
      _scheduleNext();
      return;
    }
    _busy = true;
    try {
      final frame = await _grabFrame();
      if (frame == null || frame.isEmpty) return;

      final result = await _pipeline.analyze(
        frame,
        confidenceThreshold: confidenceThreshold,
      );

      final observations = result.detections
          .map(
            (d) => VisionObservation(
              className: d.className,
              weight: d.areaRatio,
              centerX: d.centerX,
              centerY: d.centerY,
            ),
          )
          .toList();

      final report = _engine.evaluate(observations);
      _lastObservations = observations;
      _lastReport = report;
      _tickCount++;

      if (report.shouldBroadcast && report.text != null) {
        debugPrint(
          '[VisionWarning] ${report.level.name} 播报: ${report.text} '
          '(权重 ${(report.weight * 100).toStringAsFixed(1)}%)',
        );
        _emitReport(report);
      }

      if (!_disposed && (report.shouldBroadcast || _tickCount % 5 == 0)) {
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[VisionWarning] 推理失败: $e');
    } finally {
      _busy = false;
      _scheduleNext();
    }
  }

  void _emitReport(VisionReport report) {
    final sink = onReport;
    if (sink != null) {
      sink(report);
      return;
    }
    final tts = _tts;
    if (tts != null) {
      unawaited(tts.speak(report.text!));
    }
  }

  Future<Uint8List?> _grabFrame() async {
    final bytes = await grabBuiltInFrame();
    if (bytes != null) return bytes;

    final frame = _latestFrame;
    final at = _latestFrameAt;
    if (frame == null || at == null) return null;
    if (DateTime.now().difference(at) > frameMaxAge) return null;
    return frame;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _running = false;
    unawaited(_pipeline.dispose());
    super.dispose();
  }
}

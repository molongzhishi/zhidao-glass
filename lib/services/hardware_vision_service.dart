import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

enum VisionAction { forward, slowDown, turnLeft, turnRight, stop }

class VisionDetection {
  const VisionDetection({
    required this.className,
    required this.confidence,
    required this.normalizedBox,
  });

  final String className;
  final double confidence;
  final Rect normalizedBox;

  double get area => normalizedBox.width * normalizedBox.height;
  double get centerX => normalizedBox.center.dx;
  double get centerY => normalizedBox.center.dy;
}

class VisionGuidance {
  const VisionGuidance({
    required this.action,
    required this.command,
    required this.message,
    this.target,
  });

  final VisionAction action;
  final String command;
  final String message;
  final VisionDetection? target;
}

/// 视觉服务核心（单视觉模型方案）
///
/// 只有一个 YOLO26 通用检测模型（yolo26n_w8a32.tflite），由 ultralytics_yolo
/// 插件的 YOLOView / YOLO 负责采集与推理，本服务只负责：
///  - 过滤置信度、按面积排序整理检测结果；
///  - 生成离线的视觉引导（障碍物避让建议）供 UI 与 WarningSync 报警联动。
class HardwareVisionService extends ChangeNotifier {
  /// 通用检测模型（随 APK 打包，COCO 80类）
  static const String generalModelAsset = 'assets/models/yolo26n_w8a32.tflite';
  static const double confidenceThreshold = 0.35;

  /// UI 通知节流间隔——UVC 视频流逐帧推理时过高频率会导致大量无意义的
  /// widget 重建，100ms 内最多通知一次。
  static const Duration _notifyThrottleInterval = Duration(milliseconds: 100);
  DateTime? _lastNotifyTime;

  bool _isRunning = false;
  bool _isModelLoaded = false;
  String? _errorMessage;
  List<VisionDetection> _detections = const [];
  VisionGuidance _guidance = const VisionGuidance(
    action: VisionAction.forward,
    command: 'VISION_FORWARD',
    message: '等待视觉检测结果',
  );

  bool get isRunning => _isRunning;
  bool get isModelLoaded => _isModelLoaded;
  String? get errorMessage => _errorMessage;
  List<VisionDetection> get detections => _detections;
  VisionGuidance get guidance => _guidance;

  /// 节流版 notifyListeners：100ms 内最多触发一次，避免逐帧高频更新导致 UI 抖动。
  /// 状态变更（start/stop/error）绕过节流直接通知。
  @override
  void notifyListeners() {
    final now = DateTime.now();
    final last = _lastNotifyTime;
    if (last != null && now.difference(last) < _notifyThrottleInterval) {
      return; // 节流：跳过本次通知
    }
    _lastNotifyTime = now;
    super.notifyListeners();
  }

  /// 立即通知（绕过节流），用于状态突变场景
  void _notifyImmediate() {
    _lastNotifyTime = null;
    super.notifyListeners();
  }

  void start() {
    _isRunning = true;
    _errorMessage = null;
    _notifyImmediate();
  }

  void markModelLoaded() {
    _isModelLoaded = true;
    _errorMessage = null;
    _notifyImmediate();
  }

  void markModelError(Object error) {
    _isModelLoaded = false;
    _errorMessage = error.toString();
    _notifyImmediate();
  }

  /// 接收 YOLO 检测结果（YOLOView 的 onResult / YOLO.predict 返回）
  /// 过滤置信度并按面积排序，随后生成视觉引导。
  void updateDetections(List<YOLOResult> results) {
    _detections = results
        .where((r) => r.confidence >= confidenceThreshold)
        .map((r) => VisionDetection(
              className: r.className,
              confidence: r.confidence,
              normalizedBox: r.normalizedBox,
            ))
        .toList()
      ..sort((a, b) => b.area.compareTo(a.area));
    _guidance = _buildGuidance(_detections);
    notifyListeners();
  }

  VisionGuidance _buildGuidance(List<VisionDetection> detections) {
    if (detections.isEmpty) {
      return const VisionGuidance(
        action: VisionAction.forward,
        command: 'VISION_FORWARD',
        message: '前方未检测到障碍，可继续前进',
      );
    }

    final target = detections.first;
    if (target.area >= 0.28) {
      return VisionGuidance(
        action: VisionAction.stop,
        command: 'VISION_STOP',
        message: '${target.className}距离过近，建议停止',
        target: target,
      );
    }
    if (target.area >= 0.06 && target.centerX < 0.38) {
      return VisionGuidance(
        action: VisionAction.turnRight,
        command: 'VISION_RIGHT',
        message: '${target.className}位于左侧，建议向右避让',
        target: target,
      );
    }
    if (target.area >= 0.06 && target.centerX > 0.62) {
      return VisionGuidance(
        action: VisionAction.turnLeft,
        command: 'VISION_LEFT',
        message: '${target.className}位于右侧，建议向左避让',
        target: target,
      );
    }
    if (target.area >= 0.12) {
      return VisionGuidance(
        action: VisionAction.slowDown,
        command: 'VISION_SLOW',
        message: '前方检测到${target.className}，建议减速',
        target: target,
      );
    }

    return VisionGuidance(
      action: VisionAction.forward,
      command: 'VISION_FORWARD',
      message: '检测到${target.className}，当前可继续前进',
      target: target,
    );
  }

  void stop() {
    _isRunning = false;
    _isModelLoaded = false;
    _detections = const [];
    _guidance = const VisionGuidance(
      action: VisionAction.forward,
      command: 'VISION_FORWARD',
      message: '视觉模块已停止',
    );
    _notifyImmediate();
  }
}
import 'package:flutter/foundation.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import 'camera_source_manager.dart';
import 'detection.dart';
import 'hardware_vision_service.dart';

/// 统一检测管线：取帧 → YOLO 推理 → 障碍物过滤 → 坐标/面积计算 → 面积排序取最大目标。
///
/// - 负责 YOLO 模型的生命周期（按需加载、复用、释放）；
/// - [analyzeFrame] 可直接从 [CameraSourceManager] 取当前画面源的一帧；
/// - 纯几何/过滤逻辑在 [DetectionResult.fromYoloResults]，可独立单测。
class DetectionPipeline {
  DetectionPipeline({
    this.modelPath = HardwareVisionService.generalModelAsset,
  });

  final String modelPath;

  YOLO? _yolo;
  bool _loading = false;

  bool get isModelReady => _yolo != null;

  /// 对单帧 JPEG/原始字节做检测，返回按面积排序的障碍物检测结果。
  Future<DetectionResult> analyze(
    Uint8List frame, {
    double confidenceThreshold = HardwareVisionService.confidenceThreshold,
    bool obstaclesOnly = true,
  }) async {
    if (frame.isEmpty) return const DetectionResult(detections: []);
    await _ensureYolo();
    final yolo = _yolo;
    if (yolo == null) return const DetectionResult(detections: []);

    try {
      final map = await yolo.predict(
        frame,
        confidenceThreshold: confidenceThreshold,
      );
      final results = (map['detections'] as List?)
              ?.whereType<Map>()
              .map(YOLOResult.fromMap)
              .toList() ??
          const <YOLOResult>[];
      return DetectionResult.fromYoloResults(
        results,
        confidenceThreshold: confidenceThreshold,
        obstaclesOnly: obstaclesOnly,
      );
    } catch (e) {
      debugPrint('[DetectionPipeline] 推理失败: $e');
      return const DetectionResult(detections: []);
    }
  }

  /// 从 [CameraSourceManager] 取一帧（当前场景源/降级源）后执行检测。
  Future<DetectionResult> analyzeFrame(
    CameraSourceManager camera, {
    double confidenceThreshold = HardwareVisionService.confidenceThreshold,
    bool obstaclesOnly = true,
  }) async {
    final frame = await camera.getFrame();
    if (frame == null) return const DetectionResult(detections: []);
    return analyze(
      frame.bytes,
      confidenceThreshold: confidenceThreshold,
      obstaclesOnly: obstaclesOnly,
    );
  }

  Future<void> _ensureYolo() async {
    if (_yolo != null || _loading) return;
    _loading = true;
    try {
      final yolo = YOLO(
        modelPath: modelPath,
        task: YOLOTask.detect,
        useGpu: true,
        useMultiInstance: true,
      );
      final loaded = await yolo.loadModel();
      if (loaded) {
        _yolo = yolo;
        debugPrint('[DetectionPipeline] YOLO 模型加载完成');
      } else {
        debugPrint('[DetectionPipeline] YOLO 模型加载返回 false');
      }
    } catch (e) {
      debugPrint('[DetectionPipeline] YOLO 模型加载失败: $e');
    } finally {
      _loading = false;
    }
  }

  Future<void> dispose() async {
    await _yolo?.dispose();
    _yolo = null;
    _loading = false;
  }
}
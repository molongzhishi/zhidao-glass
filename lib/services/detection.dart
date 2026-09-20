import 'dart:ui';

import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import 'hardware_vision_service.dart';

/// COCO 障碍物类别白名单。
///
/// 导盲场景下只把「会阻挡行进路线/需要绕行」的地面常见物体视为障碍物，
/// 过滤掉空中、墙上、桌面等不构成步行阻碍的类别（鸟、飞机、电视、书本等）。
/// 类别名按小写比较（与 `ultralytics_yolo` 输出保持一致）。
class ObstacleClasses {
  const ObstacleClasses._();

  static const Set<String> names = {
    // 人与车
    'person',
    'bicycle',
    'car',
    'motorcycle',
    'bus',
    'train',
    'truck',
    'boat',
    // 街边设施（立柱/长椅等）
    'fire hydrant',
    'stop sign',
    'parking meter',
    'bench',
    // 随身/地面小件
    'backpack',
    'umbrella',
    'handbag',
    'suitcase',
    'sports ball',
    'skis',
    'snowboard',
    'skateboard',
    'bottle',
    'cup',
    'bowl',
    // 室内家具
    'chair',
    'couch',
    'dining table',
    'potted plant',
    // 动物
    'dog',
    'cat',
    'horse',
  };

  static bool contains(String className) =>
      names.contains(className.trim().toLowerCase());
}

/// 一次目标检测的归一化结果。
///
/// 由 YOLO 原始结果派生：
/// - [areaRatio]：检测框面积 / 画面面积（0..1，要求 2）；
/// - [centerX]/[centerY]：目标中心归一化坐标（要求 2，供方位映射）。
class Detection {
  const Detection({
    required this.className,
    required this.confidence,
    required this.normalizedBox,
    this.isObstacle = true,
  });

  final String className;
  final double confidence;

  /// 归一化检测框（各值 0..1）
  final Rect normalizedBox;

  /// 是否属于障碍物类别白名单
  final bool isObstacle;

  /// 面积占比 = 框宽 × 框高（要求 2）
  double get areaRatio =>
      (normalizedBox.width * normalizedBox.height).clamp(0.0, 1.0);

  /// 目标中心归一化 X（0 左 → 1 右）
  double get centerX => normalizedBox.center.dx;

  /// 目标中心归一化 Y（0 上 → 1 下）
  double get centerY => normalizedBox.center.dy;

  @override
  String toString() =>
      'Detection{className: $className, confidence: $confidence, '
      'areaRatio: $areaRatio, center: ($centerX, $centerY)}';
}

/// 一帧画面的检测结果集合。
///
/// - 已按面积占比从大到小排序（要求 3）；
/// - [target] 为面积最大的目标（要求 3）；
/// - 默认仅保留障碍物类别（要求 1）。
class DetectionResult {
  const DetectionResult({required this.detections});

  final List<Detection> detections;

  bool get hasTarget => detections.isNotEmpty;

  /// 面积占比最大的目标，无则 null
  Detection? get target => detections.isEmpty ? null : detections.first;

  /// 从 YOLO 推理结果整型为归一化检测集合（纯函数，便于单元测试）。
  ///
  /// - 过滤置信度 < [confidenceThreshold] 的结果；
  /// - [obstaclesOnly] 为 true 时仅保留障碍物类别；
  /// - 计算面积占比与归一化中心坐标；
  /// - 按面积占比降序排序。
  factory DetectionResult.fromYoloResults(
    List<YOLOResult> results, {
    double confidenceThreshold = HardwareVisionService.confidenceThreshold,
    bool obstaclesOnly = true,
  }) {
    final detections = results
        .where((r) => r.confidence >= confidenceThreshold)
        .map(
          (r) => Detection(
            className: r.className,
            confidence: r.confidence,
            normalizedBox: r.normalizedBox,
            isObstacle: ObstacleClasses.contains(r.className),
          ),
        )
        .where((d) => !obstaclesOnly || d.isObstacle)
        .toList()
      ..sort((a, b) => b.areaRatio.compareTo(a.areaRatio));
    return DetectionResult(detections: detections);
  }
}
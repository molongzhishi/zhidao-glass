import 'azimuth_mapper.dart';
import 'coco_labels_zh.dart';
import 'vision_alert_engine.dart';

/// 雷达方向（融合层独立枚举，避免依赖蓝牙接收实现）
enum FusionRadarDirection { left, front, right, unknown }

/// 融合播报优先级：紧急 > 普通
enum FusionPriority { normal, emergency }

/// 一条待播报的融合结果
class FusionAnnouncement {
  const FusionAnnouncement({
    required this.priority,
    required this.text,
  });

  final FusionPriority priority;
  final String text;
}

/// 视觉通道的具名识别结果（由 [VisionReport] 裁剪而来）
class FusionVisionItem {
  const FusionVisionItem({
    required this.className,
    required this.weight,
    required this.centerX,
    this.level = VisionAlertLevel.normal,
  });

  final String className;
  final double weight;

  /// 目标中心归一化 X，用于雷达方向未知时的方位兜底
  final double centerX;

  final VisionAlertLevel level;
}

/// 雷达通道当前状态（服务运行时注入）
class FusionRadarState {
  const FusionRadarState({
    required this.hasObstacle,
    this.direction = FusionRadarDirection.unknown,
  });

  final bool hasObstacle;
  final FusionRadarDirection direction;
}

/// 雷达 + 视觉 融合裁决引擎（纯逻辑，可单测）。
///
/// 融合规则：
/// - 雷达有障碍 + 视觉有物品 → "[雷达方位]有[物品名]"；
/// - 雷达有障碍 + 视觉无物品 → "[雷达方位]有障碍物"；
/// - 雷达无障碍 + 视觉识别到物品 → 仅当物品权重 > [largeItemThreshold] 才可选播报
///   （方位取视觉中心 X，作为雷达失效时的独立通道）；
/// - 两者都无 → 不播报。
///
/// 方位决策：雷达方向为主（左/右/正前）；雷达方向未知或无障碍时，
/// 退化为视觉最大目标中心 X 的五档映射（画面坐标为辅，要求 2）。
///
/// 防重复：相同文案在 [minReportGap] 内不重复输出（要求 3 的防重复层之一）。
class FusionEngine {
  FusionEngine({
    this.largeItemThreshold = 0.30,
    this.minReportGap = const Duration(milliseconds: 700),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 仅视觉通道报告"大物品"的权重阈值（默认 30%，与紧急分级一致）
  final double largeItemThreshold;

  /// 相同播报文案的去重时间窗
  final Duration minReportGap;

  final DateTime Function() _now;

  /// 最近一次可播报的视觉结果（雷达触发时读取）
  FusionVisionItem? _visionItem;
  String? _lastKey;
  DateTime? _lastAnnouncedAt;

  /// 注入/更新视觉识别结果，返回是否应播报（含文案与优先级）。
  ///
  /// [item] 为 null 表示视觉通道路径下无目标。
  FusionAnnouncement? setVisionItem(
    FusionVisionItem? item,
    FusionRadarState radar,
  ) {
    _visionItem = item;
    if (item == null) return null;
    if (!radar.hasObstacle && item.weight <= largeItemThreshold) return null;
    return _announce(
      _priorityFor(item),
      _fusedText(radar.hasObstacle ? radar.direction : null, item),
    );
  }

  /// 雷达探测到障碍物：方位=雷达方向为主，物品名来自最新视觉结果。
  /// 视觉无目标时退化为 "[方位]有障碍物"。
  FusionAnnouncement? radarObstacle(FusionRadarDirection direction) {
    final item = _visionItem;
    if (item != null) {
      return _announce(
        _priorityFor(item),
        _fusedText(direction, item),
      );
    }
    return _announce(FusionPriority.normal, genericObstacleText(direction));
  }

  /// 雷达状态播报（已清除/断连/重连等通道文案直通）
  FusionAnnouncement? reportStatus(String text) =>
      _announce(FusionPriority.normal, text);

  /// 合成文案："[方位]有[物品名]"（紧急加"注意，"前缀）
  String _fusedText(FusionRadarDirection? radarDir, FusionVisionItem item) {
    final azimuth = resolveAzimuth(radarDir, item);
    final prefix = item.level == VisionAlertLevel.emergency ? '注意，' : '';
    return '$prefix$azimuth有${CocoLabelsZh.resolve(item.className)}';
  }

  /// 方位决策：雷达方向为主；方向未知/无障碍时用视觉中心 X 五档映射兜底
  String resolveAzimuth(
    FusionRadarDirection? radarDir,
    FusionVisionItem item,
  ) {
    switch (radarDir) {
      case FusionRadarDirection.left:
        return Azimuth.left.zh;
      case FusionRadarDirection.right:
        return Azimuth.right.zh;
      case FusionRadarDirection.front:
        return Azimuth.front.zh;
      case FusionRadarDirection.unknown:
      case null:
        return xToDirection(item.centerX).zh;
    }
  }

  /// 雷达触发但无视觉目标："[方位]有障碍物"
  String genericObstacleText(FusionRadarDirection dir) => switch (dir) {
        FusionRadarDirection.left => '左侧有障碍物',
        FusionRadarDirection.right => '右侧有障碍物',
        FusionRadarDirection.front => '正前方有障碍物',
        FusionRadarDirection.unknown => '前方有障碍物',
      };

  static FusionPriority _priorityFor(FusionVisionItem item) =>
      item.level == VisionAlertLevel.emergency
          ? FusionPriority.emergency
          : FusionPriority.normal;

  FusionAnnouncement? _announce(FusionPriority priority, String text) {
    if (text.isEmpty) return null;
    final now = _now();
    if (text == _lastKey &&
        _lastAnnouncedAt != null &&
        now.difference(_lastAnnouncedAt!) < minReportGap) {
      return null;
    }
    _lastKey = text;
    _lastAnnouncedAt = now;
    return FusionAnnouncement(priority: priority, text: text);
  }

  /// 复位内部状态（供测试/重连场景）
  void reset() {
    _visionItem = null;
    _lastKey = null;
    _lastAnnouncedAt = null;
  }
}
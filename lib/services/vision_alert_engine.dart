/// 视觉障碍报告的等级
enum VisionAlertLevel {
  /// 权重 < 10%，忽略
  ignore,

  /// 权重 10% ~ 30%，普通报告
  normal,

  /// 权重 > 30%，紧急报告
  emergency,
}

/// 一次视觉检测的结果（已归一化为面积占比 + 目标中心坐标）
class VisionObservation {
  const VisionObservation({
    required this.className,
    required this.weight,
    this.centerX = 0.5,
    this.centerY = 0.5,
  });

  final String className;

  /// 权重 = 检测框面积 / 画面面积（0..1）
  final double weight;

  /// 目标中心归一化 X（0 左 → 1 右），供方位映射
  final double centerX;

  /// 目标中心归一化 Y（0 上 → 1 下）
  final double centerY;
}

/// 引擎给出的报告决策
class VisionReport {
  const VisionReport({
    required this.shouldBroadcast,
    required this.level,
    required this.className,
    required this.weight,
    this.text,
    this.centerX = 0.5,
    this.centerY = 0.5,
  });

  /// 本次是否需要语音播报
  final bool shouldBroadcast;
  final VisionAlertLevel level;
  final String className;
  final double weight;

  /// 待播报文案（格式："前方有[物品名]"；紧急时加"注意，"前缀）
  final String? text;

  /// 最大目标中心归一化坐标（透传自观测，供融合方位映射）
  final double centerX;
  final double centerY;

  bool get hasTarget => className.isNotEmpty;
}

/// 视觉分级报告引擎（纯逻辑，便于单元测试）
///
/// 规则：
/// - 权重 = 检测框面积 / 画面面积；
/// - 仅保留权重 >= [normalThreshold]（10%）的观测，按权重从大到小排序；
/// - 权重 > [emergencyThreshold]（30%）→ 紧急报告，否则普通报告；
/// - 只报告权重最大的物品；
/// - 同一物品持续存在时，距上次播报不足 [repeatInterval] 则抑制，达到间隔后重复播报；
/// - 目标消失后再出现，立即恢复播报。
class VisionAlertEngine {
  VisionAlertEngine({
    this.emergencyThreshold = 0.30,
    this.normalThreshold = 0.10,
    this.repeatInterval = const Duration(seconds: 2),
    String Function(String className)? labelResolver,
  }) : _labelResolver = labelResolver ?? _identity;

  final double emergencyThreshold;
  final double normalThreshold;
  final Duration repeatInterval;
  final String Function(String className) _labelResolver;

  String? _lastClassName;
  DateTime? _lastBroadcastAt;

  static String _identity(String className) => className;

  /// 评估当前观测集合，返回应否播报及文案。
  VisionReport evaluate(
    List<VisionObservation> observations, {
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();

    VisionObservation? top;
    for (final observation in observations) {
      if (observation.weight < normalThreshold) continue;
      if (top == null || observation.weight > top.weight) {
        top = observation;
      }
    }

    if (top == null) {
      // 当前无达标目标，重置以便下次出现时立即播报
      _lastClassName = null;
      _lastBroadcastAt = null;
      return const VisionReport(
        shouldBroadcast: false,
        level: VisionAlertLevel.ignore,
        className: '',
        weight: 0,
      );
    }

    final level = top.weight > emergencyThreshold
        ? VisionAlertLevel.emergency
        : VisionAlertLevel.normal;

    final sameAsLast = _lastClassName == top.className;
    final due = _lastBroadcastAt == null ||
        timestamp.difference(_lastBroadcastAt!) >= repeatInterval;

    if (sameAsLast && !due) {
      return VisionReport(
        shouldBroadcast: false,
        level: level,
        className: top.className,
        weight: top.weight,
        centerX: top.centerX,
        centerY: top.centerY,
      );
    }

    _lastClassName = top.className;
    _lastBroadcastAt = timestamp;

    final name = _labelResolver(top.className);
    final prefix = level == VisionAlertLevel.emergency ? '注意，' : '';
    return VisionReport(
      shouldBroadcast: true,
      level: level,
      className: top.className,
      weight: top.weight,
      text: '$prefix前方有$name',
      centerX: top.centerX,
      centerY: top.centerY,
    );
  }

  /// 复位内部去重状态
  void reset() {
    _lastClassName = null;
    _lastBroadcastAt = null;
  }
}

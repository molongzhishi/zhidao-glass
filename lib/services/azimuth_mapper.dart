/// 五档方位（由归一化坐标 X 映射而来）
enum Azimuth {
  left,
  leftFront,
  front,
  rightFront,
  right;

  /// 播报用中文词：方位 + "有" + 物品名
  String get zh => switch (this) {
        Azimuth.left => '左侧',
        Azimuth.leftFront => '左前方',
        Azimuth.front => '正前方',
        Azimuth.rightFront => '右前方',
        Azimuth.right => '右侧',
      };
}

/// 归一化中心 X（0 左 → 1 右）→ 五档方位。
///
/// 阈值可配置（默认左前/正前/右前/右侧边界 0.2 / 0.4 / 0.6 / 0.8）：
/// - [0.00, 0.20) 左
/// - [0.20, 0.40) 左前
/// - [0.40, 0.60) 正前
/// - [0.60, 0.80) 右前
/// - [0.80, 1.00] 右
class AzimuthMapper {
  const AzimuthMapper({
    this.leftBoundary = 0.20,
    this.leftFrontBoundary = 0.40,
    this.frontBoundary = 0.60,
    this.rightFrontBoundary = 0.80,
  });

  final double leftBoundary;
  final double leftFrontBoundary;
  final double frontBoundary;
  final double rightFrontBoundary;

  Azimuth fromX(double centerX) {
    if (centerX < leftBoundary) return Azimuth.left;
    if (centerX < leftFrontBoundary) return Azimuth.leftFront;
    if (centerX < frontBoundary) return Azimuth.front;
    if (centerX < rightFrontBoundary) return Azimuth.rightFront;
    return Azimuth.right;
  }
}

/// 归一化中心 X → 五档方位（默认阈值）。
///
/// 可通过 [mapper] 传入自定义阈值。
Azimuth xToDirection(
  double centerX, {
  AzimuthMapper mapper = const AzimuthMapper(),
}) =>
    mapper.fromX(centerX);

/// 三档映射方位（简化展示用）：左前 / 正前 / 右前
enum FrontAzimuth { leftFront, front, rightFront }

extension FrontAzimuthLabel on FrontAzimuth {
  /// 展示用中文词
  String get zh => switch (this) {
        FrontAzimuth.leftFront => '左前',
        FrontAzimuth.front => '正前',
        FrontAzimuth.rightFront => '右前',
      };
}

/// 归一化中心 X → 三档方位（左前/正前/右前）。
///
/// 默认边界：[leftBoundary, rightBoundary]（默认 0.4 ~ 0.6）为中心正前区，
/// 两侧分别为左前 / 右前，供状态页等简化展示使用。
FrontAzimuth xToFrontAzimuth(
  double centerX, {
  double leftBoundary = 0.40,
  double rightBoundary = 0.60,
}) {
  if (centerX < leftBoundary) return FrontAzimuth.leftFront;
  if (centerX > rightBoundary) return FrontAzimuth.rightFront;
  return FrontAzimuth.front;
}
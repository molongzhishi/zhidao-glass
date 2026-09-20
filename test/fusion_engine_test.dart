import 'package:flutter_test/flutter_test.dart';
import 'package:multimodal_chat/services/fusion_engine.dart';
import 'package:multimodal_chat/services/vision_alert_engine.dart';

FusionVisionItem item(
  String className,
  double weight, {
  double centerX = 0.5,
  VisionAlertLevel level = VisionAlertLevel.normal,
}) =>
    FusionVisionItem(
      className: className,
      weight: weight,
      centerX: centerX,
      level: level,
    );

/// 以"雷达静默 + 未达大物品阈值"的方式仅存储视觉结果，不触发播报，
/// 以便随后单独验证 [FusionEngine.radarObstacle] 的输出。
void storeSilently(FusionEngine engine, FusionVisionItem visionItem) {
  final a = engine.setVisionItem(
    visionItem,
    const FusionRadarState(hasObstacle: false),
  );
  expect(a, isNull, reason: '雷达静默且未达大物品阈值时不应播报');
}

void main() {
  group('FusionEngine rules', () {
    test('radar obstacle + vision item -> [方位]有[物品名] (radar azimuth primary)',
        () {
      final engine = FusionEngine();
      storeSilently(engine, item('person', 0.2, centerX: 0.9));
      final a = engine.radarObstacle(FusionRadarDirection.left);
      expect(a, isNotNull);
      expect(a!.text, '左侧有行人');
      expect(a.priority, FusionPriority.normal);
    });

    test('radar obstacle + no vision item -> [方位]有障碍物', () {
      final engine = FusionEngine();
      final a = engine.radarObstacle(FusionRadarDirection.right);
      expect(a!.text, '右侧有障碍物');
    });

    test('radar unknown direction uses vision x as fallback (coordinate secondary)',
        () {
      final engine = FusionEngine();
      storeSilently(engine, item('car', 0.2, centerX: 0.75));
      final a = engine.radarObstacle(FusionRadarDirection.unknown);
      expect(a!.text, '右前方有汽车');
    });

    test('neither radar nor vision -> no announcement', () {
      final engine = FusionEngine();
      expect(engine.setVisionItem(null, const FusionRadarState(hasObstacle: false)), isNull);
      expect(engine.setVisionItem(
            item('car', 0.12),
            const FusionRadarState(hasObstacle: false),
          ),
          isNull);
      expect(engine.reportStatus(''), isNull);
    });

    test('radar silent + small vision item -> silent', () {
      final engine = FusionEngine();
      final a = engine.setVisionItem(
        item('car', 0.12),
        const FusionRadarState(hasObstacle: false),
      );
      expect(a, isNull);
    });

    test('radar silent + large vision item -> optional named report', () {
      final engine = FusionEngine();
      final a = engine.setVisionItem(
        item('car', 0.45, centerX: 0.5, level: VisionAlertLevel.emergency),
        const FusionRadarState(hasObstacle: false),
      );
      expect(a!.text, '注意，正前方有汽车');
      expect(a.priority, FusionPriority.emergency);
    });

    test('radar obstacle with emergency vision item -> emergency priority',
        () {
      final engine = FusionEngine();
      storeSilently(
        engine,
        item('car', 0.2, level: VisionAlertLevel.emergency),
      );
      final a = engine.radarObstacle(FusionRadarDirection.front);
      expect(a!.text, '注意，正前方有汽车');
      expect(a.priority, FusionPriority.emergency);
    });

    test('status announcements pass through', () {
      final engine = FusionEngine();
      final a = engine.reportStatus('前方已恢复通行');
      expect(a!.text, '前方已恢复通行');
      expect(a.priority, FusionPriority.normal);
    });
  });

  group('FusionEngine anti-repeat', () {
    test('dedups identical text within minReportGap', () {
      final now = DateTime(2026, 1, 1, 12);
      final engine = FusionEngine(now: () => now);
      storeSilently(engine, item('car', 0.2));
      expect(engine.radarObstacle(FusionRadarDirection.front), isNotNull);
      // 同文案在时间窗内被抑制
      expect(engine.radarObstacle(FusionRadarDirection.front), isNull);
    });

    test('allows same text again after minReportGap elapses', () {
      var now = DateTime(2026, 1, 1, 12);
      final engine = FusionEngine(now: () => now);
      storeSilently(engine, item('car', 0.2));
      expect(engine.radarObstacle(FusionRadarDirection.front), isNotNull);
      now = now.add(const Duration(seconds: 2));
      expect(engine.radarObstacle(FusionRadarDirection.front), isNotNull);
    });

    test('allows distinct text despite minReportGap', () {
      final now = DateTime(2026, 1, 1, 12);
      final engine = FusionEngine(now: () => now);
      storeSilently(engine, item('car', 0.2));
      expect(engine.radarObstacle(FusionRadarDirection.front), isNotNull);
      storeSilently(engine, item('truck', 0.2));
      expect(engine.radarObstacle(FusionRadarDirection.left), isNotNull);
    });

    test('small minReportGap reduces blocking', () {
      var now = DateTime(2026, 1, 1, 12);
      final engine = FusionEngine(
        minReportGap: const Duration(milliseconds: 10),
        now: () => now,
      );
      storeSilently(engine, item('car', 0.2));
      expect(engine.radarObstacle(FusionRadarDirection.front), isNotNull);
      now = now.add(const Duration(milliseconds: 20));
      expect(engine.radarObstacle(FusionRadarDirection.front), isNotNull);
    });
  });
}
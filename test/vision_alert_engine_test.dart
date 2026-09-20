import 'package:flutter_test/flutter_test.dart';
import 'package:multimodal_chat/services/coco_labels_zh.dart';
import 'package:multimodal_chat/services/vision_alert_engine.dart';

VisionObservation obs(String name, double weight) =>
    VisionObservation(className: name, weight: weight);

VisionAlertEngine newEngine() =>
    VisionAlertEngine(labelResolver: CocoLabelsZh.resolve);

void main() {
  group('CocoLabelsZh', () {
    test('translates known COCO classes', () {
      expect(CocoLabelsZh.resolve('person'), '行人');
      expect(CocoLabelsZh.resolve('car'), '汽车');
      expect(CocoLabelsZh.resolve('PERSON'), '行人');
    });

    test('falls back to original name for unknown classes', () {
      expect(CocoLabelsZh.resolve('spaceship'), 'spaceship');
    });
  });

  group('VisionAlertEngine', () {
    test('ignores observations below normal threshold', () {
      final engine = newEngine();
      final report = engine.evaluate([obs('person', 0.09)]);
      expect(report.shouldBroadcast, isFalse);
      expect(report.level, VisionAlertLevel.ignore);
    });

    test('reports normal level for 10%~30% weight', () {
      final engine = newEngine();
      final report = engine.evaluate([obs('car', 0.15)]);
      expect(report.shouldBroadcast, isTrue);
      expect(report.level, VisionAlertLevel.normal);
      expect(report.text, '前方有汽车');
    });

    test('reports emergency level for weight > 30%', () {
      final engine = newEngine();
      final report = engine.evaluate([obs('car', 0.45)]);
      expect(report.shouldBroadcast, isTrue);
      expect(report.level, VisionAlertLevel.emergency);
      expect(report.text, '注意，前方有汽车');
    });

    test('only reports the largest weighted object', () {
      final engine = newEngine();
      final report = engine.evaluate([
        obs('chair', 0.12),
        obs('person', 0.05),
        obs('person', 0.18),
      ]);
      expect(report.className, 'person');
      expect(report.weight, 0.18);
      expect(report.text, '前方有行人');
    });

    test('suppresses repeat within repeatInterval for same object', () {
      final engine = newEngine();
      final base = DateTime(2026, 1, 1, 12, 0, 0);
      final first = engine.evaluate([obs('person', 0.2)], now: base);
      expect(first.shouldBroadcast, isTrue);

      final tooSoon = engine.evaluate(
        [obs('person', 0.2)],
        now: base.add(const Duration(milliseconds: 1500)),
      );
      expect(tooSoon.shouldBroadcast, isFalse);
    });

    test('repeats after repeatInterval elapses', () {
      final engine = newEngine();
      final base = DateTime(2026, 1, 1, 12, 0, 0);
      engine.evaluate([obs('person', 0.2)], now: base);
      final due = engine.evaluate(
        [obs('person', 0.2)],
        now: base.add(const Duration(seconds: 2)),
      );
      expect(due.shouldBroadcast, isTrue);
      expect(due.text, '前方有行人');
    });

    test('broadcasts immediately when object changes', () {
      final engine = newEngine();
      final base = DateTime(2026, 1, 1, 12, 0, 0);
      engine.evaluate([obs('person', 0.2)], now: base);
      final changed = engine.evaluate(
        [obs('car', 0.2)],
        now: base.add(const Duration(milliseconds: 500)),
      );
      expect(changed.shouldBroadcast, isTrue);
      expect(changed.text, '前方有汽车');
    });

    test('reports immediately after target disappears then reappears', () {
      final engine = newEngine();
      final base = DateTime(2026, 1, 1, 12, 0, 0);
      engine.evaluate([obs('person', 0.2)], now: base);
      engine.evaluate(
        [obs('person', 0.02)],
        now: base.add(const Duration(seconds: 1)),
      );
      final reappear = engine.evaluate(
        [obs('person', 0.2)],
        now: base.add(const Duration(milliseconds: 1500)),
      );
      expect(reappear.shouldBroadcast, isTrue);
    });

    test('reset clears anti-repeat state', () {
      final engine = newEngine();
      final base = DateTime(2026, 1, 1, 12, 0, 0);
      engine.evaluate([obs('person', 0.2)], now: base);
      engine.reset();
      final after = engine.evaluate(
        [obs('person', 0.2)],
        now: base.add(const Duration(milliseconds: 100)),
      );
      expect(after.shouldBroadcast, isTrue);
    });
  });
}

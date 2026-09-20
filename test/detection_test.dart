import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:multimodal_chat/services/detection.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

YOLOResult yoloResult({
  required String className,
  required double confidence,
  required Rect box,
  int classIndex = 0,
}) {
  return YOLOResult(
    classIndex: classIndex,
    className: className,
    confidence: confidence,
    boundingBox: Rect.fromLTWH(
      box.left * 640,
      box.top * 640,
      box.width * 640,
      box.height * 640,
    ),
    normalizedBox: box,
  );
}

void main() {
  group('ObstacleClasses', () {
    test('recognizes ground-level obstacle classes', () {
      for (final name in ['person', 'car', 'bus', 'bench', 'chair', 'dog']) {
        expect(ObstacleClasses.contains(name), isTrue, reason: name);
      }
    });

    test('excludes non-obstacle classes (air/sky/wall/decor)', () {
      for (final name in ['bird', 'airplane', 'tv', 'book', 'clock', 'vase']) {
        expect(ObstacleClasses.contains(name), isFalse, reason: name);
      }
    });

    test('is case-insensitive and trims whitespace', () {
      expect(ObstacleClasses.contains('Car'), isTrue);
      expect(ObstacleClasses.contains('  PERSON '), isTrue);
    });
  });

  group('Detection', () {
    test('computes normalized center and area ratio from box', () {
      const box = Rect.fromLTWH(0.25, 0.5, 0.5, 0.4);
      const detection = Detection(
        className: 'car',
        confidence: 0.9,
        normalizedBox: box,
      );
      expect(detection.centerX, closeTo(0.5, 1e-9));
      expect(detection.centerY, closeTo(0.7, 1e-9));
      expect(detection.areaRatio, closeTo(0.2, 1e-9));
      expect(detection.isObstacle, isTrue);
    });

    test('clamps area ratio to [0, 1]', () {
      const detection = Detection(
        className: 'x',
        confidence: 0.9,
        normalizedBox: Rect.fromLTWH(-0.1, -0.1, 1.2, 1.2),
      );
      expect(detection.areaRatio, 1.0);
    });
  });

  group('DetectionResult.fromYoloResults', () {
    test('maps results and sorts by area ratio descending', () {
      final results = [
        yoloResult(
          className: 'person',
          confidence: 0.9,
          box: const Rect.fromLTWH(0, 0, 0.1, 0.5),
        ), // 面积 0.05
        yoloResult(
          className: 'car',
          confidence: 0.85,
          box: const Rect.fromLTWH(0, 0, 0.6, 0.5),
        ), // 面积 0.30
        yoloResult(
          className: 'bicycle',
          confidence: 0.8,
          box: const Rect.fromLTWH(0, 0, 0.4, 0.2),
        ), // 面积 0.08
      ];
      final result = DetectionResult.fromYoloResults(results);
      expect(result.detections.length, 3);
      expect(result.detections.map((d) => d.className).toList(),
          ['car', 'bicycle', 'person']);
      expect(result.target!.className, 'car');
      expect(result.hasTarget, isTrue);
      expect(result.detections.first.areaRatio, closeTo(0.3, 1e-9));
    });

    test('target reflects the largest object with normalized center', () {
      final result = DetectionResult.fromYoloResults([
        yoloResult(
          className: 'truck',
          confidence: 0.7,
          box: const Rect.fromLTWH(0.3, 0.2, 0.5, 0.6),
        ),
        yoloResult(
          className: 'person',
          confidence: 0.9,
          box: const Rect.fromLTWH(0.1, 0.1, 0.2, 0.3),
        ),
      ]);
      expect(result.target!.className, 'truck');
      expect(result.target!.centerX, closeTo(0.55, 1e-9));
      expect(result.target!.centerY, closeTo(0.5, 1e-9));
    });

    test('returns empty result for no detections', () {
      final result = DetectionResult.fromYoloResults(const []);
      expect(result.hasTarget, isFalse);
      expect(result.target, isNull);
      expect(result.detections, isEmpty);
    });

    test('filters detections below confidence threshold', () {
      final result = DetectionResult.fromYoloResults(
        [
          yoloResult(
            className: 'car',
            confidence: 0.3,
            box: const Rect.fromLTWH(0, 0, 0.5, 0.5),
          ),
          yoloResult(
            className: 'car',
            confidence: 0.6,
            box: const Rect.fromLTWH(0, 0, 0.5, 0.5),
          ),
        ],
        confidenceThreshold: 0.5,
      );
      expect(result.detections.single.confidence, 0.6);
    });

    test('filters out non-obstacle classes by default', () {
      final result = DetectionResult.fromYoloResults([
        yoloResult(
          className: 'horse',
          confidence: 0.9,
          box: const Rect.fromLTWH(0, 0, 0.5, 0.5),
        ),
        yoloResult(
          className: 'bird',
          confidence: 0.95,
          box: const Rect.fromLTWH(0, 0, 0.8, 0.8),
        ),
        yoloResult(
          className: 'cell phone',
          confidence: 0.98,
          box: const Rect.fromLTWH(0, 0, 0.9, 0.9),
        ),
      ]);
      expect(result.detections.single.className, 'horse');
    });

    test('keeps all classes when obstaclesOnly is false', () {
      final result = DetectionResult.fromYoloResults(
        [
          yoloResult(
            className: 'bird',
            confidence: 0.9,
            box: const Rect.fromLTWH(0, 0, 0.7, 0.1),
          ),
        ],
        obstaclesOnly: false,
      );
      expect(result.detections.single.className, 'bird');
    });
  });
}
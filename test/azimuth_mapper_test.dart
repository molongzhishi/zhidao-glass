import 'package:flutter_test/flutter_test.dart';
import 'package:multimodal_chat/services/azimuth_mapper.dart';

void main() {
  group('xToDirection', () {
    test('maps normalized center X to five azimuth zones (default 0.2/0.4/0.6/0.8)',
        () {
      expect(xToDirection(0.00), Azimuth.left);
      expect(xToDirection(0.19), Azimuth.left);
      expect(xToDirection(0.20), Azimuth.leftFront);
      expect(xToDirection(0.39), Azimuth.leftFront);
      expect(xToDirection(0.40), Azimuth.front);
      expect(xToDirection(0.59), Azimuth.front);
      expect(xToDirection(0.60), Azimuth.rightFront);
      expect(xToDirection(0.79), Azimuth.rightFront);
      expect(xToDirection(0.80), Azimuth.right);
      expect(xToDirection(1.00), Azimuth.right);
    });

    test('public spec: <0.2 left / <0.4 leftFront / <0.6 front / <0.8 rightFront / >=0.8 right',
        () {
      expect(xToDirection(0.19), Azimuth.left);
      expect(xToDirection(0.2), Azimuth.leftFront);
      expect(xToDirection(0.39), Azimuth.leftFront);
      expect(xToDirection(0.4), Azimuth.front);
      expect(xToDirection(0.59), Azimuth.front);
      expect(xToDirection(0.6), Azimuth.rightFront);
      expect(xToDirection(0.79), Azimuth.rightFront);
      expect(xToDirection(0.8), Azimuth.right);
      expect(xToDirection(0.99), Azimuth.right);
    });

    test('zh labels are speech-friendly', () {
      expect(Azimuth.left.zh, '左侧');
      expect(Azimuth.leftFront.zh, '左前方');
      expect(Azimuth.front.zh, '正前方');
      expect(Azimuth.rightFront.zh, '右前方');
      expect(Azimuth.right.zh, '右侧');
    });

    test('QA spec: X=0.10 -> 左侧, X=0.50 -> 正前方', () {
      expect(xToDirection(0.10), Azimuth.left);
      expect(xToDirection(0.10).zh, '左侧');
      expect(xToDirection(0.50), Azimuth.front);
      expect(xToDirection(0.50).zh, '正前方');
    });
  });

  group('AzimuthMapper (configurable thresholds)', () {
    test('custom thresholds shift the zone boundaries', () {
      const mapper = AzimuthMapper(
        leftBoundary: 0.1,
        leftFrontBoundary: 0.3,
        frontBoundary: 0.5,
        rightFrontBoundary: 0.7,
      );
      expect(mapper.fromX(0.05), Azimuth.left);
      expect(mapper.fromX(0.10), Azimuth.leftFront);
      expect(mapper.fromX(0.30), Azimuth.front);
      expect(mapper.fromX(0.50), Azimuth.rightFront);
      expect(mapper.fromX(0.70), Azimuth.right);
    });

    test('allows passing custom mapper through xToDirection', () {
      const mapper = AzimuthMapper(frontBoundary: 0.5);
      expect(xToDirection(0.55, mapper: mapper), Azimuth.rightFront);
      expect(xToDirection(0.55), Azimuth.front, reason: '默认阈值下应在前');
    });

    test('respects default const constructor', () {
      expect(const AzimuthMapper().fromX(0.6), Azimuth.rightFront);
    });
  });

  group('xToFrontAzimuth (三档方位)', () {
    test('maps center X to leftFront / front / rightFront (default 0.4/0.6)', () {
      expect(xToFrontAzimuth(0.00), FrontAzimuth.leftFront);
      expect(xToFrontAzimuth(0.39), FrontAzimuth.leftFront);
      expect(xToFrontAzimuth(0.40), FrontAzimuth.front);
      expect(xToFrontAzimuth(0.60), FrontAzimuth.front);
      expect(xToFrontAzimuth(0.61), FrontAzimuth.rightFront);
      expect(xToFrontAzimuth(1.00), FrontAzimuth.rightFront);
    });

    test('zh labels match status page display spec', () {
      expect(FrontAzimuth.leftFront.zh, '左前');
      expect(FrontAzimuth.front.zh, '正前');
      expect(FrontAzimuth.rightFront.zh, '右前');
    });
  });
}
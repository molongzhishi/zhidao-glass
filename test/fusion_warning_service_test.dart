import 'package:flutter_test/flutter_test.dart';
import 'package:multimodal_chat/services/bluetooth_receiver.dart';
import 'package:multimodal_chat/services/bluetooth_spp_service.dart';
import 'package:multimodal_chat/services/fusion_warning_service.dart';
import 'package:multimodal_chat/services/vision_alert_engine.dart';
import 'package:multimodal_chat/services/vision_warning_service.dart';
import 'package:multimodal_chat/services/warning_center.dart';

VisionReport vision(
  String name,
  double weight,
  String text, {
  double centerX = 0.5,
}) =>
    VisionReport(
      shouldBroadcast: true,
      level: weight > 0.30
          ? VisionAlertLevel.emergency
          : VisionAlertLevel.normal,
      className: name,
      weight: weight,
      text: text,
      centerX: centerX,
    );

void main() {
  late List<List<String>> spoken;
  late BluetoothReceiver radar;
  late FusionWarningService fusion;

  FusionWarningService buildFusion({Duration minGap = Duration.zero}) {
    spoken = [];
    fusion = FusionWarningService(
      radar: radar,
      vision: VisionWarningService(warningCenter: WarningCenter()),
      ttsService: null,
      minReportGap: minGap,
      speakOverride: (texts) async {
        spoken.add(List.of(texts));
      },
    );
    return fusion;
  }

  setUp(() {
    radar = BluetoothReceiver(
      bluetoothSpp: BluetoothSppService(),
      warningCenter: WarningCenter(),
      ttsService: null,
    );
  });

  group('FusionWarningService', () {
    test('radar + vision item -> fused named report only', () {
      buildFusion();
      fusion.feedVisionReport(vision('car', 0.2, '前方有汽车'));
      radar.feedSensorLine('RADAR:OBSTACLE LEFT');
      expect(spoken, hasLength(1));
      expect(spoken.single, ['左侧有汽车']);
    });

    test('radar obstacle + no vision item -> generic obstacle report', () {
      buildFusion();
      radar.feedSensorLine('RADAR:OBSTACLE');
      expect(spoken, hasLength(1));
      expect(spoken.single, [BluetoothReceiver.obstacleAnnouncement]);
    });

    test('radar obstacle uses direction-aware text', () {
      buildFusion();
      radar.feedSensorLine('RADAR:OBSTACLE RIGHT');
      expect(spoken.single, ['右侧有障碍物']);
    });

    test('no radar + vision large item -> named report (optional large)', () {
      buildFusion();
      fusion.feedVisionReport(vision('car', 0.45, '注意，前方有汽车'));
      expect(spoken, hasLength(1));
      expect(spoken.single, ['注意，正前方有汽车']);
    });

    test('no radar + vision small item -> silent', () {
      buildFusion();
      fusion.feedVisionReport(vision('car', 0.12, '前方有汽车'));
      expect(spoken, isEmpty);
    });

    test('neither channel active -> never reports', () {
      buildFusion();
      fusion.feedVisionReport(vision('person', 0.05, '前方有行人'));
      radar.feedSensorLine('RADAR:CLEAR');
      expect(spoken, isEmpty);
    });

    test('radar azimuth primary when 视觉方位与雷达方位不一致', () {
      buildFusion();
      // 画面目标中心 X=0.9 → 画面映射为"右侧"，但雷达明确"左" → 以雷达为准
      radar.feedSensorLine('RADAR:OBSTACLE LEFT');
      fusion.feedVisionReport(vision('car', 0.2, '前方有汽车', centerX: 0.9));
      expect(spoken.last, ['左侧有汽车']);
    });

    test('radar clear announces recovery', () {
      buildFusion();
      radar.feedSensorLine('RADAR:OBSTACLE');
      radar.feedSensorLine('RADAR:CLEAR');
      expect(spoken.last, [BluetoothReceiver.clearAnnouncement]);
    });

    test('vision supplement: item change while radar active reports name only',
        () {
      buildFusion();
      radar.feedSensorLine('RADAR:OBSTACLE');
      fusion.feedVisionReport(vision('car', 0.2, '前方有汽车'));
      fusion.feedVisionReport(vision('person', 0.2, '前方有行人'));
      expect(spoken, [
        [BluetoothReceiver.obstacleAnnouncement],
        ['正前方有汽车'],
        ['正前方有行人'],
      ]);
    });

    test('vision keeps working when radar is silent (fault tolerance)', () {
      buildFusion();
      radar.feedSensorLine('RADAR:CLEAR');
      fusion.feedVisionReport(vision('car', 0.5, '前方有汽车'));
      expect(spoken.single, ['注意，正前方有汽车']);
    });

    test('radar keeps working without any vision reports (fault tolerance)',
        () {
      buildFusion();
      radar.feedSensorLine('RADAR:OBSTACLE');
      expect(spoken.single, [BluetoothReceiver.obstacleAnnouncement]);
      radar.feedSensorLine('RADAR:CLEAR');
      expect(spoken.last, [BluetoothReceiver.clearAnnouncement]);
    });

    test('dedups identical report within minReportGap', () {
      buildFusion(minGap: const Duration(milliseconds: 100));
      fusion.feedVisionReport(vision('car', 0.5, '前方有汽车'));
      fusion.feedVisionReport(vision('car', 0.5, '前方有汽车'));
      expect(spoken, hasLength(1));
    });

    test('allows distinct reports despite minReportGap', () {
      buildFusion(minGap: const Duration(milliseconds: 100));
      fusion.feedVisionReport(vision('car', 0.5, '前方有汽车'));
      fusion.feedVisionReport(vision('person', 0.5, '前方有行人'));
      expect(spoken, hasLength(2));
    });
  });
}
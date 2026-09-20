import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:multimodal_chat/services/bluetooth_receiver.dart';
import 'package:multimodal_chat/services/bluetooth_spp_service.dart';
import 'package:multimodal_chat/services/detection.dart';
import 'package:multimodal_chat/services/detection_pipeline.dart';
import 'package:multimodal_chat/services/fusion_warning_service.dart';
import 'package:multimodal_chat/services/hardware_vision_service.dart';
import 'package:multimodal_chat/services/vision_alert_engine.dart';
import 'package:multimodal_chat/services/vision_warning_service.dart';
import 'package:multimodal_chat/services/warning_center.dart';

Uint8List jpeg([int size = 4]) => Uint8List.fromList(List.filled(size, 0xFF));

class FakeDetectionPipeline extends DetectionPipeline {
  FakeDetectionPipeline({required this.frameDefault});

  final DetectionResult frameDefault;

  @override
  Future<DetectionResult> analyze(
    Uint8List frame, {
    double confidenceThreshold = HardwareVisionService.confidenceThreshold,
    bool obstaclesOnly = true,
  }) async =>
      frameDefault;

  @override
  Future<void> dispose() async {}
}

void main() {
  // QA 场景 1：雷达触发 → 摄像头取帧 → YOLO → 播报
  test('radar trigger -> camera frame -> yolo -> fused broadcast', () async {
    final spoken = <List<String>>[];
    final radar = BluetoothReceiver(
      bluetoothSpp: BluetoothSppService(),
      warningCenter: WarningCenter(),
      ttsService: null,
    );
    final vision = VisionWarningService(
      warningCenter: WarningCenter(),
      ttsService: null,
      pipeline: FakeDetectionPipeline(
        frameDefault: const DetectionResult(
          detections: [
            Detection(
              className: 'car',
              confidence: 0.9,
              normalizedBox: Rect.fromLTWH(0.2, 0.25, 0.6, 0.5),
            ),
          ],
        ),
      ),
      confidenceThreshold: 0.5,
    );
    final fusion = FusionWarningService(
      radar: radar,
      vision: vision,
      ttsService: null,
      speakOverride: (texts) async => spoken.add(List.of(texts)),
    );

    // 1. 雷达触发
    radar.feedSensorLine('RADAR:OBSTACLE LEFT');
    expect(fusion.radarActive, isTrue);

    // 2. 摄像头取帧（UVC 帧喂入）→ 触发一轮推理
    vision.submitFrame(jpeg());
    vision.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    vision.stop();

    // 3. 融合播报：无视觉目标的雷达播报 + 识别出汽车后的融合播报
    expect(spoken, isNotEmpty);
    expect(spoken.first, ['左侧有障碍物']);
    expect(spoken.last.single, contains('汽车'));
    expect(spoken.last.single, contains('左侧有汽车'),
        reason: '雷达方位为主叠加 YOLO 物品名');

    radar.dispose();
    vision.dispose();
  });

  // 融合引擎不带 YOLO 的快速链路（防御雷达方向的兜底）
  test('vision coordinate only broadcast when radar has no obstacle', () async {
    final spoken = <List<String>>[];
    final radar = BluetoothReceiver(
      bluetoothSpp: BluetoothSppService(),
      warningCenter: WarningCenter(),
      ttsService: null,
    );
    final fusion = FusionWarningService(
      radar: radar,
      vision: VisionWarningService(warningCenter: WarningCenter()),
      ttsService: null,
      speakOverride: (texts) async => spoken.add(List.of(texts)),
    );
    expect(fusion, isNotNull);

    fusion.feedVisionReport(
      const VisionReport(
        shouldBroadcast: true,
        level: VisionAlertLevel.emergency,
        className: 'car',
        weight: 0.45,
        text: '注意，前方有汽车',
        centerX: 0.5,
      ),
    );
    expect(spoken.single, ['注意，正前方有汽车']);

    radar.dispose();
  });
}
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:multimodal_chat/services/builtin_camera_source.dart';
import 'package:multimodal_chat/services/camera_source.dart';
import 'package:multimodal_chat/services/camera_source_manager.dart';
import 'package:multimodal_chat/services/uvc_camera_source.dart';

Uint8List jpeg([int size = 4]) => Uint8List.fromList(List.filled(size, 0xFF));

class FakeFrameHub implements CameraFrameHub {
  FakeFrameHub({
    this.hasInternalCamera = false,
    this.builtInFrame,
    this.uvcFrame,
    this.uvcAt,
  });

  @override
  bool hasInternalCamera;
  Uint8List? builtInFrame;
  Uint8List? uvcFrame;
  DateTime? uvcAt;

  @override
  Uint8List? get lastUvcFrame => uvcFrame;

  @override
  DateTime? get lastUvcFrameAt => uvcAt;

  @override
  Future<Uint8List?> grabBuiltInFrame() async => builtInFrame;
}

class FakeUvcState implements UvcOpenState {
  FakeUvcState({
    this.isOpened = false,
    this.hasFrameStallFault = false,
    this.previewWidth,
    this.previewHeight,
  });

  @override
  bool isOpened;
  @override
  bool hasFrameStallFault;
  @override
  int? previewWidth;
  @override
  int? previewHeight;
}

class FakeSource implements CameraSource {
  FakeSource({
    required this.kind,
    required this.label,
    this.available = false,
    this.frame,
  });

  @override
  final CameraSourceKind kind;
  @override
  final String label;
  bool available;
  CameraFrame? frame;

  @override
  bool get isAvailable => available;

  @override
  Future<CameraFrame?> getFrame() async => frame;
}

void main() {
  group('BuiltinCameraSource', () {
    test('unavailable until internal camera controller is registered', () async {
      final hub = FakeFrameHub(hasInternalCamera: false);
      final source = BuiltinCameraSource(hub);
      expect(source.kind, CameraSourceKind.builtin);
      expect(source.label, contains('内置'));
      expect(source.isAvailable, isFalse);
      expect(await source.getFrame(), isNull);
    });

    test('grabs a frame when internal camera is ready', () async {
      final hub = FakeFrameHub(
        hasInternalCamera: true,
        builtInFrame: jpeg(),
      );
      final source = BuiltinCameraSource(hub);
      expect(source.isAvailable, isTrue);
      final frame = await source.getFrame();
      expect(frame, isNotNull);
      expect(frame!.bytes, equals(jpeg()));
    });
  });

  group('UvcCameraSource', () {
    test('unavailable when uvc not opened or has stall fault', () async {
      final source = UvcCameraSource(
        frameHub: FakeFrameHub(uvcFrame: jpeg(), uvcAt: DateTime.now()),
        uvcState: FakeUvcState(isOpened: false),
      );
      expect(source.kind, CameraSourceKind.uvc);
      expect(source.isAvailable, isFalse);
      expect(await source.getFrame(), isNull);

      final stalled = UvcCameraSource(
        frameHub: FakeFrameHub(uvcFrame: jpeg(), uvcAt: DateTime.now()),
        uvcState: FakeUvcState(isOpened: true, hasFrameStallFault: true),
      );
      expect(stalled.isAvailable, isFalse);
      expect(await stalled.getFrame(), isNull);
    });

    test('returns fresh src frame with preview size', () async {
      final now = DateTime.now();
      final source = UvcCameraSource(
        frameHub: FakeFrameHub(
          uvcFrame: jpeg(),
          uvcAt: now,
        ),
        uvcState: FakeUvcState(
          isOpened: true,
          previewWidth: 1280,
          previewHeight: 720,
        ),
      );
      final frame = await source.getFrame();
      expect(frame, isNotNull);
      expect(frame!.width, 1280);
      expect(frame.height, 720);
      expect(frame.capturedAt, now);
    });

    test('rejects already expired frame', () async {
      final source = UvcCameraSource(
        frameHub: FakeFrameHub(
          uvcFrame: jpeg(),
          uvcAt: DateTime.now().subtract(const Duration(seconds: 5)),
        ),
        uvcState: FakeUvcState(isOpened: true),
      );
      expect(await source.getFrame(), isNull);
    });
  });

  group('CameraSourceManager', () {
    CameraFrame frameOf(CameraSourceKind kind) => CameraFrame(
          bytes: jpeg(),
          capturedAt: DateTime.now(),
        );

    test('guideCane scenario prefers uvc, degrades to builtin when uvc down',
        () async {
      final builtin = FakeSource(
        kind: CameraSourceKind.builtin,
        label: '内置摄像头',
        available: true,
        frame: frameOf(CameraSourceKind.builtin),
      );
      final uvc =
          FakeSource(kind: CameraSourceKind.uvc, label: '外接 UVC 摄像头', available: true);
      final manager = CameraSourceManager(builtin: builtin, uvc: uvc);

      expect(manager.scenario, CameraScenario.guideCane);
      expect(manager.activeSource, same(uvc));

      uvc.available = false;
      expect(manager.activeSource, same(builtin), reason: '异常降级到内置');

      final frame = await manager.getFrame();
      expect(frame, isNotNull);
      expect(frame!.width, isNull);
    });

    test('phone scenario prefers builtin, degrades to uvc when builtin down',
        () {
      final builtin =
          FakeSource(kind: CameraSourceKind.builtin, label: '内置摄像头', available: true);
      final uvc = FakeSource(
        kind: CameraSourceKind.uvc,
        label: '外接 UVC 摄像头',
        available: false,
        frame: frameOf(CameraSourceKind.uvc),
      );
      final manager = CameraSourceManager(
        builtin: builtin,
        uvc: uvc,
        scenario: CameraScenario.phone,
      );
      expect(manager.activeSource, same(builtin));

      builtin.available = false;
      uvc.available = true;
      expect(manager.activeSource, same(uvc), reason: '异常降级到 UVC');

      manager.setScenario(CameraScenario.guideCane);
      expect(manager.activeSource, same(uvc), reason: '首选 UVC 已可用');
    });

    test('setScenario notifies listeners when changed', () {
      final manager = CameraSourceManager(
        builtin: FakeSource(
          kind: CameraSourceKind.builtin,
          label: '内置摄像头',
          available: true,
        ),
        uvc: FakeSource(
          kind: CameraSourceKind.uvc,
          label: '外接 UVC 摄像头',
          available: true,
        ),
      );
      var notified = 0;
      manager.addListener(() => notified++);
      manager.setScenario(CameraScenario.phone);
      manager.setScenario(CameraScenario.phone); // 无变化不通知
      expect(notified, 1);
    });
  });
}
import 'camera_source.dart';

/// 内置摄像头取帧源（手机/眼镜内嵌相机）
///
/// 复用视觉通道（[VisionWarningService]）的 YOLOViewController 抓帧，
/// 与视觉通道共享同一个相机，不额外开启第二个摄像头。
class BuiltinCameraSource implements CameraSource {
  BuiltinCameraSource(this._hub);

  final CameraFrameHub _hub;

  @override
  CameraSourceKind get kind => CameraSourceKind.builtin;

  @override
  String get label => '内置摄像头';

  @override
  bool get isAvailable => _hub.hasInternalCamera;

  @override
  Future<CameraFrame?> getFrame() async {
    if (!isAvailable) return null;
    final bytes = await _hub.grabBuiltInFrame();
    if (bytes == null || bytes.isEmpty) return null;
    return CameraFrame(bytes: bytes, capturedAt: DateTime.now());
  }
}
import 'camera_source.dart';

/// 外接 USB（UVC）摄像头取帧源（导盲杖）
///
/// 帧数据取自已提交的 [CameraFrameHub.lastUvcFrame] 缓存（视觉通道唯一缓存点），
/// 打开/故障状态来自 [UvcOpenState]。两者均为现有服务，本源不重复订阅原生帧流，
/// 避免与 UVC 视觉页抢同一 EventChannel 监听。
class UvcCameraSource implements CameraSource {
  UvcCameraSource({
    required CameraFrameHub frameHub,
    required UvcOpenState uvcState,
    this.frameMaxAge = const Duration(seconds: 2),
  })  : _hub = frameHub,
        _uvcState = uvcState;

  final CameraFrameHub _hub;
  final UvcOpenState _uvcState;

  /// 帧新鲜度：超过该时长视为画面过期，返回 null
  final Duration frameMaxAge;

  @override
  CameraSourceKind get kind => CameraSourceKind.uvc;

  @override
  String get label => '外接 UVC 摄像头';

  @override
  bool get isAvailable => _uvcState.isOpened && !_uvcState.hasFrameStallFault;

  @override
  Future<CameraFrame?> getFrame() async {
    if (!isAvailable) return null;
    final bytes = _hub.lastUvcFrame;
    final at = _hub.lastUvcFrameAt;
    if (bytes == null || at == null || bytes.isEmpty) return null;
    if (DateTime.now().difference(at) > frameMaxAge) return null;
    return CameraFrame(
      bytes: bytes,
      width: _uvcState.previewWidth,
      height: _uvcState.previewHeight,
      capturedAt: at,
    );
  }
}
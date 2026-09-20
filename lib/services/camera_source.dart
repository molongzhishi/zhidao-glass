import 'dart:typed_data';

/// 摄像头来源种类
enum CameraSourceKind { builtin, uvc }

/// 使用场景：决定首选画面源。
/// - [CameraScenario.guideCane]：导盲杖 → 外接 UVC 摄像头；
/// - [CameraScenario.phone]：手机 → 内置摄像头。
enum CameraScenario { guideCane, phone }

/// 一帧实时画面（JPEG/原始编码）
class CameraFrame {
  const CameraFrame({
    required this.bytes,
    this.width,
    this.height,
    required this.capturedAt,
  });

  /// 画面像素数据（JPEG/原始编码）
  final Uint8List bytes;

  /// 画面尺寸（未知时为 null，如内置摄像头 JPEG 仅回字节）
  final int? width;
  final int? height;

  /// 取帧时刻
  final DateTime capturedAt;

  bool get isValid => bytes.isNotEmpty;
}

/// 摄像头实时取帧统一接口。
///
/// 注意：是「摄像头实时取帧」，不是手机屏幕截屏。
abstract class CameraSource {
  CameraSourceKind get kind;

  /// 界面/调试用名称
  String get label;

  /// 当前是否可用（未打开/故障时置 false）
  bool get isAvailable;

  /// 取最新一帧画面；当前无可用帧返回 null。
  Future<CameraFrame?> getFrame();
}

/// 实时帧中枢（由 [VisionWarningService] 实现）：
/// 内置摄像头控制器抓帧 + UVC 已提交帧缓存。
abstract class CameraFrameHub {
  /// 内置摄像头控制器是否已注册且初始化
  bool get hasInternalCamera;

  /// 从内置摄像头抓一帧（JPEG），失败/无控制器返回 null
  Future<Uint8List?> grabBuiltInFrame();

  /// UVC 帧流最近一帧（经视觉通道提交缓存）
  Uint8List? get lastUvcFrame;

  /// UVC 最近一帧的到达时刻
  DateTime? get lastUvcFrameAt;
}

/// UVC 摄像头打开/故障状态（由 [UvcCameraService] 实现）
abstract class UvcOpenState {
  bool get isOpened;

  bool get hasFrameStallFault;

  int? get previewWidth;

  int? get previewHeight;
}
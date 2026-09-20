import 'package:flutter/foundation.dart';

import 'camera_source.dart';

/// 摄像头取帧调度器
///
/// 按场景决定首选画面源（导盲杖→UVC，手机→内置），运行时可 [setScenario] 切换；
/// 当前源不可用（未打开/故障）时，自动降级到可用备用源（异常降级）。
class CameraSourceManager extends ChangeNotifier {
  CameraSourceManager({
    required this.builtin,
    required this.uvc,
    CameraScenario scenario = CameraScenario.guideCane,
  }) : _scenario = scenario;

  final CameraSource builtin;
  final CameraSource uvc;

  CameraScenario _scenario;

  CameraScenario get scenario => _scenario;

  /// 场景首选源
  CameraSource get preferredSource =>
      _scenario == CameraScenario.guideCane ? uvc : builtin;

  /// 场景备用源
  CameraSource get fallbackSource =>
      _scenario == CameraScenario.guideCane ? builtin : uvc;

  /// 当前激活源：首选源不可用时自动切换/降级到备用源；
  /// 两者都不可用时仍返回首选源，由调用方对 null 帧兜底。
  CameraSource get activeSource {
    if (preferredSource.isAvailable) return preferredSource;
    if (fallbackSource.isAvailable) return fallbackSource;
    return preferredSource;
  }

  CameraSourceKind? get activeKind => activeSource.kind;
  String get activeLabel => activeSource.label;

  /// 统一取帧入口
  Future<CameraFrame?> getFrame() => activeSource.getFrame();

  void setScenario(CameraScenario value) {
    if (_scenario == value) return;
    _scenario = value;
    notifyListeners();
  }
}
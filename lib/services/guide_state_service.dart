import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 使用引导状态管理（与视觉/YOLO、摄像头等业务完全解耦）
///
/// 职责（只做状态与权限查询，绝不去实例化 YOLO、启动截屏或抓帧）：
/// 1. 记录首启引导是否已完成（持久化到 shared_preferences）；
/// 2. 只读查询"核心权限"快照：蓝牙权限组、摄像头权限、通知权限。
///
/// 权限请求统一由各专职服务/系统对话框完成，本服务不越权。
class GuideStateService extends ChangeNotifier {
  static const String completedKey = 'guide_completed_v1';

  SharedPreferences? _prefs;
  bool _ready = false;
  bool _completed = false;
  bool _bluetoothGranted = false;
  bool _cameraGranted = false;
  bool _notificationGranted = false;

  bool get isReady => _ready;
  bool get firstRunCompleted => _completed;
  bool get bluetoothGranted => _bluetoothGranted;
  bool get cameraGranted => _cameraGranted;
  bool get notificationGranted => _notificationGranted;

  /// 核心权限是否全部就绪（蓝牙 + 摄像头 + 通知）
  bool get coreGranted => _bluetoothGranted && _cameraGranted && _notificationGranted;

  /// 从本地加载首启标记（幂等，多次调用安全）
  Future<void> ensureLoaded() async {
    if (_ready) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      _completed = prefs.getBool(completedKey) ?? false;
    } catch (_) {
      // 存储异常时按"未完成"处理，引导流程仍可继续
    }
    _ready = true;
    notifyListeners();
  }

  /// 标记首启引导完成
  Future<void> completeFirstRun() async {
    _completed = true;
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      _prefs = prefs;
      await prefs.setBool(completedKey, true);
    } catch (_) {
      // 持久化失败不阻塞进入主界面
    }
    notifyListeners();
  }

  /// 刷新权限快照（仅查询，不弹窗）
  Future<void> refreshPermissions() async {
    _bluetoothGranted = await _queryBluetoothGranted();
    _cameraGranted = await _queryCameraGranted();
    _notificationGranted = await _queryNotificationGranted();
    notifyListeners();
  }

  static Future<bool> _queryBluetoothGranted() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        final statuses = await Future.wait([
          Permission.bluetooth.status,
          Permission.bluetoothConnect.status,
          Permission.bluetoothScan.status,
          Permission.location.status,
        ]);
        return statuses.every((status) => status.isGranted);
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  static Future<bool> _queryCameraGranted() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        return (await Permission.camera.status).isGranted;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  static Future<bool> _queryNotificationGranted() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        return (await Permission.notification.status).isGranted;
      } catch (_) {
        return false;
      }
    }
    return true;
  }
}
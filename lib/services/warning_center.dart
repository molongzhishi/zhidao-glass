import 'package:flutter/foundation.dart';

/// 三类互相解耦的警告来源
enum WarningSource {
  /// 雷达探测到障碍物（主触发源）
  radarObstacle,

  /// 摄像头（视觉）检测到障碍物（YOLO 判定 stop）
  cameraObstacle,

  /// USB 摄像头帧流卡死/故障
  usbCameraFault,
}

/// 警告聚合中心
///
/// 各来源各自独立维护实时状态，互不影响：
/// - 雷达障碍物：收到雷达恢复信号（RADAR:CLEAR）后自动复位；
/// - 摄像头障碍物：视觉判定离开 stop 后自动复位；
/// - USB 摄像头故障：帧流恢复/重置后自动复位。
///
/// 同时提供 [reportWarningReasons]，直接读取各来源的实时状态，
/// 以应对“为什么警告 / 什么报警”等频繁提问。
class WarningCenter extends ChangeNotifier {
  bool _radarObstacle = false;
  bool _cameraObstacle = false;
  bool _usbCameraFault = false;

  bool get radarObstacle => _radarObstacle;
  bool get cameraObstacle => _cameraObstacle;
  bool get usbCameraFault => _usbCameraFault;

  bool get hasActiveWarnings =>
      _radarObstacle || _cameraObstacle || _usbCameraFault;

  /// 当前处于报警中的来源列表（雷达优先展示）
  List<WarningSource> get activeWarningSources => [
        if (_radarObstacle) WarningSource.radarObstacle,
        if (_cameraObstacle) WarningSource.cameraObstacle,
        if (_usbCameraFault) WarningSource.usbCameraFault,
      ];

  void setRadarObstacle(bool value) {
    if (_radarObstacle == value) return;
    _radarObstacle = value;
    notifyListeners();
  }

  void setCameraObstacle(bool value) {
    if (_cameraObstacle == value) return;
    _cameraObstacle = value;
    notifyListeners();
  }

  void setUsbCameraFault(bool value) {
    if (_usbCameraFault == value) return;
    _usbCameraFault = value;
    notifyListeners();
  }

  /// 报警来源的简短名称
  static String sourceLabel(WarningSource source) {
    switch (source) {
      case WarningSource.radarObstacle:
        return '雷达：前方探测到障碍物';
      case WarningSource.cameraObstacle:
        return '摄像头：检测到障碍物';
      case WarningSource.usbCameraFault:
        return 'USB摄像头：故障';
    }
  }

  /// 报警来源的详细说明
  static String sourceDetail(WarningSource source) {
    switch (source) {
      case WarningSource.radarObstacle:
        return '雷达检测到前方存在障碍物，请小心前行';
      case WarningSource.cameraObstacle:
        return '视觉识别到前方障碍物距离过近';
      case WarningSource.usbCameraFault:
        return 'USB摄像头已连续10秒没有新的图像帧，可能发生故障';
    }
  }

  /// 实时汇总当前所有报警来源（直接读取程序实时状态）
  String reportWarningReasons() {
    final active = activeWarningSources;
    if (active.isEmpty) {
      return '当前没有激活的警告：雷达未探测到障碍物，摄像头未检测到障碍物，USB摄像头运行正常。';
    }
    if (active.length == 1) {
      final source = active.first;
      return '当前警告来源：${sourceLabel(source)}。${sourceDetail(source)}。其余来源正常。';
    }
    final list = active
        .map((s) => '${sourceLabel(s)}，${sourceDetail(s)}')
        .join('；');
    return '当前有 ${active.length} 个警告来源：$list。其余来源正常。';
  }
}
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bluetooth_receiver.dart';
import 'fusion_engine.dart';
import 'tts_service.dart';
import 'vision_alert_engine.dart';
import 'vision_warning_service.dart';
import 'voice_announcer.dart';

/// 雷达 + 视觉 双通道融合服务（薄接线层）
///
/// 职责：
/// - 订阅 [BluetoothReceiver]（雷达）与 [VisionWarningService]（视觉）的事件；
/// - 将两通道状态换算为 [FusionEngine] 可裁决的输入，按引擎裁决结果唯一播报；
/// - 播报出口统一交由 [VoiceAnnouncer]（优先/防打扰/异常降级振动），
///   测试环境回退到 [speakOverride] 或 [TtsService]。
///
/// 融合规则（在 [FusionEngine] 中实现）：
/// - 雷达有障碍 + 视觉有物品 → "[雷达方位]有[物品名]"；
/// - 雷达有障碍 + 视觉无物品 → "[雷达方位]有障碍物"；
/// - 两者都无 → 不播报；
/// - 雷达方位为主，画面坐标（视觉中心 X）为辅。
class FusionWarningService extends ChangeNotifier {
  FusionWarningService({
    required BluetoothReceiver radar,
    required VisionWarningService vision,
    this.broadcaster,
    this.ttsService,
    this.speakOverride,
    double largeItemThreshold = 0.30,
    Duration minReportGap = const Duration(milliseconds: 700),
  })  : _radar = radar,
        _vision = vision,
        _engine = FusionEngine(
          largeItemThreshold: largeItemThreshold,
          minReportGap: minReportGap,
        ) {
    // 节流耦合显式校验：雷达重复周期若小于播报层防重复窗口，
    // 周期提醒会被播报层二次节流静默截断（release 模式该 assert 不生效，
    // 需配合默认 10s 间隔使用）。
    final b = broadcaster;
    assert(
      b == null || radar.repeatInterval >= b.repeatInterval,
      '雷达重复提醒间隔(${radar.repeatInterval})应不小于播报防重复窗口'
      '(${b?.repeatInterval})，否则会被二次节流截断',
    );
    radar.onSpeech = _handleRadarSpeech;
    vision.onReport = _handleVisionReport;
  }

  final BluetoothReceiver _radar;
  final VisionWarningService _vision;
  final FusionEngine _engine;

  /// 语音播报出口（优先级排队/防打扰/振动回退由此统一处理）
  final VoiceAnnouncer? broadcaster;
  final TtsService? ttsService;

  /// 测试用播报替换：接收一串待播报文案，顺序即最终播报顺序
  final Future<void> Function(List<String> texts)? speakOverride;

  bool get radarActive => _radar.hasObstacle;
  bool get radarDegraded => _radar.isDegraded;
  VisionReport? get visionReport => _vision.lastReport;

  /// 最近一次可播报的视觉报告（供状态页展示坐标/方位）
  VisionReport? get visionItem => _visionItem;

  List<String> get lastSpokenTexts => List.unmodifiable(_lastSpokenTexts);

  VisionReport? _visionItem;
  List<String> _lastSpokenTexts = const [];
  Future<void> _speechChain = Future<void>.value();

  void _handleRadarSpeech(RadarSpeechIntent intent) {
    try {
      switch (intent.kind) {
        case RadarSpeechKind.obstacle:
          _announceIfAny(_engine.radarObstacle(_mapDirection(_radar.direction)));
          break;
        case RadarSpeechKind.clear:
        case RadarSpeechKind.disconnected:
        case RadarSpeechKind.reconnected:
          _announceIfAny(_engine.reportStatus(intent.text));
          break;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[FusionWarning] 处理雷达播报失败: $e');
    }
  }

  void _handleVisionReport(VisionReport report) {
    try {
      _visionItem = (report.hasTarget && report.text != null) ? report : null;
      final item = _visionItem == null
          ? null
          : FusionVisionItem(
              className: report.className,
              weight: report.weight,
              centerX: report.centerX,
              level: report.level,
            );
      _announceIfAny(
        _engine.setVisionItem(
          item,
          FusionRadarState(
            hasObstacle: _radar.hasObstacle,
            direction: _mapDirection(_radar.direction),
          ),
        ),
      );
      notifyListeners();
    } catch (e) {
      debugPrint('[FusionWarning] 处理视觉报告失败: $e');
    }
  }

  /// 雷达方向 → 融合引擎方位枚举
  static FusionRadarDirection _mapDirection(RadarDirection direction) =>
      switch (direction) {
        RadarDirection.left => FusionRadarDirection.left,
        RadarDirection.front => FusionRadarDirection.front,
        RadarDirection.right => FusionRadarDirection.right,
        RadarDirection.unknown => FusionRadarDirection.unknown,
      };

  void _announceIfAny(FusionAnnouncement? announcement) {
    if (announcement == null) return;
    _announce(announcement);
  }

  void _announce(FusionAnnouncement announcement) {
    _lastSpokenTexts = [announcement.text];

    debugPrint('[FusionWarning] 播报: ${announcement.text}');

    final broadcast = broadcaster;
    if (broadcast != null) {
      // 优先级排队/防打扰/振动回退统一由播报模块处理
      unawaited(broadcast.broadcast(
        announcement.priority == FusionPriority.emergency
            ? BroadcastPriority.emergency
            : BroadcastPriority.normal,
        announcement.text,
      ));
      return;
    }
    final override = speakOverride;
    if (override != null) {
      unawaited(override([announcement.text]));
      return;
    }
    final tts = ttsService;
    if (tts == null) return;
    // 回退路径：无播报模块时退化为串行 TTS 出口（测试/无原生引擎环境）
    _speechChain = _speechChain.then((_) => tts.speakSequential([announcement.text]));
  }

  /// 供测试注入一次视觉报告（等价于视觉通道的 onReport 回调）
  @visibleForTesting
  void feedVisionReport(VisionReport report) => _handleVisionReport(report);

  @override
  void dispose() {
    _speechChain = Future<void>.value();
    super.dispose();
  }
}
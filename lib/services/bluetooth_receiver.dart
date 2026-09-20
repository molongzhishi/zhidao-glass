import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bluetooth_spp_service.dart';
import 'tts_service.dart';
import 'warning_center.dart';

/// 雷达信号方向（左/右/正前/未知；未知 = 无法判定方向，仍可能是有障碍物）
enum RadarDirection { left, right, front, unknown }

/// 一次雷达信号：{hasObstacle, direction}
///
/// 由原始串口行经 [BluetoothReceiver.parse] 解析而来：
/// `RADAR:OBSTACLE [LEFT|RIGHT|FRONT]` → 有障碍物 + 方向；
/// `RADAR:CLEAR` / 中文关键词（该返回恢复）→ 无障碍物。
class RadarSignal {
  const RadarSignal({required this.hasObstacle, this.direction = RadarDirection.unknown});

  /// 是否有障碍物
  final bool hasObstacle;

  /// 障碍物方向（无方向信息时为 [RadarDirection.unknown]）
  final RadarDirection direction;
}

/// 雷达信号播报的种类
enum RadarSpeechKind {
  /// 前方探测到障碍物（可能重复上报）
  obstacle,

  /// 障碍物已清除，恢复通行
  clear,

  /// 蓝牙断连，雷达失效
  disconnected,

  /// 蓝牙重连，雷达恢复
  reconnected,
}

/// 雷达通道的一次语音播报请求
class RadarSpeechIntent {
  const RadarSpeechIntent({required this.kind, required this.text});

  final RadarSpeechKind kind;
  final String text;
}

/// 雷达信号接收通道（蓝牙）
///
/// 职责（对应需求）：
/// 1. 订阅 [BluetoothSppService.sppDataStream]，把原始行解析为
///    [RadarSignal]（{hasObstacle, direction}）；
/// 2. 检测到障碍物立即触发报警（并经 [onSpeech] 交给上层触发视觉分析）；
/// 3. 防重复：同一障碍物持续存在时，每隔 [repeatInterval] 才再次触发一次；
/// 4. 蓝牙断连 → 标记 [isDegraded]（降级为"仅视觉"），重连后恢复。
///
/// 探测本身与视觉通道（VisionWarningService）完全解耦，互不影响；
/// 语音播报通过 [onSpeech] 回调交给上层（融合服务）统一裁减，
/// 未设置时回退到 [TtsService] 直接播报，保证独立可用。
class BluetoothReceiver extends ChangeNotifier {
  BluetoothReceiver({
    required BluetoothSppService bluetoothSpp,
    required WarningCenter warningCenter,
    TtsService? ttsService,
    this.onSpeech,
    this.repeatInterval = const Duration(seconds: 10),
  })  : _bluetooth = bluetoothSpp,
        _center = warningCenter,
        _tts = ttsService;

  final BluetoothSppService _bluetooth;
  final WarningCenter _center;
  final TtsService? _tts;

  /// 语音回调。设置后本服务不再直接调用 TTS，交由上层融合服务播报。
  void Function(RadarSpeechIntent intent)? onSpeech;

  /// 同一障碍物持续存在时的重复触发间隔
  final Duration repeatInterval;

  static const String obstacleAnnouncement = '前方有障碍物';
  static const String clearAnnouncement = '前方已恢复通行';
  static const String disconnectAnnouncement =
      '蓝牙连接已断开，无法接收雷达预警，请尽快重新连接，当前仅依靠视觉检测';
  static const String reconnectAnnouncement = '蓝牙已重新连接，雷达预警已恢复';

  static final _obstacleRegex = RegExp(
    r'(障碍|危险|阻挡|入侵|接近|BLOCK|DETECT|OBSTACLE)',
    caseSensitive: false,
  );

  StreamSubscription<String>? _dataSub;
  Timer? _repeatTimer;
  bool _hasObstacle = false;
  RadarDirection _direction = RadarDirection.unknown;
  bool _degraded = false;
  bool _wasConnected = false;
  bool _sawDisconnect = false;
  bool _started = false;
  int _triggerCount = 0;
  DateTime? _lastTriggerAt;

  /// 当前是否有障碍物
  bool get hasObstacle => _hasObstacle;

  /// 当前障碍物方向
  RadarDirection get direction => _direction;

  /// 蓝牙断连降级（仅视觉）状态
  bool get isDegraded => _degraded;

  /// 本会话累计触发的次数（每次新障碍事件 +1），供状态页展示
  int get radarTriggerCount => _triggerCount;

  /// 最近一次触发的时刻
  DateTime? get lastRadarTriggerAt => _lastTriggerAt;

  String get obstacleText => switch (_direction) {
        RadarDirection.left => '前方左侧有障碍物',
        RadarDirection.right => '前方右侧有障碍物',
        RadarDirection.front => '前方正中有障碍物',
        RadarDirection.unknown => obstacleAnnouncement,
      };

  /// 把原始串口行解析为 [RadarSignal]；非雷达行返回 null。
  ///
  /// 支持：`RADAR:OBSTACLE [LEFT|RIGHT|FRONT]`、`RADAR:CLEAR/FREE/OK/SAFE/PASS`
  /// 及中文/英文关键词（障碍/危险/阻挡/恢复/无障碍物…）。
  static RadarSignal? parse(String line) {
    final raw = line.trim();
    if (raw.isEmpty) return null;
    final upper = raw.toUpperCase();

    // “无障碍物”等否定形式优先判定为恢复
    if (RegExp(r'(无障碍|无阻挡|已清除|恢复通行|安全通行|净空)').hasMatch(raw)) {
      if (!RegExp(r'(RADAR:(OBSTACLE|BLOCK|DETECT))').hasMatch(upper)) {
        return const RadarSignal(hasObstacle: false);
      }
    }

    // RADAR:<tag> 前缀优先判断
    if (upper.startsWith('RADAR:')) {
      final tag = upper.substring(6).trimLeft();
      if (RegExp(r'^(CLEAR|FREE|OK|SAFE|PASS)').hasMatch(tag)) {
        return const RadarSignal(hasObstacle: false);
      }
      if (RegExp(r'^(OBSTACLE|BLOCK|DETECT|WARN|ALARM)').hasMatch(tag)) {
        return RadarSignal(hasObstacle: true, direction: _parseDirection(raw));
      }
    }

    // 中文/英文关键词兜底
    if (RegExp(r'(恢复|通畅|CLEAR)').hasMatch(raw)) {
      if (!_obstacleRegex.hasMatch(raw)) {
        return const RadarSignal(hasObstacle: false);
      }
    }

    if (_obstacleRegex.hasMatch(raw)) {
      return RadarSignal(hasObstacle: true, direction: _parseDirection(upper));
    }

    return null;
  }

  static RadarDirection _parseDirection(String upper) {
    if (upper.contains('LEFT') || upper.contains('左')) {
      return RadarDirection.left;
    }
    if (upper.contains('RIGHT') || upper.contains('右')) {
      return RadarDirection.right;
    }
    if (RegExp(r'(FRONT|CENTER|MIDDLE|正前|前方)').hasMatch(upper)) {
      return RadarDirection.front;
    }
    return RadarDirection.unknown;
  }

  /// 启动雷达信号监听。可重复调用，内部幂等。
  Future<void> start() async {
    if (_started) return;
    _started = true;

    try {
      // 确保事件通道已建立，供 SPP 数据与断连事件路由
      await _bluetooth.init();

      _dataSub = _bluetooth.sppDataStream.listen(
        _handleLine,
        onError: (e) => debugPrint('[BluetoothReceiver] SPP 数据流错误: $e'),
      );
      _bluetooth.addListener(_onBluetoothStateChanged);
      _wasConnected = _bluetooth.isConnected;
    } catch (e) {
      debugPrint('[BluetoothReceiver] 雷达信号通道启动失败: $e');
    }
  }

  void _handleLine(String line) {
    // 断连降级后忽略雷达数据，仅剩视觉通道
    if (_degraded) return;
    final signal = parse(line);
    if (signal == null) return;
    if (signal.hasObstacle) {
      _onObstacle(signal.direction);
    } else {
      _onClear();
    }
  }

  void _onObstacle(RadarDirection direction) {
    final isNewObstacle = !_hasObstacle;
    final directionChanged = _direction != direction;
    _hasObstacle = true;
    _direction = direction;
    _center.setRadarObstacle(true);
    if (isNewObstacle || directionChanged) {
      notifyListeners();
    }

    // 防重复：仅在障碍物首次出现（或方向变化）时触发一次，
    // 后续重复帧不得重置计时器，否则高频上报将导致永不重复。
    if (isNewObstacle) {
      debugPrint('[BluetoothReceiver] 探测到障碍物: $_direction');
      _triggerCount++;
      _lastTriggerAt = DateTime.now();
      _emitSpeech(obstacleText, RadarSpeechKind.obstacle);
      _stopRepeatTimer();
      _repeatTimer = Timer.periodic(repeatInterval, (_) {
        if (_hasObstacle && !_degraded) {
          debugPrint('[BluetoothReceiver] 周期触发障碍物提醒');
          _emitSpeech(obstacleText, RadarSpeechKind.obstacle);
        }
      });
    }
  }

  void _onClear() {
    if (!_hasObstacle && _repeatTimer == null) return;
    debugPrint('[BluetoothReceiver] 障碍物已清除');
    _hasObstacle = false;
    _direction = RadarDirection.unknown;
    _stopRepeatTimer();
    _center.setRadarObstacle(false);
    notifyListeners();
    _emitSpeech(clearAnnouncement, RadarSpeechKind.clear);
  }

  /// 蓝牙连接状态变化：断连 → 降级为仅视觉通道并提示；重连 → 恢复
  void _onBluetoothStateChanged() => _applyConnectionState(_bluetooth.isConnected);

  /// 应用蓝牙连接状态变化（逻辑与 [BluetoothSppService.isConnected] 解耦，便于测试）
  void _applyConnectionState(bool connected) {
    if (connected == _wasConnected) return;
    _wasConnected = connected;

    if (connected) {
      _degraded = false;
      notifyListeners();
      if (_sawDisconnect) {
        _emitSpeech(reconnectAnnouncement, RadarSpeechKind.reconnected);
      }
      _sawDisconnect = false;
    } else {
      _sawDisconnect = true;
      _degraded = true;
      _hasObstacle = false;
      _direction = RadarDirection.unknown;
      _stopRepeatTimer();
      _center.setRadarObstacle(false);
      notifyListeners();
      _emitSpeech(disconnectAnnouncement, RadarSpeechKind.disconnected);
    }
  }

  void _stopRepeatTimer() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  void _emitSpeech(String text, RadarSpeechKind kind) {
    final sink = onSpeech;
    if (sink != null) {
      sink(RadarSpeechIntent(kind: kind, text: text));
      return;
    }
    final tts = _tts;
    if (tts != null) {
      unawaited(tts.speak(text));
    }
  }

  /// 供测试注入雷达原始行数据（等价于真实的 SPP 数据流）
  @visibleForTesting
  void feedSensorLine(String line) => _handleLine(line);

  /// 供测试直接模拟蓝牙连接状态变化（等价于真实蓝牙服务的 isConnected 变化）
  @visibleForTesting
  void simulateConnectionChange(bool connected) => _applyConnectionState(connected);

  @override
  void dispose() {
    _dataSub?.cancel();
    _bluetooth.removeListener(_onBluetoothStateChanged);
    _stopRepeatTimer();
    super.dispose();
  }
}
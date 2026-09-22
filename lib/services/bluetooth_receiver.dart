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
/// 4. 蓝牙断连 → 标记 [isDegraded]（降级为"仅视觉"），断连**不清除**
///    最后已知障碍状态（断连 ≠ 障碍消失），重连后由下一帧雷达数据同步；
/// 5. 数据健康检测：连接建立后 [initialDataTimeout] 内未收到任何雷达行 →
///    [isRadarDataMissing] 置位（提示固件未启动/链路假在线）。
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
    this.initialDataTimeout = const Duration(seconds: 10),
    this.startRetryDelay = const Duration(seconds: 3),
    this.maxStartAttempts = 5,
  })  : _bluetooth = bluetoothSpp,
        _center = warningCenter,
        _tts = ttsService;

  final BluetoothSppService _bluetooth;
  final WarningCenter _center;
  final TtsService? _tts;

  /// 语音回调。设置后本服务不再直接调用 TTS，交由上层融合服务播报。
  void Function(RadarSpeechIntent intent)? onSpeech;

  /// 同一障碍物持续存在时的重复触发间隔。
  ///
  /// 节流耦合：若上层接入了带防重复窗口的播报出口
  /// （如 VoiceAnnouncer 默认 5s），本间隔必须 **≥ 播报层防重复窗口**，
  /// 否则周期提醒会被播报层二次节流静默截断
  /// （FusionWarningService 构造期有对应 assert 校验）。
  final Duration repeatInterval;

  /// 连接建立后等待首帧雷达数据的超时；超时无数据视为雷达数据缺失
  final Duration initialDataTimeout;

  /// [start] 初始化失败后的重试间隔
  final Duration startRetryDelay;

  /// [start] 最大重试次数（超过后保持未启动，可再次手动调用 start）
  final int maxStartAttempts;

  static const String obstacleAnnouncement = '前方有障碍物';
  static const String clearAnnouncement = '前方已恢复通行';
  static const String disconnectAnnouncement =
      '蓝牙连接已断开，无法接收雷达预警，请尽快重新连接，当前仅依靠视觉检测';
  static const String reconnectAnnouncement = '蓝牙已重新连接，雷达预警已恢复';

  // 解析用正则全部静态预编译：雷达行高频到达，避免每行动态创建 RegExp 的 GC 开销
  static final _obstacleRegex = RegExp(
    r'(障碍|危险|阻挡|入侵|接近|BLOCK|DETECT|OBSTACLE)',
    caseSensitive: false,
  );
  static final _negationRegex =
      RegExp(r'(无障碍|无阻挡|已清除|恢复通行|安全通行|净空)');
  static final _clearKeywordRegex = RegExp(r'(恢复|通畅|CLEAR)');
  static final _radarClearTagRegex = RegExp(r'^(CLEAR|FREE|OK|SAFE|PASS)');
  static final _radarObstacleTagRegex = RegExp(
    r'^(OBSTACLE|BLOCK|DETECT|WARN|ALARM)',
  );
  static final _directionFrontRegex =
      RegExp(r'(FRONT|CENTER|MIDDLE|正前|前方)');

  StreamSubscription<String>? _dataSub;
  Timer? _repeatTimer;
  Timer? _startRetryTimer;
  Timer? _healthTimer;
  bool _hasObstacle = false;
  RadarDirection _direction = RadarDirection.unknown;
  bool _degraded = false;
  bool _wasConnected = false;
  bool _sawDisconnect = false;
  bool _started = false;
  int _startAttempts = 0;
  int _triggerCount = 0;
  DateTime? _lastTriggerAt;

  // 数据健康检测状态
  DateTime? _sessionConnectedAt;
  DateTime? _lastDataAt;
  bool _sawDataThisSession = false;
  bool _dataMissingNotified = false;

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

  /// 最近一次收到雷达行数据的时刻（供状态页"最近数据"展示）
  DateTime? get lastRadarDataAt => _lastDataAt;

  /// 本次连接会话内是否收到过任何雷达行
  bool get hasReceivedRadarData => _sawDataThisSession;

  /// 雷达链路健康：已连接但超过 [initialDataTimeout] 未收到任何雷达行。
  ///
  /// 仅覆盖"连接后从未收到数据"（固件未启动 / 链路假在线）；
  /// 连接中途静默无法与"雷达无事件"区分，交蓝牙链路层断链检测处理。
  bool get isRadarDataMissing =>
      !_degraded &&
      _sessionConnectedAt != null &&
      !_sawDataThisSession &&
      DateTime.now().difference(_sessionConnectedAt!) >= initialDataTimeout;

  // 与融合引擎/方位播报措辞保持一致，避免同一方位两种说法
  String get obstacleText => switch (_direction) {
        RadarDirection.left => '左侧有障碍物',
        RadarDirection.right => '右侧有障碍物',
        RadarDirection.front => '正前方有障碍物',
        RadarDirection.unknown => obstacleAnnouncement,
      };

  /// 把原始串口行解析为 [RadarSignal]；非雷达行返回 null。
  ///
  /// 支持：`RADAR:OBSTACLE [LEFT|RIGHT|FRONT]`、`RADAR:CLEAR/FREE/OK/SAFE/PASS`
  /// 及中文/英文关键词（障碍/危险/阻挡/恢复/无障碍物…）。
  ///
  /// **优先级（从高到低）**：
  /// 1. `RADAR:` 协议前缀的显式标签优先于任何关键词（含否定词），
  ///    例如 `RADAR:ALARM 净空` 仍按障碍处理（协议标签可信优先）；
  /// 2. 无协议前缀时，否定词（无障碍/已清除…）判定恢复；
  /// 3. 再按恢复/障碍关键词兜底。
  static RadarSignal? parse(String line) {
    final raw = line.trim();
    if (raw.isEmpty) return null;
    final upper = raw.toUpperCase();

    // 1. RADAR:<tag> 协议前缀优先
    if (upper.startsWith('RADAR:')) {
      final tag = upper.substring(6).trimLeft();
      if (_radarClearTagRegex.hasMatch(tag)) {
        return const RadarSignal(hasObstacle: false);
      }
      if (_radarObstacleTagRegex.hasMatch(tag)) {
        return RadarSignal(
          hasObstacle: true,
          direction: _parseDirection(upper),
        );
      }
      // 未知协议标签（如 WARMING_UP）不在此猜测，落入下方关键词兜底
    }

    // 2. “无障碍物”等否定形式优先判定为恢复
    if (_negationRegex.hasMatch(raw)) {
      return const RadarSignal(hasObstacle: false);
    }

    // 3. 中文/英文关键词兜底
    if (_clearKeywordRegex.hasMatch(raw)) {
      if (!_obstacleRegex.hasMatch(raw)) {
        return const RadarSignal(hasObstacle: false);
      }
    }

    if (_obstacleRegex.hasMatch(raw)) {
      return RadarSignal(
        hasObstacle: true,
        direction: _parseDirection(upper),
      );
    }

    return null;
  }

  static RadarDirection _parseDirection(String input) {
    // 统一大写化：RADAR: 前缀分支与关键词兜底分支传入的原始串大小写可能不同
    final upper = input.toUpperCase();
    if (upper.contains('LEFT') || upper.contains('左')) {
      return RadarDirection.left;
    }
    if (upper.contains('RIGHT') || upper.contains('右')) {
      return RadarDirection.right;
    }
    if (_directionFrontRegex.hasMatch(upper)) {
      return RadarDirection.front;
    }
    return RadarDirection.unknown;
  }

  /// 启动雷达信号监听。初始化失败会按 [startRetryDelay] 自动重试
  /// （最多 [maxStartAttempts] 次），失败后保持未启动、可再次手动调用。
  Future<void> start() async {
    if (_started) return;
    _started = true;

    try {
      // 确保事件通道已建立，供 SPP 数据与断连事件路由
      final ok = await _bluetooth.init();
      if (!ok) {
        debugPrint('[BluetoothReceiver] 蓝牙服务初始化失败，稍后自动重试');
        _started = false;
        _scheduleStartRetry();
        return;
      }
      _startAttempts = 0;

      _dataSub = _bluetooth.sppDataStream.listen(
        _handleLine,
        onError: (e) => debugPrint('[BluetoothReceiver] SPP 数据流错误: $e'),
      );
      _bluetooth.addListener(_onBluetoothStateChanged);
      _wasConnected = _bluetooth.isConnected;
      if (_wasConnected) _sessionConnectedAt ??= DateTime.now();
    } catch (e) {
      debugPrint('[BluetoothReceiver] 雷达信号通道启动失败: $e');
      _started = false;
      _scheduleStartRetry();
    }
  }

  void _scheduleStartRetry() {
    if (_startAttempts >= maxStartAttempts) {
      debugPrint('[BluetoothReceiver] 启动重试已达上限，保持未启动待手动触发');
      return;
    }
    _startRetryTimer?.cancel();
    _startRetryTimer = Timer(startRetryDelay, () {
      _startRetryTimer = null;
      _startAttempts++;
      unawaited(start());
    });
  }

  void _handleLine(String line) {
    // 先记录数据时间戳：证明链路有数据（含降级期间，用于健康统计）
    _markDataReceived();

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

  void _markDataReceived() {
    _lastDataAt = DateTime.now();
    if (_sawDataThisSession) return;
    _sawDataThisSession = true;
    if (_dataMissingNotified) {
      _dataMissingNotified = false;
      notifyListeners();
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
      _startRepeatReminder();
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
      // 新一轮会话数据健康检测：等待本会话首帧雷达数据
      _sessionConnectedAt = DateTime.now();
      _sawDataThisSession = false;
      _dataMissingNotified = false;
      _startHealthMonitor();
      notifyListeners();
      if (_sawDisconnect) {
        _emitSpeech(reconnectAnnouncement, RadarSpeechKind.reconnected);
      }
      _sawDisconnect = false;
      // 断连前若仍有障碍（保留的最后已知状态），重连后恢复周期提醒，
      // 由随后到达的雷达帧（或 RADAR:CLEAR）同步真实状态。
      if (_hasObstacle) {
        _startRepeatReminder();
      }
    } else {
      _sawDisconnect = true;
      _degraded = true;
      // 断连 ≠ 障碍清除：保留最后已知障碍状态，仅停止周期提醒与健康监控；
      // UI 以降级横幅提示雷达不可用，避免用户误以为障碍已消失。
      _stopRepeatTimer();
      _stopHealthMonitor();
      notifyListeners();
      _emitSpeech(disconnectAnnouncement, RadarSpeechKind.disconnected);
    }
  }

  /// 障碍持续期周期性重复提醒（防重复节流见 [repeatInterval] 注释）
  void _startRepeatReminder() {
    _stopRepeatTimer();
    _repeatTimer = Timer.periodic(repeatInterval, (_) {
      if (_hasObstacle && !_degraded) {
        debugPrint('[BluetoothReceiver] 周期触发障碍物提醒');
        _emitSpeech(obstacleText, RadarSpeechKind.obstacle);
      }
    });
  }

  /// 周期检查雷达数据健康状态，仅在状态翻转时通知 UI
  void _startHealthMonitor() {
    _stopHealthMonitor();
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final missing = isRadarDataMissing;
      if (missing != _dataMissingNotified) {
        _dataMissingNotified = missing;
        notifyListeners();
      }
    });
  }

  void _stopHealthMonitor() {
    _healthTimer?.cancel();
    _healthTimer = null;
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
    _stopHealthMonitor();
    _startRetryTimer?.cancel();
    _startRetryTimer = null;
    super.dispose();
  }
}
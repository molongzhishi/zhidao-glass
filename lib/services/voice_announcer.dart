import 'dart:async';

import 'package:flutter/foundation.dart';

import 'android_tts.dart';

/// 播报优先级：紧急 > 普通 > 忽略
enum BroadcastPriority {
  ignore,
  normal,
  emergency,
}

/// 语音播报（TTS）出口——防重复、紧急打断、异常降级振动
///
/// 基于 Android 原生 TextToSpeech（[AndroidTts]）做统一播报出口：
///
/// 1. 播报频率：同一内容（如相同物品）持续存在时，每隔 [repeatInterval]
///    （默认 5 秒）重复播报；
/// 2. 优先级：紧急 > 普通 > 忽略——紧急内容可打断正在播报的普通内容；
/// 3. 防打扰：同一内容在 [repeatInterval] 内（短时间）不重复播报；
/// 4. 异常处理：
///    - TTS 初始化失败 → 回退为振动提示（普通 300ms / 紧急 700ms），
///      并按 [initRetryDelay] 周期自动重启（restart）TTS 引擎；
///    - 播报过程中失败同样回退振动并触发引擎重启。
class VoiceAnnouncer extends ChangeNotifier {
  VoiceAnnouncer({
    required TtsEngine engine,
    this.repeatInterval = const Duration(seconds: 5),
    this.initRetryDelay = const Duration(seconds: 3),
    DateTime Function()? now,
  })  : _engine = engine,
        _now = now ?? DateTime.now {
    _eventSub = engine.utterances.listen(_onUtterance);
  }

  final TtsEngine _engine;
  final Duration repeatInterval;
  final Duration initRetryDelay;
  final DateTime Function() _now;

  bool _ttsReady = false;
  bool _initInFlight = false;
  int _consecutiveFailures = 0;
  bool _fallbackVibrating = false;

  bool _busy = false;
  BroadcastPriority _busyPriority = BroadcastPriority.ignore;
  String? _activeUtteranceId;
  (BroadcastPriority, String)? _pending;

  final Map<String, DateTime> _lastSpoken = {};
  final Map<String, DateTime> _lastVibrated = {};
  StreamSubscription<UtteranceEvent>? _eventSub;
  Timer? _restartTimer;

  /// 当前正在播报的文案（供状态页展示）
  String? _activeText;

  /// 最近一次尝试播报的文案（供状态页展示）
  String? _lastText;

  bool get ttsReady => _ttsReady;
  bool get isFallbackVibrating => _fallbackVibrating;
  bool get isSpeaking => _busy;
  int get consecutiveFailures => _consecutiveFailures;
  String? get currentSpeakText => _busy ? _activeText : null;
  String? get lastSpeakText => _lastText;

  /// 启动时预热：尽早初始化 TTS，缩短首次播报延迟
  Future<bool> warmUp() => _ensureReady().then((_) => _ttsReady);

  /// 提交一条播报。
  ///
  /// 返回是否被接受（进入播报或振动回退）；忽略级或重复内容返回 false。
  Future<bool> broadcast(
    BroadcastPriority priority,
    String text,
  ) async {
    if (priority == BroadcastPriority.ignore || text.isEmpty) return false;
    final now = _now();
    // 清理超出防重复窗口的旧条目，防止单内容多次出现时 Map 无界增长
    _prune(_lastSpoken, now);
    _prune(_lastVibrated, now);

    if (!_ttsReady) {
      await _ensureReady();
      if (!_ttsReady) {
        _vibrateFallback(priority, text);
        unawaited(_scheduleRestart());
        return false;
      }
    }

    final last = _lastSpoken[text];
    if (last != null && now.difference(last) < repeatInterval) {
      // 防打扰：短时间内不重复播报相同内容
      return false;
    }
    _lastSpoken[text] = now;
    unawaited(_speak(priority, text));
    return true;
  }

  /// 移除时间戳早于防重复窗口的条目（超过窗口的条目对去重已无意义）
  void _prune(Map<String, DateTime> cache, DateTime now) {
    cache.removeWhere((_, at) => now.difference(at) >= repeatInterval);
  }

  Future<void> _ensureReady() async {
    if (_ttsReady || _initInFlight) return;
    _initInFlight = true;
    try {
      final ok = await _engine.init();
      _ttsReady = ok;
      if (ok) {
        _consecutiveFailures = 0;
        _fallbackVibrating = false;
      } else {
        _consecutiveFailures++;
        _fallbackVibrating = true;
      }
      debugPrint('[VoiceAnnouncer] TTS ${ok ? "就绪" : "初始化失败"}');
      notifyListeners();
    } finally {
      _initInFlight = false;
    }
  }

  /// TTS 不可用时：按 [initRetryDelay] 周期重启引擎，直到恢复
  Future<void> _scheduleRestart() async {
    _fallbackVibrating = true;
    notifyListeners();
    _restartTimer?.cancel();
    _restartTimer = Timer(initRetryDelay, () {
      unawaited(_restartNow());
    });
  }

  Future<void> _restartNow() async {
    try {
      _ttsReady = false;
      final ok = await _engine.restart();
      _ttsReady = ok;
      if (ok) {
        _consecutiveFailures = 0;
        _fallbackVibrating = false;
      } else {
        _consecutiveFailures++;
        _fallbackVibrating = true;
        _restartTimer?.cancel();
        _restartTimer = Timer(initRetryDelay, () {
          unawaited(_restartNow());
        });
      }
      debugPrint('[VoiceAnnouncer] TTS 重启 ${ok ? "成功" : "失败，稍后重试"}');
      notifyListeners();
    } catch (e) {
      debugPrint('[VoiceAnnouncer] TTS 重启异常: $e');
    }
  }

  void _vibrateFallback(BroadcastPriority priority, String text) {
    final now = _now();
    final last = _lastVibrated[text];
    if (last != null && now.difference(last) < repeatInterval) return;
    _lastVibrated[text] = now;
    final ms = priority == BroadcastPriority.emergency ? 700 : 300;
    debugPrint('[VoiceAnnouncer] TTS 不可用，振动回退: $text');
    unawaited(_engine.vibrate(duration: Duration(milliseconds: ms)));
  }

  Future<void> _speak(BroadcastPriority priority, String text) async {
    if (_busy) {
      if (priority == BroadcastPriority.emergency &&
          priority.index > _busyPriority.index) {
        // 紧急内容打断普通播报
        debugPrint('[VoiceAnnouncer] 紧急播报打断当前播报');
        await _engine.stop();
        _busy = false;
        _busyPriority = BroadcastPriority.ignore;
        _activeUtteranceId = null;
        _pending = null;
        await _speakNow(priority, text);
        return;
      }
      // 普通内容稍后排队（仅保留更高优先级的一条）
      if (_pending == null || priority.index > _pending!.$1.index) {
        _pending = (priority, text);
      }
      return;
    }
    await _speakNow(priority, text);
  }

  Future<void> _speakNow(BroadcastPriority priority, String text) async {
    _busy = true;
    _busyPriority = priority;
    _activeUtteranceId = null;
    _activeText = text;
    _lastText = text;
    try {
      final ok = await _engine.speak(text);
      if (!ok) {
        _busy = false;
        _busyPriority = BroadcastPriority.ignore;
        _activeText = null;
        _vibrateFallback(priority, text);
        unawaited(_scheduleRestart());
        return;
      }
      notifyListeners();
    } catch (e) {
      _busy = false;
      _busyPriority = BroadcastPriority.ignore;
      _activeText = null;
      debugPrint('[VoiceAnnouncer] 播报异常: $e');
      _vibrateFallback(priority, text);
      unawaited(_scheduleRestart());
    }
  }

  void _onUtterance(UtteranceEvent event) {
    switch (event.kind) {
      case UtteranceEventKind.start:
        _activeUtteranceId = event.id;
        break;
      case UtteranceEventKind.done:
      case UtteranceEventKind.error:
        // 仅当存在由本次播报启动的、正在进行的 utterrance 才看在结束事件，
        // 避免被抢占后旧 utterance 的迟到 done 误判为当前播报结束。
        if (_activeUtteranceId == null) break;
        if (event.id != null && event.id != _activeUtteranceId) break;
        _activeUtteranceId = null;
        _finishSpeaking();
        break;
      case UtteranceEventKind.stopped:
        break;
    }
  }

  void _finishSpeaking() {
    _busy = false;
    _busyPriority = BroadcastPriority.ignore;
    _activeText = null;
    final pending = _pending;
    _pending = null;
    if (pending != null) {
      unawaited(_speakNow(pending.$1, pending.$2));
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _restartTimer?.cancel();
    _restartTimer = null;
    _eventSub?.cancel();
    _eventSub = null;
    super.dispose();
  }
}
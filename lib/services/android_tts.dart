import 'dart:async';

import 'package:flutter/services.dart';

/// 播报引擎事件
enum UtteranceEventKind {
  start,
  done,
  stopped,
  error,
}

class UtteranceEvent {
  const UtteranceEvent({required this.kind, this.id});

  final UtteranceEventKind kind;
  final String? id;
}

/// 播报引擎抽象（可注入替身便于单元测试）
abstract class TtsEngine {
  /// 初始化引擎，返回是否就绪
  Future<bool> init();

  /// 重启引擎（用于初始化失败后的恢复）
  Future<bool> restart();

  /// 播报一段文本，返回是否成功入队
  Future<bool> speak(String text);

  /// 停止当前播报
  Future<void> stop();

  /// 查询引擎当前是否就绪
  Future<bool> isReady();

  /// 振动提示（TTS 不可用时的回退）
  Future<void> vibrate({required Duration duration});

  /// 播报生命周期事件（开始/完成/停止/错误）
  Stream<UtteranceEvent> get utterances;
}

/// Android 原生 TextToSpeech 桥接 (android.speech.tts.TextToSpeech)
class AndroidTts implements TtsEngine {
  static const MethodChannel _channel =
      MethodChannel('com.banai.zhidao_app/android_tts');
  static const EventChannel _events =
      EventChannel('com.banai.zhidao_app/android_tts/events');

  final StreamController<UtteranceEvent> _utteranceController =
      StreamController<UtteranceEvent>.broadcast();

  AndroidTts() {
    _events.receiveBroadcastStream().listen((dynamic raw) {
      final event = Map<String, dynamic>.from(raw as Map);
      final kind = switch (event['event']) {
        'utterance_start' => UtteranceEventKind.start,
        'utterance_stopped' => UtteranceEventKind.stopped,
        'utterance_done' => UtteranceEventKind.done,
        'utterance_error' => UtteranceEventKind.error,
        _ => UtteranceEventKind.error,
      };
      _utteranceController.add(
        UtteranceEvent(kind: kind, id: event['id'] as String?),
      );
    });
  }

  @override
  Future<bool> init() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'init',
        {'language': 'zh-CN'},
      );
      return result?['ready'] == true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> restart() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'restart',
        {'language': 'zh-CN'},
      );
      return result?['ready'] == true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> speak(String text) async {
    try {
      final ok = await _channel
          .invokeMethod<bool>('speak', <String, dynamic>{'text': text});
      return ok == true;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // 忽略
    }
  }

  @override
  Future<bool> isReady() async {
    try {
      final ready = await _channel.invokeMethod<bool>('isReady');
      return ready == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> vibrate({required Duration duration}) async {
    try {
      await _channel.invokeMethod<void>('vibrate', {
        'duration': duration.inMilliseconds,
      });
    } catch (_) {
      // 忽略
    }
  }

  @override
  Stream<UtteranceEvent> get utterances => _utteranceController.stream;

  void dispose() {
    _utteranceController.close();
  }
}
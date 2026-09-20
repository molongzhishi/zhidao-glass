import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:multimodal_chat/services/android_tts.dart';
import 'package:multimodal_chat/services/voice_announcer.dart';

class FakeTts implements TtsEngine {
  final StreamController<UtteranceEvent> controller =
      StreamController<UtteranceEvent>.broadcast();

  bool initResult = true;
  bool restartResult = true;
  bool speakResult = true;

  /// 前 N 次 restart 返回失败，之后成功（模拟持久故障后恢复）
  int restartFailuresBeforeSuccess = 0;

  final List<String> spoken = [];
  final List<Duration> vibrations = [];
  int initCalls = 0;
  int restartCalls = 0;
  int stopCalls = 0;

  @override
  Future<bool> init() async {
    initCalls++;
    return initResult;
  }

  @override
  Future<bool> restart() async {
    restartCalls++;
    if (restartFailuresBeforeSuccess > 0) {
      restartFailuresBeforeSuccess--;
      return false;
    }
    return restartResult;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<bool> isReady() async => true;

  @override
  Future<bool> speak(String text) async {
    spoken.add(text);
    return speakResult;
  }

  @override
  Future<void> vibrate({required Duration duration}) async {
    vibrations.add(duration);
  }

  @override
  Stream<UtteranceEvent> get utterances => controller.stream;

  void emitStart([String? id]) =>
      controller.add(UtteranceEvent(kind: UtteranceEventKind.start, id: id));

  void emitDone([String? id]) =>
      controller.add(UtteranceEvent(kind: UtteranceEventKind.done, id: id));
}

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeTts engine;
  late DateTime now;
  late VoiceAnnouncer service;

  VoiceAnnouncer build({Duration interval = const Duration(seconds: 5)}) {
    service = VoiceAnnouncer(
      engine: engine,
      repeatInterval: interval,
      initRetryDelay: const Duration(milliseconds: 20),
      now: () => now,
    );
    return service;
  }

  setUp(() {
    engine = FakeTts();
    now = DateTime(2026, 1, 1, 12, 0, 0);
    build();
  });

  tearDown(() => service.dispose());

  group('VoiceAnnouncer', () {
    test('broadcast speaks text once and finishes on done', () async {
      await service.broadcast(BroadcastPriority.normal, '前方有障碍物');
      await flush();
      expect(engine.spoken, ['前方有障碍物']);
      expect(service.isSpeaking, isTrue);
      engine.emitStart('100');
      engine.emitDone('100');
      await flush();
      expect(service.isSpeaking, isFalse);
    });

    test('ignore priority never speaks', () async {
      await service.broadcast(BroadcastPriority.ignore, '忽略内容');
      await flush();
      expect(engine.spoken, isEmpty);
    });

    test('empty text never speaks', () async {
      await service.broadcast(BroadcastPriority.normal, '');
      await flush();
      expect(engine.spoken, isEmpty);
    });

    test('repeats same content only after repeatInterval', () async {
      await service.broadcast(BroadcastPriority.normal, '前方有行人');
      engine.emitStart('1');
      engine.emitDone('1');
      await flush();

      // 同一时间窗（< repeatInterval）内相同内容被防打扰丢弃
      await service.broadcast(BroadcastPriority.normal, '前方有行人');
      await flush();
      expect(engine.spoken, hasLength(1));

      // 超过 repeatInterval 后允许再次播报
      now = now.add(const Duration(seconds: 6));
      await service.broadcast(BroadcastPriority.normal, '前方有行人');
      await flush();
      expect(engine.spoken, hasLength(2));
    });

    test('different content speaks back to back', () async {
      await service.broadcast(BroadcastPriority.normal, '前方有行人');
      engine.emitStart('1');
      engine.emitDone('1');
      await flush();

      await service.broadcast(BroadcastPriority.normal, '前方有汽车');
      await flush();
      expect(engine.spoken, ['前方有行人', '前方有汽车']);
    });

    test('emergency preempts normal broadcast', () async {
      await service.broadcast(BroadcastPriority.normal, '前方有障碍物');
      await flush();
      expect(engine.spoken, ['前方有障碍物']);

      await service.broadcast(BroadcastPriority.emergency, '前方有婴儿车');
      await flush();
      expect(engine.stopCalls, 1);
      expect(engine.spoken, ['前方有障碍物', '前方有婴儿车']);
    });

    test('normal broadcast while busy is queued and plays after done',
        () async {
      await service.broadcast(BroadcastPriority.normal, '前方有障碍物');
      await flush();
      await service.broadcast(BroadcastPriority.normal, '前方有汽车');
      await flush();
      expect(engine.spoken, ['前方有障碍物']);

      engine.emitStart('100');
      engine.emitDone('100');
      await flush();
      expect(engine.spoken, ['前方有障碍物', '前方有汽车']);
    });

    test('TTS init failure falls back to vibration and retries restart',
        () async {
      engine.initResult = false;
      engine.restartResult = true;

      await service.broadcast(BroadcastPriority.normal, '前方有障碍物');
      await flush();
      expect(engine.spoken, isEmpty);
      expect(engine.vibrations, [const Duration(milliseconds: 300)]);
      expect(service.ttsReady, isFalse);
      expect(service.isFallbackVibrating, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(engine.restartCalls, greaterThanOrEqualTo(1));
      expect(service.ttsReady, isTrue);
      expect(service.isFallbackVibrating, isFalse);

      await service.broadcast(BroadcastPriority.normal, '前方有障碍物');
      await flush();
      expect(engine.spoken, ['前方有障碍物']);
    });

    test('speak failure falls back to vibration and schedules restart',
        () async {
      engine.speakResult = false;
      await service.broadcast(BroadcastPriority.normal, '前方有障碍物');
      await flush();
      expect(engine.spoken, hasLength(1));
      expect(engine.vibrations, [const Duration(milliseconds: 300)]);
      expect(service.consecutiveFailures, 0); // init 成功，仅播报失败
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(engine.restartCalls, greaterThanOrEqualTo(1));
    });

    test('emergency vibration fallback uses longer duration', () async {
      engine.initResult = false;
      engine.restartResult = false;
      await service.broadcast(BroadcastPriority.emergency, '前方有汽车');
      await flush();
      expect(engine.vibrations, [const Duration(milliseconds: 700)]);
    });

    test('restart keeps retrying until engine recovers', () async {
      engine.initResult = false;
      engine.restartFailuresBeforeSuccess = 1;

      await service.broadcast(BroadcastPriority.normal, '前方有障碍物');
      await flush();
      expect(engine.spoken, isEmpty);

      // 多次重试后引擎恢复，就绪状态为 true
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(engine.restartCalls, greaterThanOrEqualTo(2));
      expect(service.ttsReady, isTrue);
      expect(service.isFallbackVibrating, isFalse);
    });

    test('stray done from interrupted utterance does not finish new speech',
        () async {
      await service.broadcast(BroadcastPriority.normal, '前方有障碍物');
      await flush();
      engine.emitStart('100');

      await service.broadcast(BroadcastPriority.emergency, '前方有婴儿车');
      await flush();
      // 模拟被抢占的旧 utterance 迟到 done，不应触发 pending 播报
      engine.emitDone('100');
      await flush();
      expect(engine.spoken, ['前方有障碍物', '前方有婴儿车']);
      expect(service.isSpeaking, isTrue);
    });

    test('warmUp initializes engine', () async {
      engine.initResult = true;
      final ready = await service.warmUp();
      expect(ready, isTrue);
      expect(engine.initCalls, 1);
      expect(service.ttsReady, isTrue);
    });
  });
}
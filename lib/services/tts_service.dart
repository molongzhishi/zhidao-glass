import 'package:flutter_tts/flutter_tts.dart';

enum TtsState { playing, stopped, paused }

class TtsService {
  final FlutterTts _flutterTts = FlutterTts();
  TtsState _state = TtsState.stopped;
  bool _isInitialized = false;
  List<String> _availableLanguages = [];

  TtsState get state => _state;
  bool get isInitialized => _isInitialized;
  List<String> get availableLanguages => _availableLanguages;

  Future<void> init() async {
    if (_isInitialized) return;

    try {
      await _flutterTts.setLanguage('zh-CN');
      await _flutterTts.setSpeechRate(0.8);
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);

      final languages = await _flutterTts.getLanguages;
      if (languages != null) {
        _availableLanguages = List<String>.from(languages);
      }

      _flutterTts.setStartHandler(() {
        _state = TtsState.playing;
      });

      _flutterTts.setCompletionHandler(() {
        _state = TtsState.stopped;
      });

      _flutterTts.setErrorHandler((msg) {
        _state = TtsState.stopped;
      });

      _flutterTts.setCancelHandler(() {
        _state = TtsState.stopped;
      });

      _isInitialized = true;
    } catch (_) {
      _isInitialized = false;
    }
  }

  Future<void> speak(String text) async {
    if (text.isEmpty) return;
    if (!_isInitialized) await init();

    await _flutterTts.stop();
    await _flutterTts.speak(text);
    _state = TtsState.playing;
  }

  /// 超时上限，防止 [speakSequential] 在个别平台缺少完成回调时永久挂起
  final Duration speakTimeout = const Duration(seconds: 30);

  /// 按顺序逐条播报：[texts] 中相邻文案不会互相打断。
  ///
  /// 用于融合层的"先播报雷达信号，再播报视觉识别结果"分级串行播报。
  Future<void> speakSequential(List<String> texts) async {
    for (final text in texts) {
      if (text.isEmpty) continue;
      await speak(text);
      await _waitUntilStopped();
    }
  }

  Future<void> _waitUntilStopped() async {
    final deadline = DateTime.now().add(speakTimeout);
    while (_state != TtsState.stopped) {
      if (DateTime.now().isAfter(deadline)) return;
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> stop() async {
    await _flutterTts.stop();
    _state = TtsState.stopped;
  }

  Future<void> pause() async {
    await _flutterTts.pause();
    _state = TtsState.paused;
  }

  Future<void> setLanguage(String language) async {
    await _flutterTts.setLanguage(language);
  }

  Future<void> setSpeechRate(double rate) async {
    await _flutterTts.setSpeechRate(rate);
  }

  Future<void> setVolume(double volume) async {
    await _flutterTts.setVolume(volume);
  }
}
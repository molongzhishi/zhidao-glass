import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'pcm_high_pass_filter.dart';
import 'pcm_ring_buffer.dart';

typedef VoiceCallback = void Function(String text);
typedef AsrLifecycleCallback = Future<void> Function();

String _transcribeWithQwen3AsrOnnx(
  Map<String, String> paths,
  TransferableTypedData pcmData,
) {
  sherpa.initBindings();

  sherpa.OfflineRecognizer? recognizer;
  sherpa.OfflineStream? stream;
  try {
    final qwen3 = sherpa.OfflineQwen3AsrModelConfig(
      convFrontend: paths['convFrontend']!,
      encoder: paths['encoder']!,
      decoder: paths['decoder']!,
      tokenizer: paths['tokenizer']!,
      maxTotalLen: 512,
      maxNewTokens: 512,
    );
    final model = sherpa.OfflineModelConfig(
      qwen3Asr: qwen3,
      tokens: '',
      numThreads: 4,
      debug: false,
      provider: 'cpu',
    );
    recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(model: model),
    );

    final pcmBytes = pcmData.materialize().asUint8List();
    final sampleCount = pcmBytes.lengthInBytes ~/ 2;
    if (sampleCount == 0) {
      return '';
    }

    final byteData = ByteData.sublistView(pcmBytes);
    final samples = Float32List(sampleCount);
    for (var i = 0; i < sampleCount; i++) {
      samples[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
    }

    stream = recognizer.createStream();
    stream.acceptWaveform(samples: samples, sampleRate: 16000);
    recognizer.decode(stream);
    return recognizer.getResult(stream).text.trim();
  } finally {
    stream?.free();
    recognizer?.free();
  }
}

class VoiceService extends ChangeNotifier {
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audioSubscription;
  sherpa.VoiceActivityDetector? _vad;
  Future<void>? _audioStopFuture;
  bool _isListening = false;
  bool _isModelDownloaded = false;
  bool _isDownloading = false;
  bool _isRecognizing = false;
  bool _isProcessingUtterance = false;

  int _downloadProgress = 0;
  String? _errorMessage;
  VoiceCallback? _onVoiceDetected;
  AsrLifecycleCallback? _onBeforeRecognition;
  AsrLifecycleCallback? _onAfterRecognition;
  String? _modelSize;
  final _dio = Dio();
  Future<void>? _activeDownloadFuture;

  final List<int> _pcmInputBytes = [];
  int _pcmReadOffset = 0;
  final PcmRingBuffer _captureRingBuffer = PcmRingBuffer(_ringBufferBytes);
  final PcmHighPassFilter _highPassFilter = PcmHighPassFilter(
    sampleRate: _audioSampleRate,
    cutoffFrequency: _highPassCutoffFrequency,
  );
  final List<Uint8List> _utterancePcmChunks = [];
  bool _hasActiveUtterance = false;
  int _utteranceDataBytes = 0;
  int _lastSpeechDataBytes = 0;
  int _consecutiveNonSpeechSamples = 0;
  bool _vadWasDetectingSpeech = false;
  int _lastNonSpeechLogSecond = -1;

  static const int _audioSampleRate = 16000;
  static const int _frameDurationMs = 20;
  static const int _frameSamples = _audioSampleRate * _frameDurationMs ~/ 1000;
  static const int _frameBytes = _frameSamples * 2;
  static const int _preRollSamples = _audioSampleRate * 400 ~/ 1000;
  static const int _preRollBytes = _preRollSamples * 2;
  static const int _ringBufferSeconds = 5;
  static const int _ringBufferBytes = _audioSampleRate * 2 * _ringBufferSeconds;
  static const int _endpointSilenceSamples = _audioSampleRate * 3;
  static const int _postSpeechTailSamples = _audioSampleRate * 200 ~/ 1000;
  static const int _postSpeechTailBytes = _postSpeechTailSamples * 2;
  static const double _highPassCutoffFrequency = 80;

  double _noiseFloorEstimate = 0.001;
  static const double _silenceRmsThreshold = 0.002; // 静音判定阈值
  static const String _sileroVadAssetPath =
      'assets/models/silero_vad.int8.onnx';
  static const String _sileroVadFileName = 'vad/silero_vad.int8.onnx';
  static const int _sileroVadFileSize = 212860;

  static const String _modelName = 'Qwen3-ASR-1.7B INT8 ONNX';
  static const Duration _downloadConnectTimeout = Duration(seconds: 20);
  static const Duration _downloadStallTimeout = Duration(seconds: 30);
  static const String _qwenModelFolderName = 'qwen3-asr-1.7b-onnx-int8';
  static const String _qwenModelRepositoryUrl =
      'https://www.modelscope.cn/models/zengshuishui/'
      'Qwen3-ASR-onnx/resolve/master';
  static const String _qwenConvFrontendFileName =
      'model_1.7B/conv_frontend.onnx';
  static const String _qwenEncoderFileName = 'model_1.7B/encoder.int8.onnx';
  static const String _qwenDecoderFileName = 'model_1.7B/decoder.int8.onnx';
  static const String _qwenTokenizerFolderName = 'tokenizer';
  static const Map<String, int> _qwenModelFileSizes = {
    _qwenConvFrontendFileName: 48080441,
    _qwenEncoderFileName: 314222162,
    _qwenDecoderFileName: 2037458645,
    'tokenizer/merges.txt': 1671853,
    'tokenizer/tokenizer_config.json': 12487,
    'tokenizer/vocab.json': 2776833,
  };
  static const int _qwenModelTotalBytes = 2404222421;
  static const int _downloadRetryCount = 3;

  bool get isListening => _isListening;
  bool get isModelDownloaded => _isModelDownloaded;
  bool get isDownloading => _isDownloading;
  bool get isRecognizing => _isRecognizing;
  int get downloadProgress => _downloadProgress;
  String? get errorMessage => _errorMessage;
  String get modelName => _modelName;
  String? get modelSize => _modelSize;

  void configureAsrLifecycle({
    required AsrLifecycleCallback beforeRecognition,
    required AsrLifecycleCallback afterRecognition,
  }) {
    _onBeforeRecognition = beforeRecognition;
    _onAfterRecognition = afterRecognition;
  }

  Future<void> downloadModel() async {
    final isComplete = await _checkModelComplete();
    if (isComplete) {
      debugPrint('[VoiceService] 模型已完整下载，无需重复下载');
      _isModelDownloaded = true;
      await _updateModelSize();
      notifyListeners();
      return;
    }

    await _downloadModel();
  }

  Future<void> clearModelFiles() async {
    await _clearModelFiles();
    _isModelDownloaded = false;
    _modelSize = null;
    notifyListeners();
  }

  /// 检查模型文件是否完整
  Future<bool> _checkModelComplete() async {
    try {
      for (final entry in _qwenModelFileSizes.entries) {
        final file = File(await _getQwenModelPath(entry.key));
        if (!await file.exists()) {
          return false;
        }
        final size = await file.length();
        if (size != entry.value) {
          debugPrint(
            '[VoiceService] ${entry.key}大小不正确: '
            '$size != ${entry.value}',
          );
          return false;
        }
      }

      debugPrint(
        '[VoiceService] Qwen3-ASR-1.7B INT8 ONNX模型完整: '
        '${_formatFileSize(_qwenModelTotalBytes)}',
      );
      return true;
    } catch (e) {
      debugPrint('[VoiceService] 检查模型完整性失败: $e');
      return false;
    }
  }

  Future<void> init() async {
    try {
      _recorder = AudioRecorder();
      await _ensureSileroVadModel();

      final isComplete = await _checkModelComplete();
      if (isComplete) {
        debugPrint('[VoiceService] 检测到Qwen3-ASR ONNX完整模型');
        _isModelDownloaded = true;
      } else {
        _isModelDownloaded = false;
        debugPrint('[VoiceService] Qwen3-ASR模型尚未下载，等待用户在设置中下载');
      }

      await _updateModelSize();
      _errorMessage = null;
      notifyListeners();
    } catch (e) {
      _isModelDownloaded = false;
      _errorMessage =
          '初始化失败: ${e.toString().substring(0, e.toString().length > 100 ? 100 : e.toString().length)}';
      notifyListeners();
    }
  }

  Future<String> _getQwenModelPath(String fileName) async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/models/$_qwenModelFolderName/$fileName';
  }

  Future<String> _ensureSileroVadModel() async {
    final path = await _getQwenModelPath(_sileroVadFileName);
    final file = File(path);
    if (await file.exists() && await file.length() == _sileroVadFileSize) {
      return path;
    }

    await file.parent.create(recursive: true);
    final data = await rootBundle.load(_sileroVadAssetPath);
    if (data.lengthInBytes != _sileroVadFileSize) {
      throw StateError(
        'Silero VAD资源大小不正确: '
        '${data.lengthInBytes} != $_sileroVadFileSize',
      );
    }
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    return path;
  }

  Future<void> _clearModelFiles() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelDir = Directory('${appDir.path}/models/$_qwenModelFolderName');
      if (await modelDir.exists()) {
        await modelDir.delete(recursive: true);
        debugPrint('[VoiceService] 已删除Qwen3-ASR-1.7B模型目录');
      }
    } catch (e) {
      debugPrint('[VoiceService] 删除Qwen3-ASR模型失败: $e');
    }
  }

  Future<void> _downloadModel() {
    final activeDownload = _activeDownloadFuture;
    if (activeDownload != null) {
      debugPrint('[VoiceService] 已有下载任务，等待当前任务完成');
      return activeDownload;
    }

    late final Future<void> downloadTask;
    downloadTask = _performQwenDownloadModel().whenComplete(() {
      if (identical(_activeDownloadFuture, downloadTask)) {
        _activeDownloadFuture = null;
      }
    });
    _activeDownloadFuture = downloadTask;
    return downloadTask;
  }

  Future<void> _performQwenDownloadModel() async {
    _isDownloading = true;
    _downloadProgress = 0;
    _errorMessage = '正在下载Qwen3-ASR-1.7B INT8 ONNX模型...';
    notifyListeners();

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelDir = Directory('${appDir.path}/models/$_qwenModelFolderName');
      await modelDir.create(recursive: true);

      var completedBytes = 0;
      for (final entry in _qwenModelFileSizes.entries) {
        final targetFile = File('${modelDir.path}/${entry.key}');
        await targetFile.parent.create(recursive: true);
        if (await targetFile.exists() &&
            await targetFile.length() == entry.value) {
          completedBytes += entry.value;
          _setDownloadProgress(completedBytes);
          continue;
        }

        await _downloadQwenModelFile(
          fileName: entry.key,
          expectedSize: entry.value,
          targetFile: targetFile,
          completedBytes: completedBytes,
        );
        completedBytes += entry.value;
        _setDownloadProgress(completedBytes);
      }

      if (!await _checkModelComplete()) {
        throw Exception('下载完成后模型大小校验失败');
      }

      _isModelDownloaded = true;
      _downloadProgress = 100;
      _errorMessage = null;
      await _updateModelSize();
    } catch (e) {
      _isModelDownloaded = false;
      _errorMessage = '模型下载失败: $e';
      debugPrint('[VoiceService] $_errorMessage');
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  Future<void> _downloadQwenModelFile({
    required String fileName,
    required int expectedSize,
    required File targetFile,
    required int completedBytes,
  }) async {
    final partFile = File('${targetFile.path}.part');
    if (await targetFile.exists()) {
      final targetSize = await targetFile.length();
      if (targetSize != expectedSize) {
        if (targetSize < expectedSize && !await partFile.exists()) {
          await targetFile.rename(partFile.path);
        } else {
          await targetFile.delete();
        }
      }
    }
    if (await partFile.exists() && await partFile.length() > expectedSize) {
      await partFile.delete();
    }

    var failedAttempts = 0;
    while (failedAttempts < _downloadRetryCount) {
      final existingBytes = await partFile.exists()
          ? await partFile.length()
          : 0;
      _setDownloadProgress(completedBytes + existingBytes);
      _errorMessage =
          '正在下载$fileName '
          '(${failedAttempts + 1}/$_downloadRetryCount)...';
      notifyListeners();

      final cancelToken = CancelToken();
      Timer? stallTimer;
      IOSink? sink;
      var receivedBytes = existingBytes;

      void resetStallTimer() {
        stallTimer?.cancel();
        stallTimer = Timer(_downloadStallTimeout, () {
          if (!cancelToken.isCancelled) {
            cancelToken.cancel('连续30秒未收到下载数据');
          }
        });
      }

      try {
        final response = await _dio.get<ResponseBody>(
          '$_qwenModelRepositoryUrl/$fileName',
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: true,
            maxRedirects: 10,
            connectTimeout: _downloadConnectTimeout,
            receiveTimeout: _downloadStallTimeout,
            headers: existingBytes > 0
                ? {'Range': 'bytes=$existingBytes-'}
                : null,
            validateStatus: (status) =>
                status == 200 || status == 206 || status == 416,
          ),
        );

        final statusCode = response.statusCode;
        if (statusCode == 416 && existingBytes == expectedSize) {
          await _finishQwenModelFile(partFile, targetFile, expectedSize);
          return;
        }
        if (existingBytes > 0 && statusCode == 200) {
          cancelToken.cancel('服务器不支持断点续传，重新完整下载');
          await partFile.delete();
          continue;
        }
        if (statusCode != 200 && statusCode != 206) {
          throw Exception('HTTP $statusCode');
        }

        final stream = response.data?.stream;
        if (stream == null) {
          throw Exception('下载响应没有数据流');
        }

        sink = partFile.openWrite(
          mode: existingBytes > 0 ? FileMode.append : FileMode.write,
        );
        resetStallTimer();
        await for (final chunk in stream) {
          if (chunk.isEmpty) continue;
          sink.add(chunk);
          receivedBytes += chunk.length;
          if (receivedBytes > expectedSize) {
            cancelToken.cancel('下载文件大于预期大小');
            throw Exception('$fileName下载大小超过预期');
          }
          resetStallTimer();
          _setDownloadProgress(completedBytes + receivedBytes);
        }
        await sink.flush();
        await sink.close();
        sink = null;
        stallTimer?.cancel();

        await _finishQwenModelFile(partFile, targetFile, expectedSize);
        return;
      } catch (e) {
        stallTimer?.cancel();
        if (sink != null) {
          await sink.flush();
          await sink.close();
        }
        failedAttempts++;
        debugPrint(
          '[VoiceService] $fileName下载中断 '
          '$failedAttempts/$_downloadRetryCount: $e',
        );
        if (failedAttempts >= _downloadRetryCount) {
          rethrow;
        }
        _errorMessage = '$fileName下载中断，将从断点重试...';
        notifyListeners();
        await Future.delayed(Duration(seconds: failedAttempts * 2));
      } finally {
        stallTimer?.cancel();
      }
    }
  }

  Future<void> _finishQwenModelFile(
    File partFile,
    File targetFile,
    int expectedSize,
  ) async {
    if (!await partFile.exists()) {
      throw Exception('${partFile.path}不存在');
    }
    final actualSize = await partFile.length();
    if (actualSize != expectedSize) {
      throw Exception(
        '${targetFile.uri.pathSegments.last}大小不正确: '
        '$actualSize != $expectedSize',
      );
    }
    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    await partFile.rename(targetFile.path);
  }

  void _setDownloadProgress(int downloadedBytes) {
    final progress = (downloadedBytes * 100 ~/ _qwenModelTotalBytes).clamp(
      0,
      100,
    );
    if (progress != _downloadProgress) {
      _downloadProgress = progress;
      notifyListeners();
    }
  }

  Future<void> _updateModelSize() async {
    var totalBytes = 0;
    for (final fileName in _qwenModelFileSizes.keys) {
      final file = File(await _getQwenModelPath(fileName));
      if (await file.exists()) {
        totalBytes += await file.length();
      }
    }
    _modelSize = totalBytes > 0 ? _formatFileSize(totalBytes) : null;
  }

  Future<void> startListening({VoiceCallback? onVoiceDetected}) async {
    _onVoiceDetected = onVoiceDetected;

    if (!_isModelDownloaded) {
      _errorMessage = '语音模型未下载';
      notifyListeners();
      return;
    }

    if (_isListening) return;

    try {
      final activeStop = _audioStopFuture;
      if (activeStop != null) {
        await activeStop;
      }

      final permissionStatus = await Permission.microphone.request();
      if (permissionStatus != PermissionStatus.granted) {
        _errorMessage = '麦克风权限未授予';
        notifyListeners();
        return;
      }

      await _ensureSileroVadModel();
      _isListening = true;
      _errorMessage = null;
      notifyListeners();

      debugPrint(
        '[VoiceService] 开始连续语音活动检测: '
        '${_frameDurationMs}ms PCM帧，连续3秒无人声后识别',
      );
      if (!_isProcessingUtterance) {
        await _startAudioCapture();
      }
    } catch (e) {
      _errorMessage = '启动语音识别失败: ${e.toString()}';
      _isListening = false;
      notifyListeners();
    }
  }

  void pauseListening() {
    _isListening = false;
    _errorMessage = null;
    _clearVoiceBuffer();
    unawaited(_stopAudioCapture());
    notifyListeners();
    debugPrint('[VoiceService] 暂停语音识别');
  }

  void stopListening() {
    _isListening = false;
    _errorMessage = null;
    _clearVoiceBuffer();
    unawaited(_stopAudioCapture());
    notifyListeners();
    debugPrint('[VoiceService] 停止语音识别');
  }

  Future<void> _startAudioCapture() async {
    if (!_isListening || _audioSubscription != null) return;

    try {
      _recorder ??= AudioRecorder();
      final vadModelPath = await _ensureSileroVadModel();

      sherpa.initBindings();
      _vad?.free();
      _vad = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: vadModelPath,
            threshold: 0.35,
            minSilenceDuration: 0.3,
            minSpeechDuration: 0.15,
            windowSize: 512,
            maxSpeechDuration: 3600,
          ),
          sampleRate: _audioSampleRate,
          numThreads: 1,
          provider: 'cpu',
          debug: false,
        ),
        bufferSizeInSeconds: 60,
      );

      _pcmInputBytes.clear();
      _pcmReadOffset = 0;
      _captureRingBuffer.clear();
      _highPassFilter.reset();
      _utterancePcmChunks.clear();
      _hasActiveUtterance = false;
      final audioStream = await _recorder!.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _audioSampleRate,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
          streamBufferSize: _frameBytes,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceCommunication,
            audioManagerMode: AudioManagerMode.modeInCommunication,
          ),
        ),
      );

      if (!_isListening) {
        await _stopAudioCapture();
        return;
      }

      _audioSubscription = audioStream.listen(
        _handleAudioBytes,
        onError: _handleAudioStreamError,
        onDone: _handleAudioStreamDone,
        cancelOnError: true,
      );
    } catch (_) {
      await _stopAudioCapture();
      rethrow;
    }
  }

  Future<void> _stopAudioCapture() {
    final activeStop = _audioStopFuture;
    if (activeStop != null) {
      return activeStop;
    }

    late final Future<void> stopTask;
    stopTask = _performStopAudioCapture().whenComplete(() {
      if (identical(_audioStopFuture, stopTask)) {
        _audioStopFuture = null;
      }
    });
    _audioStopFuture = stopTask;
    return stopTask;
  }

  Future<void> _performStopAudioCapture() async {
    final subscription = _audioSubscription;
    _audioSubscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (e) {
        debugPrint('[VoiceService] 取消PCM录音订阅失败: $e');
      }
    }

    try {
      await _recorder?.stop();
    } catch (e) {
      debugPrint('[VoiceService] 停止PCM录音流失败: $e');
    }

    try {
      _vad?.free();
    } catch (e) {
      debugPrint('[VoiceService] 释放Silero VAD失败: $e');
    } finally {
      _vad = null;
    }
    _pcmInputBytes.clear();
    _pcmReadOffset = 0;
    _captureRingBuffer.clear();
    _highPassFilter.reset();
  }

  void _handleAudioBytes(Uint8List data) {
    if (!_isListening || _isProcessingUtterance || data.isEmpty) return;
    try {
      _pcmInputBytes.addAll(data);
      while (_pcmInputBytes.length - _pcmReadOffset >= _frameBytes &&
          !_isProcessingUtterance) {
        final frame = Uint8List.fromList(
          _pcmInputBytes.sublist(_pcmReadOffset, _pcmReadOffset + _frameBytes),
        );
        _pcmReadOffset += _frameBytes;
        _highPassFilter.processInPlace(frame);
        _processPcmFrame(frame);
      }

      if (_pcmReadOffset >= _frameBytes * 10) {
        _pcmInputBytes.removeRange(0, _pcmReadOffset);
        _pcmReadOffset = 0;
      }
    } catch (e) {
      _handleAudioStreamError(e);
    }
  }

  void _processPcmFrame(Uint8List pcmBytes) {
    final vad = _vad;
    if (vad == null) return;

    final byteData = ByteData.sublistView(pcmBytes);
    final samples = Float32List(_frameSamples);
    var sumSquares = 0.0;
    for (var i = 0; i < _frameSamples; i++) {
      final sample = byteData.getInt16(i * 2, Endian.little) / 32768.0;
      samples[i] = sample;
      sumSquares += sample * sample;
    }
    final rms = sqrt(sumSquares / _frameSamples);

    vad.acceptWaveform(samples);
    final hasSpeech = vad.isDetected();
    while (!vad.isEmpty()) {
      vad.pop();
    }

    if (hasSpeech) {
      if (!_hasActiveUtterance) {
        _beginUtterance();
      }
      _appendUtterancePcm(pcmBytes);
      _lastSpeechDataBytes = _utteranceDataBytes;
      _consecutiveNonSpeechSamples = 0;
      _lastNonSpeechLogSecond = -1;
      if (!_vadWasDetectingSpeech) {
        debugPrint('[VoiceService] VAD检测到人声，开始或继续缓存整句音频');
      }
    } else if (_hasActiveUtterance) {
      _appendUtterancePcm(pcmBytes);
      _consecutiveNonSpeechSamples += _frameSamples;
      final nonSpeechSeconds = _consecutiveNonSpeechSamples ~/ _audioSampleRate;
      if (nonSpeechSeconds > 0 && nonSpeechSeconds != _lastNonSpeechLogSecond) {
        _lastNonSpeechLogSecond = nonSpeechSeconds;
        final kind = _classifyNonSpeech(rms);
        debugPrint(
          '[VoiceService] 检测到$kind，等待句尾: '
          '$nonSpeechSeconds/3秒',
        );
      }
      if (_consecutiveNonSpeechSamples >= _endpointSilenceSamples) {
        _completeUtterance();
      }
    } else {
      _updateNoiseFloor(rms);
    }

    _captureRingBuffer.add(pcmBytes);
    _vadWasDetectingSpeech = hasSpeech;
  }

  void _beginUtterance() {
    final preRollBytes = _captureRingBuffer.tail(_preRollBytes);
    _utterancePcmChunks.clear();
    if (preRollBytes.isNotEmpty) {
      _utterancePcmChunks.add(preRollBytes);
    }

    _hasActiveUtterance = true;
    _utteranceDataBytes = preRollBytes.length;
    _lastSpeechDataBytes = 0;
    _consecutiveNonSpeechSamples = 0;
  }

  void _appendUtterancePcm(Uint8List pcmBytes) {
    if (!_hasActiveUtterance) return;
    _utterancePcmChunks.add(pcmBytes);
    _utteranceDataBytes += pcmBytes.length;
  }

  List<Uint8List> _copyPcmPrefix(List<Uint8List> chunks, int byteCount) {
    final result = <Uint8List>[];
    var remaining = byteCount;
    for (final chunk in chunks) {
      if (remaining <= 0) break;
      if (chunk.lengthInBytes <= remaining) {
        result.add(chunk);
        remaining -= chunk.lengthInBytes;
      } else {
        result.add(Uint8List.sublistView(chunk, 0, remaining));
        remaining = 0;
      }
    }
    return result;
  }

  String _classifyNonSpeech(double rms) {
    final silenceThreshold = max(
      _silenceRmsThreshold,
      _noiseFloorEstimate * 1.5,
    );
    return rms <= silenceThreshold ? '静音' : '非人声噪音';
  }

  void _updateNoiseFloor(double rms) {
    _noiseFloorEstimate = _noiseFloorEstimate * 0.98 + rms * 0.02;
  }

  void _completeUtterance() {
    if (!_hasActiveUtterance ||
        _utterancePcmChunks.isEmpty ||
        _lastSpeechDataBytes <= 0) {
      _clearVoiceBuffer();
      return;
    }

    final finalDataBytes = min(
      _utteranceDataBytes,
      _lastSpeechDataBytes + _postSpeechTailBytes,
    );
    final pcmChunks = _copyPcmPrefix(_utterancePcmChunks, finalDataBytes);
    _utterancePcmChunks.clear();
    _hasActiveUtterance = false;
    _utteranceDataBytes = 0;
    _lastSpeechDataBytes = 0;
    _consecutiveNonSpeechSamples = 0;
    _lastNonSpeechLogSecond = -1;
    _isProcessingUtterance = true;

    debugPrint('[VoiceService] 连续3秒无人声，保留200ms尾音后提交完整语句识别');
    unawaited(
      _processCompletedUtterance(
        pcmChunks: pcmChunks,
        dataBytes: finalDataBytes,
      ),
    );
  }

  Future<void> _processCompletedUtterance({
    required List<Uint8List> pcmChunks,
    required int dataBytes,
  }) async {
    try {
      await _stopAudioCapture();

      if (!_isListening) return;
      final result = await _recognizePcm(pcmChunks, dataBytes);
      if (result == null || result.isEmpty) return;

      debugPrint('[VoiceService] 识别结果: "$result"');
      _onVoiceDetected?.call(result);
    } catch (e) {
      debugPrint('[VoiceService] 完整语句识别失败: $e');
    } finally {
      pcmChunks.clear();
      _isProcessingUtterance = false;
      if (_isListening) {
        try {
          await _startAudioCapture();
        } catch (e) {
          _isListening = false;
          _errorMessage = '恢复语音检测失败: $e';
          notifyListeners();
        }
      }
    }
  }

  void _handleAudioStreamError(Object error, [StackTrace? stackTrace]) {
    debugPrint('[VoiceService] PCM录音流错误: $error');
    _isListening = false;
    _errorMessage = '语音采集失败: $error';
    _clearVoiceBuffer();
    unawaited(_stopAudioCapture());
    notifyListeners();
  }

  void _handleAudioStreamDone() {
    _audioSubscription = null;
    if (_isListening && !_isProcessingUtterance) {
      _handleAudioStreamError(StateError('PCM录音流意外结束'));
    }
  }

  void _clearVoiceBuffer() {
    _pcmInputBytes.clear();
    _pcmReadOffset = 0;
    _captureRingBuffer.clear();
    _utterancePcmChunks.clear();
    _hasActiveUtterance = false;
    _consecutiveNonSpeechSamples = 0;
    _lastNonSpeechLogSecond = -1;
    _vadWasDetectingSpeech = false;
    _utteranceDataBytes = 0;
    _lastSpeechDataBytes = 0;
  }

  Future<String?> _recognizePcm(
    List<Uint8List> pcmChunks,
    int dataBytes,
  ) async {
    if (_isRecognizing || !await _checkModelComplete()) {
      return null;
    }

    String? result;
    _isRecognizing = true;
    notifyListeners();
    bool llmWasReleased = false;
    try {
      final paths = <String, String>{
        'convFrontend': await _getQwenModelPath(_qwenConvFrontendFileName),
        'encoder': await _getQwenModelPath(_qwenEncoderFileName),
        'decoder': await _getQwenModelPath(_qwenDecoderFileName),
        'tokenizer': await _getQwenModelPath(_qwenTokenizerFolderName),
      };

      String text;
      try {
        // 第一次尝试：保留 LLM 共存，避免卸载/重载开销
        debugPrint('[VoiceService] 尝试直接 ASR 识别（保留 LLM 共存）');
        final pcmData = TransferableTypedData.fromList(pcmChunks);
        text = await Isolate.run(
          () => _transcribeWithQwen3AsrOnnx(paths, pcmData),
        );
      } catch (e) {
        // 非内存/加载类错误直接抛出
        if (!_isLikelyMemoryError(e)) rethrow;
        // 共存失败（OOM 或模型加载错误），回退到卸载 LLM 后重试
        debugPrint('[VoiceService] 共存失败，释放 LLM 后重试 ASR: $e');
        await _onBeforeRecognition?.call();
        llmWasReleased = true;
        // TransferableTypedData 已被消费，需重新构造
        final pcmDataRetry = TransferableTypedData.fromList(pcmChunks);
        debugPrint('[VoiceService] LLM 已释放，重新创建 Qwen3-ASR 识别器');
        text = await Isolate.run(
          () => _transcribeWithQwen3AsrOnnx(paths, pcmDataRetry),
        );
      }

      if (text.isEmpty) {
        debugPrint('[VoiceService] 识别结果为空，忽略');
      } else {
        result = text;
      }
    } catch (e) {
      debugPrint('[VoiceService] 识别内存PCM错误: $e');
    } finally {
      // 仅在实际卸载过 LLM 时才尝试恢复，避免无谓的重载开销
      if (llmWasReleased) {
        debugPrint('[VoiceService] ASR 期间释放过 LLM，现在恢复');
        try {
          await _onAfterRecognition?.call();
        } catch (e) {
          debugPrint('[VoiceService] LLM 恢复失败: $e');
        }
      }
      _isRecognizing = false;
      notifyListeners();
    }
    return result;
  }

  /// 判断异常是否可能为内存不足或模型加载失败，用于决定是否回退到卸载 LLM 的流程
  bool _isLikelyMemoryError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('out of memory') ||
        msg.contains('oom') ||
        msg.contains('memory') ||
        msg.contains('alloc') ||
        msg.contains('load') ||
        msg.contains('model') ||
        msg.contains('runtime') ||
        msg.contains('exception');
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  @override
  void dispose() {
    _isListening = false;
    _clearVoiceBuffer();
    unawaited(() async {
      await _stopAudioCapture();
      await _recorder?.dispose();
      _recorder = null;
    }());
    _onBeforeRecognition = null;
    _onAfterRecognition = null;
    _dio.close();
    super.dispose();
  }
}

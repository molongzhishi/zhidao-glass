import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';

class ModelDownloadService extends ChangeNotifier {
  static const String _modelFileName = 'gemma-4-E2B-it.litertlm';
  static const int _maxRetryCount = 5;
  static const int _timeoutSeconds = 600;
  static const int _minModelSize = 2 * 1024 * 1024 * 1024; // 2GB minimum
  static const String _modelVersionFile = 'model_version.json';
  static const String _latestModelVersion = 'gemma-4-E2B-it-v1'; // 最新版本号

  final List<String> _downloadUrls = [
    'https://hf-mirror.com/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    'https://mirror.ghproxy.com/https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    'https://cdn.huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
  ];

  final List<String> _downloadSourceNames = [
    'HF镜像(Gemma 4 E2B)',
    'HuggingFace(Gemma 4 E2B)',
    'GHProxy(Gemma 4 E2B)',
    'CDN(Gemma 4 E2B)',
  ];

  bool _isDownloading = false;
  int _downloadProgress = 0;
  int _downloadedBytes = 0;
  int _totalBytes = 0;
  bool _isDownloadComplete = false;
  String? _errorMessage;
  String? _modelFilePath;
  String? _modelsDirectory;
  bool _isInitialized = false;
  int _currentUrlIndex = 0;
  String? _savedModelVersion; // 已保存的版本号
  String? _lastUpdateTime;
  bool _needsUpdate = false;

  bool get isDownloading => _isDownloading;
  int get downloadProgress => _downloadProgress;
  int get downloadedBytes => _downloadedBytes;
  int get totalBytes => _totalBytes;
  bool get isDownloadComplete => _isDownloadComplete;
  String? get errorMessage => _errorMessage;
  String? get llmModelFilePath => _modelFilePath;
  bool get isInitialized => _isInitialized;
  String? get currentModelVersion => _savedModelVersion;
  String? get lastUpdateTime => _lastUpdateTime;
  bool get needsUpdate => _needsUpdate;

  Future<void> init() async {
    if (_isInitialized) {
      print('[ModelDownloadService] 已初始化，跳过');
      return;
    }

    print('[ModelDownloadService] 初始化模型下载服务...');
    
    final appDir = await getApplicationDocumentsDirectory();
    print('[ModelDownloadService] appDir.path=${appDir.path}');
    _modelsDirectory = '${appDir.path}/models';
    _modelFilePath = '$_modelsDirectory/$_modelFileName';
    print('[ModelDownloadService] _modelFilePath=$_modelFilePath');

    await _checkExistingModels();
    _isInitialized = true;
    
    if (_isDownloadComplete) {
      debugPrint('[ModelDownloadService] ✅ LLM模型已存在且完整，无需下载');
      _loadModelVersionInfo();
    } else {
      debugPrint('[ModelDownloadService] ❌ LLM模型未下载或不完整');
    }
    
    notifyListeners();
  }

  /// 检查现有模型文件，验证完整性
  Future<void> _checkExistingModels() async {
    final modelFile = File(_modelFilePath!);
    final versionFile = File('$_modelsDirectory/$_modelVersionFile');

    // 检查模型文件是否存在
    if (!await modelFile.exists()) {
      debugPrint('[ModelDownloadService] 模型文件不存在');
      _isDownloadComplete = false;
      return;
    }

    // 检查文件大小
    final modelSize = await modelFile.length();
    debugPrint('[ModelDownloadService] 模型文件大小: ${(modelSize / 1024 / 1024).toStringAsFixed(1)}MB');

    if (modelSize < _minModelSize) {
      debugPrint('[ModelDownloadService] 模型文件过小，可能不完整，需要重新下载');
      await modelFile.delete();
      _isDownloadComplete = false;
      return;
    }

    // 检查版本信息
    if (await versionFile.exists()) {
      try {
        final versionContent = await versionFile.readAsString();
        final versionInfo = jsonDecode(versionContent) as Map<String, dynamic>;
        final savedVersion = versionInfo['version'] as String?;
        _lastUpdateTime = versionInfo['updateTime'] as String?;
        _savedModelVersion = savedVersion;
        
        if (savedVersion == _latestModelVersion) {
          _needsUpdate = false;
          debugPrint('[ModelDownloadService] ✅ 版本匹配: $savedVersion');
        } else {
          _needsUpdate = true;
          debugPrint('[ModelDownloadService] ⚠️ 版本需要更新: $savedVersion -> $_latestModelVersion');
        }
      } catch (e) {
        debugPrint('[ModelDownloadService] 读取版本信息失败: $e');
      }
    } else {
      // 没有版本文件，需要记录当前版本
      _savedModelVersion = _latestModelVersion;
      await _saveModelVersionInfo();
    }

    _isDownloadComplete = true;
  }

  /// 保存模型版本信息
  Future<void> _saveModelVersionInfo() async {
    try {
      final versionFile = File('$_modelsDirectory/$_modelVersionFile');
      final versionInfo = {
        'version': _latestModelVersion,
        'updateTime': DateTime.now().toIso8601String(),
        'fileName': _modelFileName,
      };
      await versionFile.writeAsString(jsonEncode(versionInfo));
      _savedModelVersion = _latestModelVersion;
      debugPrint('[ModelDownloadService] 版本信息已保存');
    } catch (e) {
      debugPrint('[ModelDownloadService] 保存版本信息失败: $e');
    }
  }

  /// 加载版本信息
  void _loadModelVersionInfo() {
    try {
      final versionFile = File('$_modelsDirectory/$_modelVersionFile');
      if (versionFile.existsSync()) {
        final content = versionFile.readAsStringSync();
        final info = jsonDecode(content) as Map<String, dynamic>;
        _savedModelVersion = info['version'] as String?;
        _lastUpdateTime = info['updateTime'] as String?;
      }
    } catch (e) {
      debugPrint('[ModelDownloadService] 加载版本信息失败: $e');
    }
  }

  Future<bool> isModelDownloaded() async {
    print('[ModelDownloadService] isModelDownloaded: _modelFilePath=$_modelFilePath, _isInitialized=$_isInitialized');
    if (_modelFilePath == null) {
      print('[ModelDownloadService] _modelFilePath is null');
      return false;
    }
    final modelExists = await File(_modelFilePath!).exists();
    print('[ModelDownloadService] modelExists=$modelExists path=$_modelFilePath');
    if (!modelExists) return false;
    final modelSize = await File(_modelFilePath!).length();
    print('[ModelDownloadService] modelSize=$modelSize, _minModelSize=$_minModelSize');
    return modelSize >= _minModelSize;
  }

  /// 下载模型（仅在需要时执行）
  Future<void> downloadModel({bool force = false}) async {
    if (_isDownloading) return;
    
    if (!_isInitialized) await init();
    
    // 如果模型已完整下载且不需要更新，跳过下载
    if (!force && _isDownloadComplete && !_needsUpdate) {
      debugPrint('[ModelDownloadService] ✅ 模型已是最新，无需下载');
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
      _downloadedBytes = 0;
      _totalBytes = 0;
      _errorMessage = null;
      _currentUrlIndex = 0;
    });

    final dir = Directory(_modelsDirectory!);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    for (int attempt = 1; attempt <= _maxRetryCount; attempt++) {
      try {
        await _downloadSingleFile(
          _downloadUrls[_currentUrlIndex],
          _modelFileName,
          '语言模型',
        );
        await _verifyDownload();
        await _saveModelVersionInfo();
        
        setState(() {
          _isDownloading = false;
          _isDownloadComplete = true;
          _needsUpdate = false;
          _errorMessage = null;
        });
        return;
      } catch (e) {
        setState(() {
          _errorMessage =
              '下载失败 (尝试 $attempt/$_maxRetryCount): ${e.toString().substring(0, e.toString().length > 100 ? 100 : e.toString().length)}';
        });

        if (_currentUrlIndex < _downloadUrls.length - 1) {
          _currentUrlIndex++;
          setState(() {
            _errorMessage = '切换下载源...';
          });
          continue;
        }

        if (attempt == _maxRetryCount) {
          setState(() {
            _isDownloading = false;
          });
          rethrow;
        }

        setState(() {
          _errorMessage = '等待重试...';
        });
        await Future.delayed(Duration(seconds: attempt * 3));
      }
    }
  }

  Future<void> _downloadSingleFile(
    String url,
    String fileName,
    String fileDesc,
  ) async {
    final dio = Dio();
    dio.options.connectTimeout = Duration(seconds: _timeoutSeconds);
    dio.options.receiveTimeout = Duration(seconds: _timeoutSeconds);

    final filePath = '$_modelsDirectory/$fileName';
    final tempFilePath = '$filePath.tmp';

    setState(() {
      _errorMessage =
          '正在从 ${_downloadSourceNames[_currentUrlIndex]} 下载 $fileDesc...';
    });

    int? existingLength;
    final tempFile = File(tempFilePath);
    if (await tempFile.exists()) {
      existingLength = await tempFile.length();
    }

    final headers = <String, dynamic>{};
    if (existingLength != null && existingLength > 0) {
      headers['Range'] = 'bytes=$existingLength-';
    }

    int fileDownloaded = existingLength ?? 0;

    await dio.download(
      url,
      tempFilePath,
      options: Options(headers: headers),
      onReceiveProgress: (received, total) {
        fileDownloaded = existingLength != null
            ? received + existingLength
            : received;
        final _ = existingLength != null ? total + existingLength : total;

        setState(() {
          _downloadedBytes = fileDownloaded;
          _totalBytes = total > 0 ? total : 2400 * 1024 * 1024;
          _downloadProgress = ((_downloadedBytes / _totalBytes) * 100)
              .toInt();
        });
      },
    );

    final file = File(tempFilePath);
    await file.rename(filePath);
  }

  Future<void> _verifyDownload() async {
    final modelFile = File(_modelFilePath!);

    if (!await modelFile.exists()) {
      throw Exception('模型文件不存在');
    }

    final modelSize = await modelFile.length();

    if (modelSize < _minModelSize) {
      await modelFile.delete();
      throw Exception(
        '模型文件大小异常，应为约2.4GB+，实际为 ${(modelSize / 1024 / 1024).toStringAsFixed(1)}MB',
      );
    }
    
    debugPrint('[ModelDownloadService] ✅ 模型验证通过: ${(modelSize / 1024 / 1024).toStringAsFixed(1)}MB');
  }

  /// 检查并更新模型（如需要）
  Future<bool> checkForUpdate() async {
    if (!_isInitialized) await init();
    await _checkExistingModels();
    return _needsUpdate;
  }

  void reset() {
    _isDownloading = false;
    _downloadProgress = 0;
    _downloadedBytes = 0;
    _totalBytes = 0;
    _errorMessage = null;
    _currentUrlIndex = 0;
    notifyListeners();
  }

  Future<void> clearCache() async {
    if (!_isInitialized) await init();

    try {
      final modelFile = File(_modelFilePath!);
      if (await modelFile.exists()) {
        await modelFile.delete();
      }

      final tempFile = File('${_modelFilePath!}.tmp');
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      
      final versionFile = File('$_modelsDirectory/$_modelVersionFile');
      if (await versionFile.exists()) {
        await versionFile.delete();
      }

      setState(() {
        _isDownloadComplete = false;
        _needsUpdate = false;
        _savedModelVersion = null;
        _lastUpdateTime = null;
        _errorMessage = null;
      });
    } catch (e) {
      setState(() {
        _errorMessage = '清理失败: ${e.toString()}';
      });
    }
  }

  void setState(VoidCallback fn) {
    fn();
    notifyListeners();
  }
}
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

class InferenceService extends ChangeNotifier {
  InferenceModel? _model;
  InferenceChat? _chat;
  bool _isModelLoaded = false;
  bool _isLoading = false;
  String? _errorMessage;
  bool _isGenerating = false;
  String? _modelPath;
  String? _modelName;
  String? _modelSize;
  Future<void>? _loadFuture;
  Future<void>? _unloadFuture;
  Completer<void>? _generationDone;

  bool get isModelLoaded => _isModelLoaded;
  bool get isLoading => _isLoading;
  bool get isGenerating => _isGenerating;
  String? get errorMessage => _errorMessage;
  String? get modelPath => _modelPath;
  String? get modelName => _modelName;
  String? get modelSize => _modelSize;

  Future<void> loadModel(String llmModelPath) {
    if (_isModelLoaded && _unloadFuture == null) {
      return Future.value();
    }
    final activeLoad = _loadFuture;
    if (activeLoad != null) {
      return activeLoad;
    }

    late final Future<void> loadTask;
    loadTask = _performLoadModel(llmModelPath).whenComplete(() {
      if (identical(_loadFuture, loadTask)) {
        _loadFuture = null;
      }
    });
    _loadFuture = loadTask;
    return loadTask;
  }

  Future<void> _performLoadModel(String llmModelPath) async {
    final activeUnload = _unloadFuture;
    if (activeUnload != null) {
      await activeUnload;
    }
    if (_isModelLoaded) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _modelPath = llmModelPath;
      _modelName = llmModelPath.split('/').last;
    });

    try {
      await FlutterGemma.initialize();

      final modelType = _detectModelType(llmModelPath);

      await FlutterGemma.installModel(
        modelType: modelType,
        fileType: ModelFileType.litertlm,
      ).fromFile(llmModelPath).install();

      _model = await FlutterGemma.getActiveModel(
        maxTokens: 2048,
        supportImage: true,
      );

      _chat = await _model!.createChat(
        temperature: 0.7,
        randomSeed: 1,
        topK: 1,
        supportImage: true,
        modelType: modelType,
        systemInstruction:
            '你是应用内智能助手。当用户请求执行操作时，必须输出JSON格式工具调用。\n可用工具：\n- openSettings: 打开设置页面\n- clearChatHistory: 清除聊天记录\n- getAppStatus: 获取应用状态\n- getWarningReasons: 获取当前激活的警告来源及原因（雷达障碍物/摄像头检测到障碍物/USB摄像头故障），当用户问到报警或警告原因时调用\n- startImageAnalysis: 打开摄像头拍照分析\n- startYoloVision: 打开YOLO26实时视觉页面（内置摄像头），进行离线目标检测与障碍物探测\n- startUvcVision: 打开USB摄像头（UVC）实时视觉页面（外接USB摄像头，连接后进行离线目标检测）\n- toggleUvcVision: 切换USB摄像头视觉开关\n- resetUvcCamera: 重置USB摄像头，关闭并重新打开同一设备和图像帧流。故障询问后仅在用户明确同意时调用\n- toggleVoiceInput: 切换语音输入\n- downloadModel: 下载模型\n- reloadModel: 重新加载模型\n\n输出格式示例：\n用户：打开设置\n助手：{"tool":"openSettings","args":{}}\n\n用户：拍照分析\n助手：{"tool":"startImageAnalysis","args":{}}\n\n用户：打开YOLO视觉\n助手：{"tool":"startYoloVision","args":{}}\n\n用户：重置USB摄像头\n助手：{"tool":"resetUvcCamera","args":{}}\n\n用户：清除聊天记录\n助手：{"tool":"clearChatHistory","args":{}}\n\n用户：获取状态\n助手：{"tool":"getAppStatus","args":{}}\n\n用户：你好\n助手：你好！我是你的本地AI助手。\n\n请严格按照上述格式输出，不需要任何额外文字解释。',
      );

      await _updateModelSize(llmModelPath);

      setState(() {
        _isModelLoaded = true;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage =
            '加载模型失败: ${e.toString().substring(0, e.toString().length > 100 ? 100 : e.toString().length)}';
        _isLoading = false;
      });
      rethrow;
    }
  }

  ModelType _detectModelType(String modelPath) {
    final fileName = modelPath.toLowerCase();
    if (fileName.contains('gemma-4') || fileName.contains('gemma4')) {
      return ModelType.gemma4;
    } else if (fileName.contains('gemma')) {
      return ModelType.gemmaIt;
    } else if (fileName.contains('qwen3')) {
      return ModelType.qwen3;
    } else if (fileName.contains('qwen')) {
      return ModelType.qwen;
    } else if (fileName.contains('deepseek')) {
      return ModelType.deepSeek;
    } else if (fileName.contains('llama')) {
      return ModelType.llama;
    }
    return ModelType.general;
  }

  Future<void> _updateModelSize(String modelPath) async {
    final file = File(modelPath);
    if (await file.exists()) {
      final size = await file.length();
      _modelSize = _formatFileSize(size);
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  Future<InferenceResponse> generateWithTools(
    String prompt, {
    String? imagePath,
  }) async {
    if (!_isModelLoaded || _model == null || _chat == null) {
      throw Exception('模型未加载');
    }

    setState(() {
      _isGenerating = true;
    });
    final generationDone = Completer<void>();
    _generationDone = generationDone;

    try {
      if (imagePath != null && await File(imagePath).exists()) {
        final imageBytes = await File(imagePath).readAsBytes();
        await _chat!.addQuery(
          Message.withImage(text: prompt, imageBytes: imageBytes, isUser: true),
        );
      } else {
        await _chat!.addQuery(Message.text(text: prompt, isUser: true));
      }

      final response = await _chat!.generateChatResponse();

      debugPrint('[InferenceService] Response type: ${response.runtimeType}');
      debugPrint('[InferenceService] Response: $response');

      String? textResponse;
      if (response is TextResponse) {
        textResponse = response.token.isNotEmpty
            ? response.token
            : '抱歉，我无法回答这个问题。';
        debugPrint('[InferenceService] Text response: $textResponse');
      }

      if (textResponse != null) {
        final toolCall = _parseToolCall(textResponse);
        if (toolCall != null) {
          debugPrint(
            '[InferenceService] Parsed tool call: ${toolCall.name}, args: ${toolCall.args}',
          );
          return InferenceResponse(
            type: InferenceResponseType.toolCall,
            toolName: toolCall.name,
            toolArgs: toolCall.args,
          );
        }

        final fallbackToolCall = _parseToolCallByKeywords(prompt);
        if (fallbackToolCall != null) {
          debugPrint(
            '[InferenceService] Keyword fallback tool call: ${fallbackToolCall.name}, args: ${fallbackToolCall.args}',
          );
          return InferenceResponse(
            type: InferenceResponseType.toolCall,
            toolName: fallbackToolCall.name,
            toolArgs: fallbackToolCall.args,
          );
        }
      }

      return InferenceResponse(
        type: InferenceResponseType.text,
        text: textResponse ?? '抱歉，我无法回答这个问题。',
      );
    } catch (e) {
      setState(() {
        _errorMessage =
            '推理失败: ${e.toString().substring(0, e.toString().length > 100 ? 100 : e.toString().length)}';
      });
      rethrow;
    } finally {
      setState(() {
        _isGenerating = false;
      });
      if (!generationDone.isCompleted) {
        generationDone.complete();
      }
      if (identical(_generationDone, generationDone)) {
        _generationDone = null;
      }
    }
  }

  ToolCallData? _parseToolCall(String response) {
    try {
      String cleanedResponse = response;

      cleanedResponse = cleanedResponse.replaceAll(RegExp(r'```json\s*'), '');
      cleanedResponse = cleanedResponse.replaceAll(RegExp(r'\s*```'), '');
      cleanedResponse = cleanedResponse.trim();

      debugPrint('[InferenceService] Cleaned response: "$cleanedResponse"');

      if (cleanedResponse.startsWith('{') && cleanedResponse.endsWith('}')) {
        final Map<String, dynamic> jsonData =
            (jsonDecode(cleanedResponse) as Map).cast<String, dynamic>();
        if (jsonData.containsKey('tool')) {
          final toolName = jsonData['tool'] as String;
          final args = jsonData.containsKey('args') && jsonData['args'] is Map
              ? (jsonData['args'] as Map).cast<String, dynamic>()
              : <String, dynamic>{};
          return ToolCallData(name: toolName, args: args);
        }
      }

      final jsonMatch = RegExp(
        r'\{[\s\S]*?"tool"\s*:\s*"[^"]+"[\s\S]*?\}',
      ).firstMatch(response);
      if (jsonMatch != null) {
        final jsonString = jsonMatch.group(0)!;
        debugPrint('[InferenceService] Found JSON via regex: $jsonString');
        final Map<String, dynamic> jsonData = (jsonDecode(jsonString) as Map)
            .cast<String, dynamic>();
        if (jsonData.containsKey('tool')) {
          final toolName = jsonData['tool'] as String;
          final args = jsonData.containsKey('args') && jsonData['args'] is Map
              ? (jsonData['args'] as Map).cast<String, dynamic>()
              : <String, dynamic>{};
          return ToolCallData(name: toolName, args: args);
        }
      }
    } catch (e) {
      debugPrint('[InferenceService] Failed to parse tool call: $e');
    }
    return null;
  }

  ToolCallData? _parseToolCallByKeywords(String prompt) {
    final lowerPrompt = prompt.toLowerCase();

    final resetUvcCamera = RegExp(
      r'((重置|重启|重新连接|恢复).*(usb|uvc|外接|外部).*(摄像头|相机))|'
      r'((usb|uvc|外接|外部).*(摄像头|相机).*(重置|重启|重新连接|恢复))',
      caseSensitive: false,
    );
    if (resetUvcCamera.hasMatch(lowerPrompt)) {
      debugPrint('[InferenceService] USB camera reset keyword matched');
      return const ToolCallData(name: 'resetUvcCamera', args: {});
    }

    final keywordMap = {
      r'(usb|uvc|外接摄像头|usb摄像头|外接相机|外部摄像头)': 'startUvcVision',
      r'(yolo|实时视觉|视觉指导|目标检测|障碍物探测)': 'startYoloVision',
      r'(拍照|分析|扫描|相机|照片|识别|看看)': 'startImageAnalysis',
      r'(设置|偏好|配置|选项)': 'openSettings',
      r'(清除|清空|删除|重置)': 'clearChatHistory',
      r'(状态|信息|情况|检查)': 'getAppStatus',
      r'(语音|麦克风|说话)': 'toggleVoiceInput',
      r'(下载模型|更新模型)': 'downloadModel',
      r'(重新加载|重载|刷新模型)': 'reloadModel',
    };

    for (final entry in keywordMap.entries) {
      if (RegExp(entry.key).hasMatch(lowerPrompt)) {
        debugPrint(
          '[InferenceService] Keyword matched: ${entry.key} → ${entry.value}',
        );
        return ToolCallData(name: entry.value, args: {});
      }
    }

    return null;
  }

  Future<String> generate(String prompt, {String? imagePath}) async {
    if (!_isModelLoaded || _model == null || _chat == null) {
      throw Exception('模型未加载');
    }

    setState(() {
      _isGenerating = true;
    });
    final generationDone = Completer<void>();
    _generationDone = generationDone;

    try {
      if (imagePath != null && await File(imagePath).exists()) {
        final imageBytes = await File(imagePath).readAsBytes();
        await _chat!.addQuery(
          Message.withImage(text: prompt, imageBytes: imageBytes, isUser: true),
        );
      } else {
        await _chat!.addQuery(Message.text(text: prompt, isUser: true));
      }

      final response = await _chat!.generateChatResponse();
      if (response is TextResponse) {
        return response.token.isNotEmpty ? response.token : '抱歉，我无法回答这个问题。';
      }
      return '抱歉，我无法回答这个问题。';
    } catch (e) {
      setState(() {
        _errorMessage =
            '推理失败: ${e.toString().substring(0, e.toString().length > 100 ? 100 : e.toString().length)}';
      });
      rethrow;
    } finally {
      setState(() {
        _isGenerating = false;
      });
      if (!generationDone.isCompleted) {
        generationDone.complete();
      }
      if (identical(_generationDone, generationDone)) {
        _generationDone = null;
      }
    }
  }

  Stream<String> generateStream(String prompt, {String? imagePath}) async* {
    if (!_isModelLoaded || _model == null || _chat == null) {
      throw Exception('模型未加载');
    }

    setState(() {
      _isGenerating = true;
    });
    final generationDone = Completer<void>();
    _generationDone = generationDone;

    try {
      if (imagePath != null && await File(imagePath).exists()) {
        final imageBytes = await File(imagePath).readAsBytes();
        await _chat!.addQuery(
          Message.withImage(text: prompt, imageBytes: imageBytes, isUser: true),
        );
      } else {
        await _chat!.addQuery(Message.text(text: prompt, isUser: true));
      }

      await for (final chunk in _chat!.generateChatResponseAsync()) {
        if (chunk is TextResponse) {
          yield chunk.token;
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage =
            '推理失败: ${e.toString().substring(0, e.toString().length > 100 ? 100 : e.toString().length)}';
      });
      rethrow;
    } finally {
      setState(() {
        _isGenerating = false;
      });
      if (!generationDone.isCompleted) {
        generationDone.complete();
      }
      if (identical(_generationDone, generationDone)) {
        _generationDone = null;
      }
    }
  }

  /// 流式工具调用推理。先嗅探响应首字符：以 `{` 开头判定为工具调用缓冲模式；
  /// 否则按文本逐 token 推送给 UI。流结束后再尝试解析工具调用 JSON。
  Stream<InferenceStreamEvent> generateWithToolsStream(
    String prompt, {
    String? imagePath,
  }) async* {
    if (!_isModelLoaded || _model == null || _chat == null) {
      throw Exception('模型未加载');
    }

    setState(() {
      _isGenerating = true;
    });
    final generationDone = Completer<void>();
    _generationDone = generationDone;

    try {
      if (imagePath != null && await File(imagePath).exists()) {
        final imageBytes = await File(imagePath).readAsBytes();
        await _chat!.addQuery(
          Message.withImage(text: prompt, imageBytes: imageBytes, isUser: true),
        );
      } else {
        await _chat!.addQuery(Message.text(text: prompt, isUser: true));
      }

      final buffer = StringBuffer();
      var decided = false;
      var isToolCallMode = false;

      await for (final chunk in _chat!.generateChatResponseAsync()) {
        if (chunk is! TextResponse) continue;
        final token = chunk.token;
        if (token.isEmpty) continue;
        buffer.write(token);

        if (!decided) {
          // 去除前导空白与可能的 ```json 代码块标记后判定模式
          final cleaned = buffer
              .toString()
              .replaceAll(RegExp(r'^```json\s*'), '')
              .trimLeft();
          if (cleaned.isNotEmpty) {
            if (cleaned.startsWith('{')) {
              isToolCallMode = true;
            } else {
              // 文本模式：把已累积内容一次性推送给 UI
              yield InferenceStreamEvent.text(buffer.toString());
              buffer.clear();
            }
            decided = true;
          }
        } else if (!isToolCallMode) {
          // 文本模式：直接推送 token
          yield InferenceStreamEvent.text(token);
          buffer.clear();
        }
        // 工具调用模式：继续缓冲，不推送
      }

      if (isToolCallMode) {
        final fullText = buffer.toString();
        buffer.clear();
        final toolCall = _parseToolCall(fullText);
        if (toolCall != null) {
          yield InferenceStreamEvent.toolCall(toolCall);
        } else {
          // 不是有效工具调用 JSON，回退关键词匹配；仍无命中则作为文本返回
          final fallback = _parseToolCallByKeywords(prompt);
          if (fallback != null) {
            yield InferenceStreamEvent.toolCall(fallback);
          } else {
            yield InferenceStreamEvent.text(fullText);
          }
        }
      } else if (buffer.isNotEmpty) {
        // 流结束前残留的尾部文本
        yield InferenceStreamEvent.text(buffer.toString());
        buffer.clear();
      }
      yield InferenceStreamEvent.done;
    } catch (e) {
      setState(() {
        _errorMessage =
            '推理失败: ${e.toString().substring(0, e.toString().length > 100 ? 100 : e.toString().length)}';
      });
      rethrow;
    } finally {
      setState(() {
        _isGenerating = false;
      });
      if (!generationDone.isCompleted) {
        generationDone.complete();
      }
      if (identical(_generationDone, generationDone)) {
        _generationDone = null;
      }
    }
  }

  Future<void> unloadModel() {
    final activeUnload = _unloadFuture;
    if (activeUnload != null) {
      return activeUnload;
    }

    late final Future<void> unloadTask;
    unloadTask = _performUnloadModel().whenComplete(() {
      if (identical(_unloadFuture, unloadTask)) {
        _unloadFuture = null;
      }
    });
    _unloadFuture = unloadTask;
    return unloadTask;
  }

  Future<void> _performUnloadModel() async {
    final activeLoad = _loadFuture;
    if (activeLoad != null) {
      try {
        await activeLoad;
      } catch (_) {
        // Continue closing any partially-created native resources.
      }
    }

    final generationDone = _generationDone;
    if (_isGenerating) {
      try {
        await _chat?.stopGeneration();
      } catch (e) {
        debugPrint('[InferenceService] 停止Gemma生成失败: $e');
      }
      if (generationDone != null && !generationDone.isCompleted) {
        try {
          await generationDone.future.timeout(const Duration(seconds: 10));
        } on TimeoutException {
          debugPrint('[InferenceService] 等待Gemma停止生成超时，继续释放模型');
        }
      }
    }

    final chat = _chat;
    final model = _model;
    _chat = null;
    _model = null;
    setState(() {
      _isModelLoaded = false;
      _isGenerating = false;
    });

    try {
      await chat?.close();
    } finally {
      await model?.close();
    }
    debugPrint('[InferenceService] Gemma Chat和Model已完整释放');
  }

  void setState(VoidCallback fn) {
    fn();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(unloadModel());
    super.dispose();
  }
}

enum InferenceResponseType { text, toolCall, parallelToolCall }

class ToolCallData {
  final String name;
  final Map<String, dynamic> args;

  const ToolCallData({required this.name, required this.args});
}

class InferenceResponse {
  final InferenceResponseType type;
  final String? text;
  final String? toolName;
  final Map<String, dynamic>? toolArgs;
  final List<ToolCallData>? toolCalls;

  const InferenceResponse({
    required this.type,
    this.text,
    this.toolName,
    this.toolArgs,
    this.toolCalls,
  });
}

/// 流式推理事件。文本增量、工具调用、结束标记三种互斥形态。
class InferenceStreamEvent {
  final String? textDelta;
  final ToolCallData? toolCall;
  final bool isDone;

  const InferenceStreamEvent._({
    this.textDelta,
    this.toolCall,
    this.isDone = false,
  });

  factory InferenceStreamEvent.text(String delta) =>
      InferenceStreamEvent._(textDelta: delta);
  factory InferenceStreamEvent.toolCall(ToolCallData call) =>
      InferenceStreamEvent._(toolCall: call);
  static const InferenceStreamEvent done = InferenceStreamEvent._(isDone: true);
}

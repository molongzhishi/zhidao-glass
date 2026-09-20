import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/model_download_service.dart';
import '../services/inference_service.dart';
import '../services/tts_service.dart';
import '../services/photo_service.dart';
import '../services/app_tools.dart';
import '../services/wakeup_service.dart';
import '../services/bluetooth_spp_service.dart';
import '../services/uvc_camera_service.dart';
import '../services/warning_center.dart';
import '../services/chat_database_service.dart';
import 'settings_screen.dart';
import 'bluetooth_settings_screen.dart';
import 'hardware_vision_screen.dart';
import 'image_analysis_screen.dart';
import 'uvc_vision_screen.dart';
import 'widgets/voice_analysis_prompt.dart';
import 'widgets/warning_banner.dart';
import 'guide/status_screen.dart';

enum MessageType { text, image, toolCall }

class ChatMessage {
  final String id;
  final String text;
  final bool isUser;
  final MessageType type;
  final String? imagePath;
  final DateTime timestamp;
  final String? toolName;

  ChatMessage({
    required this.id,
    required this.text,
    required this.isUser,
    this.type = MessageType.text,
    this.imagePath,
    DateTime? timestamp,
    this.toolName,
  }) : timestamp = timestamp ?? DateTime.now();
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  final ChatDatabaseService _dbService = ChatDatabaseService();
  bool _isTyping = false;
  bool _isInitialized = false;
  bool _voiceInputEnabled = true;
  bool _ttsEnabled = true;
  bool _wasContinuousListeningBeforeBackground = false;
  bool _reloadGemmaAfterRecognition = false;
  StreamSubscription<UvcCameraStatusEvent>? _uvcStatusSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMessagesFromDatabase();
    _initServices();
  }

  Future<void> _loadMessagesFromDatabase() async {
    try {
      final messages = await _dbService.getMessages(limit: 100);
      if (messages.isEmpty) {
        _messages.add(
          ChatMessage(
            id: '1',
            text: '你好！我是你的本地AI助手。请先下载模型，然后我们就可以开始聊天了。你可以让我打开设置、清除聊天记录、切换语音功能等。',
            isUser: false,
          ),
        );
      } else {
        for (final msg in messages) {
          _messages.add(
            ChatMessage(
              id: msg.id?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
              text: msg.text,
              isUser: msg.isUser,
              type: _parseMessageType(msg.type),
              imagePath: msg.imagePath,
              toolName: msg.toolName,
              timestamp: msg.timestamp,
            ),
          );
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[ChatScreen] 加载聊天记录失败: $e');
      _messages.add(
        ChatMessage(
          id: '1',
          text: '你好！我是你的本地AI助手。请先下载模型，然后我们就可以开始聊天了。',
          isUser: false,
        ),
      );
    }
  }

  MessageType _parseMessageType(String type) {
    switch (type) {
      case 'image':
        return MessageType.image;
      case 'toolCall':
        return MessageType.toolCall;
      default:
        return MessageType.text;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _uvcStatusSubscription ??= context
        .read<UvcCameraService>()
        .statusEvents
        .listen(_handleUvcCameraStatusEvent);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uvcStatusSubscription?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    final voiceService = Provider.of<VoiceService>(context, listen: false);

    switch (state) {
      case AppLifecycleState.paused:
        _wasContinuousListeningBeforeBackground = voiceService.isListening;
        voiceService.stopListening();
        debugPrint('[ChatScreen] App进入后台，已停止语音识别');
        break;
      case AppLifecycleState.resumed:
        if (_wasContinuousListeningBeforeBackground &&
            !voiceService.isListening) {
          voiceService.startListening(onVoiceDetected: _handleVoiceCommand);
          debugPrint('[ChatScreen] App返回前台，恢复语音识别');
        }
        break;
      case AppLifecycleState.detached:
        voiceService.stopListening();
        debugPrint('[ChatScreen] App关闭，已停止语音识别');
        break;
      default:
        break;
    }
  }

  Future<void> _initServices() async {
    final downloadService = Provider.of<ModelDownloadService>(
      context,
      listen: false,
    );
    await downloadService.init();

    if (mounted) {
      setState(() => _isInitialized = true);
    }

    if (await downloadService.isModelDownloaded()) {
      if (!mounted) return;
      final inferenceService = Provider.of<InferenceService>(
        context,
        listen: false,
      );

      try {
        await inferenceService.loadModel(downloadService.llmModelFilePath!);

        await _initWakeupService();

        debugPrint('[ChatScreen] 模型加载成功，语音识别已启动');
      } catch (e) {
        debugPrint('[ChatScreen] 模型加载失败，语音识别未启动: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '模型加载失败: ${e.toString().substring(0, e.toString().length > 50 ? 50 : e.toString().length)}',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _initWakeupService() async {
    final voiceService = Provider.of<VoiceService>(context, listen: false);
    final inferenceService = Provider.of<InferenceService>(
      context,
      listen: false,
    );
    final downloadService = Provider.of<ModelDownloadService>(
      context,
      listen: false,
    );

    voiceService.configureAsrLifecycle(
      beforeRecognition: () async {
        _reloadGemmaAfterRecognition =
            inferenceService.isModelLoaded || inferenceService.isLoading;
        await inferenceService.unloadModel();
      },
      afterRecognition: () async {
        final shouldReload = _reloadGemmaAfterRecognition;
        _reloadGemmaAfterRecognition = false;
        final modelPath = downloadService.llmModelFilePath;
        if (shouldReload &&
            !inferenceService.isModelLoaded &&
            downloadService.isDownloadComplete &&
            modelPath != null) {
          await inferenceService.loadModel(modelPath);
        }
      },
    );

    await voiceService.init();

    if (voiceService.errorMessage != null) {
      debugPrint('[ChatScreen] 语音模型初始化失败: ${voiceService.errorMessage}');
      return;
    }

    if (!voiceService.isModelDownloaded) {
      debugPrint('[ChatScreen] 语音模型正在下载，等待下载完成...');
      while (!voiceService.isModelDownloaded &&
          voiceService.errorMessage == null) {
        await Future.delayed(const Duration(seconds: 5));
      }

      if (voiceService.errorMessage != null) {
        debugPrint('[ChatScreen] 语音模型下载失败: ${voiceService.errorMessage}');
        return;
      }
    }

    await voiceService.startListening(onVoiceDetected: _handleVoiceCommand);
  }

  void _handleVoiceCommand(String command) {
    if (!mounted) return;

    _addMessage(command, true);
    _scrollToBottom();

    if (_isWarningReasonQuestion(command)) {
      _answerWarningReasons();
      return;
    }

    if (_handlePendingUvcResetIntent(command)) {
      return;
    }
    if (_isExplicitUvcResetCommand(command)) {
      unawaited(_handleToolCall('resetUvcCamera', const {}));
      return;
    }
    if (_isYoloVisionCommand(command)) {
      unawaited(_openYoloVisionFromLocalCommand());
      return;
    }

    final inferenceService = Provider.of<InferenceService>(
      context,
      listen: false,
    );
    final downloadService = Provider.of<ModelDownloadService>(
      context,
      listen: false,
    );

    if (!downloadService.isDownloadComplete) {
      _addMessage('请先下载模型。', false);
      return;
    }

    if (!inferenceService.isModelLoaded) {
      setState(() => _isTyping = true);
      inferenceService
          .loadModel(downloadService.llmModelFilePath!)
          .then((_) {
            if (mounted) {
              setState(() => _isTyping = false);
              _processWakeupCommand(command);
            }
          })
          .catchError((e) {
            if (mounted) {
              setState(() => _isTyping = false);
              _addMessage('模型加载失败: $e', false);
            }
          });
    } else {
      _processWakeupCommand(command);
    }
  }

  Future<void> _processWakeupCommand(String command) async {
    if (!mounted) return;
    await _runStreamingPrompt(command);
  }

  /// 统一的流式生成循环：消费 textDelta 实时追加，遇到工具调用转交执行。
  /// 与 [_handleSend] 共用，避免两处重复维护流式消费逻辑。
  Future<void> _runStreamingPrompt(String prompt) async {
    if (!mounted) return;

    setState(() => _isTyping = true);
    _startStreamingMessage();
    var toolCallHandled = false;
    try {
      final inferenceService = Provider.of<InferenceService>(
        context,
        listen: false,
      );
      await for (final event
          in inferenceService.generateWithToolsStream(prompt)) {
        if (!mounted) break;
        if (event.isDone) break;
        if (event.toolCall != null) {
          // 工具调用：移除流式占位消息，转入工具执行反馈流程
          _removeStreamingMessage();
          toolCallHandled = true;
          await _handleToolCall(event.toolCall!.name, event.toolCall!.args);
        } else if (event.textDelta != null) {
          _appendStreamingDelta(event.textDelta!);
        }
      }
      if (mounted && !toolCallHandled) {
        _finalizeStreamingMessage();
      }
    } catch (e) {
      if (mounted) {
        _removeStreamingMessage();
        _addMessage('抱歉，出现了错误：${_brief(e)}', false);
      }
    } finally {
      if (mounted) {
        setState(() => _isTyping = false);
      }
    }
  }

  /// 截断工具错误消息，避免超长文本撑爆消息气泡
  String _brief(Object? message) {
    final text = message.toString();
    return text.length > 50 ? text.substring(0, 50) : text;
  }

  /// 是否是在询问“警告/报警原因”
  bool _isWarningReasonQuestion(String text) {
    final normalized = text.replaceAll(RegExp(r'[\s，。！？、,.!?~～]'), '');
    return RegExp(
      r'(警告原因|报警原因|为什么警告|为什么报警|为什么有警告|为什么报警提示|警告来源|报警来源|什么警告|什么报警|有哪些警告|有什么警告|都有什么警告|怎么报警|怎么警告|为何报警|为何警告|当前警告|现在什么报警|现在什么警告)',
    ).hasMatch(normalized);
  }

  /// 直接读取 WarningCenter 实时状态回答，不经过 LLM，响应频繁提问
  void _answerWarningReasons() {
    final center = Provider.of<WarningCenter>(context, listen: false);
    _addMessage(center.reportWarningReasons(), false);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleSend() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    _textController.clear();
    _addMessage(text, true);

    if (_isWarningReasonQuestion(text)) {
      _answerWarningReasons();
      return;
    }

    if (_handlePendingUvcResetIntent(text)) {
      return;
    }
    if (_isExplicitUvcResetCommand(text)) {
      await _handleToolCall('resetUvcCamera', const {});
      return;
    }
    if (_isYoloVisionCommand(text)) {
      await _openYoloVisionFromLocalCommand();
      return;
    }

    final inferenceService = Provider.of<InferenceService>(
      context,
      listen: false,
    );
    final downloadService = Provider.of<ModelDownloadService>(
      context,
      listen: false,
    );

    if (!downloadService.isDownloadComplete) {
      _addMessage('请先下载模型。', false);
      return;
    }

    if (!inferenceService.isModelLoaded) {
      setState(() => _isTyping = true);
      await inferenceService.loadModel(downloadService.llmModelFilePath!);
      setState(() => _isTyping = false);
    }

    await _runStreamingPrompt(text);
  }

  Future<void> _handleToolCall(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final toolType = AppTool.fromName(toolName);
    if (toolType == null) {
      _addMessage(
        '未知工具: $toolName',
        false,
        type: MessageType.toolCall,
        toolName: toolName,
      );
      return;
    }

    _addMessage(
      '正在执行: $toolName',
      false,
      type: MessageType.toolCall,
      toolName: toolName,
    );

    String result = '';
    switch (toolType) {
      case AppToolType.openSettings:
        result = await _executeOpenSettings();
        break;
      case AppToolType.clearChatHistory:
        result = await _executeClearChatHistory();
        break;
      case AppToolType.toggleVoiceInput:
        result = await _executeToggleVoiceInput(args);
        break;
      case AppToolType.toggleTts:
        result = await _executeToggleTts(args);
        break;
      case AppToolType.downloadModel:
        result = await _executeDownloadModel();
        break;
      case AppToolType.reloadModel:
        result = await _executeReloadModel();
        break;
      case AppToolType.getAppStatus:
        result = await _executeGetAppStatus();
        break;
      case AppToolType.getWarningReasons:
        result = await _executeGetWarningReasons();
        break;
      case AppToolType.startImageAnalysis:
        result = await _executeStartImageAnalysis();
        break;
      case AppToolType.startYoloVision:
        result = await _executeStartYoloVision();
        break;
      case AppToolType.startUvcVision:
        result = await _executeStartUvcVision();
        break;
      case AppToolType.toggleUvcVision:
        result = await _executeToggleUvcVision(args);
        break;
      case AppToolType.resetUvcCamera:
        result = await _executeResetUvcCamera();
        break;
    }

    _addMessage(result, false);
  }

  Future<String> _executeOpenSettings() async {
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const SettingsScreen()),
      );
    }
    return '已打开设置页面';
  }

  Future<String> _executeClearChatHistory() async {
    try {
      await _dbService.clearAllMessages();
      setState(() {
        _messages.clear();
      });
      return '聊天记录已清除';
    } catch (e) {
      debugPrint('[ChatScreen] 清除聊天记录失败: $e');
      return '清除聊天记录失败: $e';
    }
  }

  Future<String> _executeToggleVoiceInput(Map<String, dynamic> args) async {
    final enable = args['enable'] as bool? ?? !_voiceInputEnabled;
    setState(() {
      _voiceInputEnabled = enable;
    });

    final voiceService = Provider.of<VoiceService>(context, listen: false);
    if (_voiceInputEnabled && !voiceService.isListening) {
      await voiceService.startListening(onVoiceDetected: _handleVoiceCommand);
    } else if (!_voiceInputEnabled && voiceService.isListening) {
      voiceService.stopListening();
    }

    return _voiceInputEnabled ? '语音输入已启用' : '语音输入已禁用';
  }

  Future<String> _executeToggleTts(Map<String, dynamic> args) async {
    final enable = args['enable'] as bool? ?? !_ttsEnabled;
    setState(() {
      _ttsEnabled = enable;
    });
    return _ttsEnabled ? '语音合成已启用' : '语音合成已禁用';
  }

  Future<String> _executeDownloadModel() async {
    final downloadService = Provider.of<ModelDownloadService>(
      context,
      listen: false,
    );
    await downloadService.downloadModel();
    return '模型下载已开始';
  }

  Future<String> _executeReloadModel() async {
    final inferenceService = Provider.of<InferenceService>(
      context,
      listen: false,
    );
    final downloadService = Provider.of<ModelDownloadService>(
      context,
      listen: false,
    );

    await inferenceService.unloadModel();
    await inferenceService.loadModel(downloadService.llmModelFilePath!);
    return '模型已重新加载';
  }

  Future<String> _executeGetAppStatus() async {
    final inferenceService = Provider.of<InferenceService>(
      context,
      listen: false,
    );
    final downloadService = Provider.of<ModelDownloadService>(
      context,
      listen: false,
    );
    final voiceService = Provider.of<VoiceService>(context, listen: false);
    final uvcService = Provider.of<UvcCameraService>(context, listen: false);
    final bluetoothService = Provider.of<BluetoothSppService>(
      context,
      listen: false,
    );

    return '''应用状态：
- 模型加载: ${inferenceService.isModelLoaded ? '已加载' : '未加载'}
- 模型名称: ${inferenceService.modelName ?? '未知'}
- 模型大小: ${inferenceService.modelSize ?? '未知'}
- 模型下载: ${downloadService.isDownloadComplete ? '已完成' : '未完成'}
- 语音输入: ${_voiceInputEnabled ? '已启用' : '已禁用'}
- 语音合成: ${_ttsEnabled ? '已启用' : '已禁用'}
- Qwen3-ASR-1.7B INT8 ONNX模型: ${voiceService.isModelDownloaded ? '已下载' : '未下载'}
- 语音识别: ${voiceService.isListening ? '运行中' : '已停止'}
- 蓝牙连接: ${bluetoothService.isConnected ? '已连接' : '未连接'}
- USB摄像头: ${uvcService.isOpened ? '已连接' : '未连接'}
- USB摄像头重置确认: ${uvcService.awaitingResetConfirmation ? '等待用户答复' : '无'}''';
  }

  Future<String> _executeGetWarningReasons() async {
    final center = Provider.of<WarningCenter>(context, listen: false);
    return center.reportWarningReasons();
  }

  Future<String> _executeStartImageAnalysis() async {
    if (mounted) {
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const ImageAnalysisScreen()),
        ),
      );
    }
    return '已打开图像分析页面，可拍照或从相册选择图片进行分析';
  }

  bool _isYoloVisionCommand(String text) {
    final hasVisionTarget = RegExp(
      r'(yolo|实时视觉|视觉指导|目标检测|障碍物探测)',
      caseSensitive: false,
    ).hasMatch(text);
    final hasStartAction = RegExp(r'(打开|开启|启动|进入|运行|使用|开始)').hasMatch(text);
    return hasVisionTarget && hasStartAction;
  }

  Future<void> _openYoloVisionFromLocalCommand() async {
    final result = await _executeStartYoloVision();
    if (mounted) {
      _addMessage(result, false);
    }
  }

  Future<String> _executeStartYoloVision() async {
    if (mounted) {
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const HardwareVisionScreen()),
        ),
      );
    }
    return '已打开机器视觉（通用检测模型），语音指令仍可继续接收';
  }

  Future<String> _executeStartUvcVision() async {
    if (mounted) {
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => const UvcVisionScreen()),
        ),
      );
    }
    return '已打开USB摄像头（UVC）实时视觉，请在页面中选择并连接USB摄像头，语音指令仍可继续接收';
  }

  Future<String> _executeToggleUvcVision(Map<String, dynamic> args) async {
    final enable = (args['enable'] as bool?) ?? true;
    if (enable) {
      return _executeStartUvcVision();
    }
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    return '已关闭USB摄像头视觉页面';
  }

  Future<String> _executeResetUvcCamera() async {
    final uvcService = context.read<UvcCameraService>();
    if (uvcService.isResetting) {
      return 'USB 摄像头正在重置，请稍候';
    }

    final reset = await uvcService.resetCamera();
    if (reset) {
      return 'USB 摄像头重置完成，已重新打开设备并恢复图像帧流';
    }
    return uvcService.errorMessage ?? 'USB 摄像头重置失败';
  }

  void _handleUvcCameraStatusEvent(UvcCameraStatusEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case UvcCameraStatusEventType.frameTimeout:
      case UvcCameraStatusEventType.frameRecovered:
        _addMessage(event.message, false);
        break;
    }
  }

  bool _handlePendingUvcResetIntent(String text) {
    final uvcService = context.read<UvcCameraService>();
    if (!uvcService.awaitingResetConfirmation) return false;

    switch (UvcResetIntentParser.parse(text)) {
      case UvcResetIntent.confirm:
        unawaited(_handleToolCall('resetUvcCamera', const {}));
        return true;
      case UvcResetIntent.decline:
        uvcService.declineReset();
        _addMessage('已按你的选择暂不重置 USB 摄像头。画面恢复后会自动解除故障状态。', false);
        return true;
      case UvcResetIntent.unrelated:
        return false;
    }
  }

  bool _isExplicitUvcResetCommand(String text) {
    final normalized = text.toLowerCase();
    final mentionsUvc = RegExp(
      r'(usb|uvc|外接摄像头|usb摄像头|外接相机|外部摄像头)',
      caseSensitive: false,
    ).hasMatch(normalized);
    final requestsReset = RegExp(r'(重置|重启|重新连接|恢复)').hasMatch(normalized);
    final rejectsReset = RegExp(r'(不要|不想|不需要|无需|取消|拒绝)').hasMatch(normalized);
    return mentionsUvc && requestsReset && !rejectsReset;
  }

  Future<void> _showVisionSourceDialog() async {
    if (!mounted) return;
    final source = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择摄像头来源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.orange),
              title: const Text('内置摄像头'),
              subtitle: const Text('使用手机自带摄像头进行 YOLO26 目标检测'),
              onTap: () => Navigator.pop(context, 'internal'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.usb, color: Colors.teal),
              title: const Text('USB 摄像头（UVC）'),
              subtitle: const Text('使用外接 USB 摄像头进行离线目标检测'),
              onTap: () => Navigator.pop(context, 'uvc'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    String result;
    if (source == 'internal') {
      result = await _executeStartYoloVision();
    } else if (source == 'uvc') {
      result = await _executeStartUvcVision();
    } else {
      return;
    }
    _addMessage(result, false);
  }

  Future<void> _handleImageCapture() async {
    final photoService = Provider.of<PhotoService>(context, listen: false);
    final imagePath = await photoService.takePhoto();

    if (imagePath != null && mounted) {
      _addMessage('图片已发送', true, type: MessageType.image, imagePath: imagePath);

      final inferenceService = Provider.of<InferenceService>(
        context,
        listen: false,
      );
      final downloadService = Provider.of<ModelDownloadService>(
        context,
        listen: false,
      );

      if (!downloadService.isDownloadComplete) {
        _addMessage('请先下载模型。', false);
        return;
      }

      if (!inferenceService.isModelLoaded) {
        setState(() => _isTyping = true);
        await inferenceService.loadModel(downloadService.llmModelFilePath!);
        setState(() => _isTyping = false);
      }

      setState(() => _isTyping = true);
      try {
        final response = await inferenceService.generateWithTools(
          '请描述这张图片的内容',
          imagePath: imagePath,
        );

        if (response.type == InferenceResponseType.text) {
          _addMessage(response.text ?? '抱歉，我无法分析这张图片。', false);
        } else {
          _addMessage('图片分析完成', false);
        }
      } catch (e) {
        _addMessage(
          '抱歉，图片分析出现了错误：${_brief(e)}',
          false,
        );
      } finally {
        setState(() => _isTyping = false);
      }
    }
  }

  void _addMessage(
    String text,
    bool isUser, {
    MessageType type = MessageType.text,
    String? imagePath,
    String? toolName,
  }) {
    final message = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: text,
      isUser: isUser,
      type: type,
      imagePath: imagePath,
      toolName: toolName,
    );

    setState(() {
      _messages.add(message);
    });
    _scrollToBottom();

    // 保存到数据库
    _saveMessageToDatabase(message);

    // TTS在后台执行，不阻塞UI线程
    if (type == MessageType.text && !isUser) {
      _speakMessage(text);
    }
  }

  Future<void> _saveMessageToDatabase(ChatMessage message) async {
    try {
      await _dbService.insertMessage(
        ChatMessageData(
          text: message.text,
          isUser: message.isUser,
          type: message.type.name,
          imagePath: message.imagePath,
          toolName: message.toolName,
          timestamp: message.timestamp,
        ),
      );
    } catch (e) {
      debugPrint('[ChatScreen] 保存消息到数据库失败: $e');
    }
  }

  /// 流式消息辅助方法：管理一个 id='streaming' 的占位消息，
  /// 支持增量追加、定稿、移除三种操作，避免高频 setState 导致的列表抖动。

  static const String _streamingMessageId = 'streaming';

  void _startStreamingMessage() {
    _removeStreamingMessage();
    setState(() {
      _messages.add(
        ChatMessage(id: _streamingMessageId, text: '', isUser: false),
      );
    });
    _scrollToBottom();
  }

  void _appendStreamingDelta(String delta) {
    if (delta.isEmpty) return;
    final idx = _messages.lastIndexWhere((m) => m.id == _streamingMessageId);
    if (idx < 0) return;
    setState(() {
      final old = _messages[idx];
      _messages[idx] = ChatMessage(
        id: _streamingMessageId,
        text: old.text + delta,
        isUser: false,
        timestamp: old.timestamp,
      );
    });
    _scrollToBottom();
  }

  void _finalizeStreamingMessage() {
    final idx = _messages.lastIndexWhere((m) => m.id == _streamingMessageId);
    if (idx < 0) return;
    final old = _messages[idx];
    setState(() {
      _messages[idx] = ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        text: old.text,
        isUser: false,
        timestamp: old.timestamp,
      );
    });
    if (old.text.isNotEmpty) {
      _speakMessage(old.text);
    }
  }

  void _removeStreamingMessage() {
    setState(() {
      _messages.removeWhere((m) => m.id == _streamingMessageId);
    });
  }

  Future<void> _handleDownloadModel() async {
    final downloadService = Provider.of<ModelDownloadService>(
      context,
      listen: false,
    );

    await downloadService.downloadModel();

    if (await downloadService.isModelDownloaded()) {
      if (!mounted) return;
      final inferenceService = Provider.of<InferenceService>(
        context,
        listen: false,
      );

      try {
        await inferenceService.loadModel(downloadService.llmModelFilePath!);

        await _initWakeupService();

        debugPrint('[ChatScreen] 模型下载并加载成功，语音识别已启动');
      } catch (e) {
        debugPrint('[ChatScreen] 模型加载失败，语音识别未启动: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '模型加载失败: ${e.toString().substring(0, e.toString().length > 50 ? 50 : e.toString().length)}',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _speakMessage(String text) async {
    if (!_ttsEnabled) return;

    final ttsService = Provider.of<TtsService>(context, listen: false);
    final voiceService = Provider.of<VoiceService>(context, listen: false);

    // TTS播放期间暂停语音识别，避免录到TTS声音形成循环
    final wasListening = voiceService.isListening;
    if (wasListening) {
      voiceService.pauseListening();
      debugPrint('[ChatScreen] TTS播放，暂停语音识别');
    }

    await ttsService.speak(text);

    // 等待TTS播放完成
    while (ttsService.state == TtsState.playing) {
      await Future.delayed(const Duration(milliseconds: 200));
    }

    // TTS播放完成后恢复语音识别
    if (wasListening) {
      await voiceService.startListening(onVoiceDetected: _handleVoiceCommand);
      debugPrint('[ChatScreen] TTS播放完成，恢复语音识别');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('zhidao_glass'),
        actions: [
          Consumer<ModelDownloadService>(
            builder: (context, service, child) {
              if (!service.isDownloadComplete) {
                return TextButton(
                  onPressed: service.isDownloading
                      ? null
                      : _handleDownloadModel,
                  child: service.isDownloading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(),
                        )
                      : const Text('下载模型'),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          Consumer<BluetoothSppService>(
            builder: (context, service, child) {
              return Stack(
                children: [
                  IconButton(
                    icon: Icon(
                      service.isConnected
                          ? Icons.bluetooth_connected
                          : Icons.bluetooth,
                      color: service.isConnected ? Colors.blue : null,
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const BluetoothSettingsScreen(),
                        ),
                      );
                    },
                  ),
                  if (service.isConnected)
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.visibility),
            color: Colors.orange,
            tooltip: 'YOLO 视觉检测',
            onPressed: () async {
              await _showVisionSourceDialog();
            },
          ),
          IconButton(
            icon: const Icon(Icons.usb),
            color: Colors.teal,
            tooltip: 'USB 摄像头视觉',
            onPressed: () async {
              final result = await _executeStartUvcVision();
              if (mounted) {
                _addMessage(result, false);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.monitor_heart),
            color: Colors.green,
            tooltip: '运行状态',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const StatusScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Consumer<ModelDownloadService>(
                  builder: (context, service, child) {
                    if (!_isInitialized) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (service.isDownloading) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text('下载进度: ${service.downloadProgress}%'),
                            const SizedBox(height: 8),
                            Text(
                              '${(service.downloadedBytes / 1024 / 1024).toStringAsFixed(1)}MB / ${(service.totalBytes / 1024 / 1024).toStringAsFixed(1)}MB',
                            ),
                            if (service.errorMessage != null)
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 16,
                                  left: 16,
                                  right: 16,
                                ),
                                child: Text(
                                  service.errorMessage!,
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontSize: 12,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                          ],
                        ),
                      );
                    }
                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(8),
                      itemCount: _messages.length + (_isTyping ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == _messages.length) {
                          return const Padding(
                            padding: EdgeInsets.all(8),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text('正在思考...'),
                            ),
                          );
                        }
                        final message = _messages[index];
                        return _buildMessageItem(message);
                      },
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Consumer<ModelDownloadService>(
                builder: (context, service, child) {
                  if (!_isInitialized) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (!service.isDownloadComplete) {
                    return Container(
                      padding: const EdgeInsets.all(16),
                      color: Colors.grey[100],
                      child: Column(
                        children: [
                          const Text('请先下载模型'),
                          const SizedBox(height: 8),
                          ElevatedButton(
                            onPressed: service.isDownloading
                                ? null
                                : _handleDownloadModel,
                            child: service.isDownloading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(),
                                  )
                                : const Text('下载模型'),
                          ),
                          if (service.downloadProgress > 0)
                            LinearProgressIndicator(
                              value: service.downloadProgress / 100,
                            ),
                          if (service.errorMessage != null &&
                              !service.isDownloading)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Column(
                                children: [
                                  Text(
                                    service.errorMessage!,
                                    style: const TextStyle(
                                      color: Colors.red,
                                      fontSize: 12,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton(
                                    onPressed: _handleDownloadModel,
                                    child: const Text('重试下载'),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    );
                  }
                  return _buildInputArea();
                },
              ),
            ],
          ),
          const Positioned(
            top: 8,
            left: 12,
            right: 12,
            child: WarningBanner(),
          ),
          Consumer<VoiceService>(
            builder: (context, voiceService, child) {
              return VoiceAnalysisPrompt(
                isAnalyzing: voiceService.isRecognizing,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMessageItem(ChatMessage message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        mainAxisAlignment: message.isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: message.type == MessageType.toolCall
                    ? Colors.purple[100]
                    : message.isUser
                    ? Colors.blue
                    : Colors.grey[200],
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: message.isUser
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  if (message.type == MessageType.image &&
                      message.imagePath != null)
                    Image.file(File(message.imagePath!), height: 200),
                  if (message.type == MessageType.toolCall &&
                      message.toolName != null)
                    Text(
                      '🔧 ${message.toolName}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: Colors.purple,
                      ),
                    ),
                  Text(
                    message.text,
                    style: TextStyle(
                      color: message.type == MessageType.toolCall
                          ? Colors.purple[800]
                          : message.isUser
                          ? Colors.white
                          : Colors.black,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _formatTime(message.timestamp),
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                  if (!message.isUser && message.type != MessageType.toolCall)
                    IconButton(
                      onPressed: () => _speakMessage(message.text),
                      icon: const Icon(Icons.volume_up),
                      iconSize: 16,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          IconButton(
            onPressed: _handleImageCapture,
            icon: const Icon(Icons.camera_alt),
            color: Colors.blue,
          ),
          Expanded(
            child: TextField(
              controller: _textController,
              decoration: const InputDecoration(
                hintText: '输入消息...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(24)),
                ),
                contentPadding: EdgeInsets.symmetric(horizontal: 16),
              ),
              onSubmitted: (_) => _handleSend(),
            ),
          ),
          Consumer<VoiceService>(
            builder: (context, voiceService, child) {
              return IconButton(
                onPressed: () => _toggleListening(),
                icon: voiceService.isListening
                    ? const Icon(Icons.mic)
                    : const Icon(Icons.mic_off),
                color: voiceService.isListening ? Colors.blue : Colors.grey,
                tooltip: voiceService.isListening ? '暂停录音' : '开启录音',
              );
            },
          ),
          IconButton(
            onPressed: _handleSend,
            icon: const Icon(Icons.send),
            color: Colors.blue,
          ),
        ],
      ),
    );
  }

  void _toggleListening() async {
    final voiceService = Provider.of<VoiceService>(context, listen: false);

    if (voiceService.isListening) {
      voiceService.pauseListening();
    } else {
      await voiceService.startListening(onVoiceDetected: _handleVoiceCommand);
    }
  }

  String _formatTime(DateTime timestamp) {
    return '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
  }
}

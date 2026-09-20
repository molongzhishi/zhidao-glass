import 'package:flutter_gemma/core/tool.dart';

enum AppToolType {
  openSettings,
  clearChatHistory,
  toggleVoiceInput,
  toggleTts,
  downloadModel,
  reloadModel,
  getAppStatus,
  getWarningReasons,
  startImageAnalysis,
  startYoloVision,
  startUvcVision,
  toggleUvcVision,
  resetUvcCamera,
}

enum UvcResetIntent { confirm, decline, unrelated }

class UvcResetIntentParser {
  const UvcResetIntentParser._();

  static UvcResetIntent parse(String input) {
    final normalized = input.trim().toLowerCase().replaceAll(
      RegExp(r'[\s，。！？、,.!?]'),
      '',
    );
    if (normalized.isEmpty) return UvcResetIntent.unrelated;

    const declinePhrases = [
      '不要重置',
      '不重置',
      '暂不重置',
      '先不重置',
      '不用重置',
      '不需要重置',
      '无需重置',
      '不想重置',
      '别重置',
      '没必要重置',
      '不可以',
      '不是',
      '不要',
      '别',
      '不用了',
      '暂不',
      '先不',
      '取消',
      '拒绝',
      '否',
      'no',
    ];
    if (declinePhrases.any(normalized.contains)) {
      return UvcResetIntent.decline;
    }

    const uncertainPhrases = [
      '是否',
      '要不要',
      '该不该',
      '不确定',
      '没决定',
      '再想想',
      '等一下',
      '稍后',
    ];
    if (uncertainPhrases.any(normalized.contains)) {
      return UvcResetIntent.unrelated;
    }

    const exactConfirmations = [
      '确认',
      '同意',
      '可以',
      '好的',
      '好',
      '是',
      '是的',
      '需要',
      '执行',
      '没问题',
      'ok',
      'yes',
    ];
    if (exactConfirmations.contains(normalized) ||
        normalized.contains('重置') ||
        normalized.contains('重启') ||
        normalized.contains('重新连接')) {
      return UvcResetIntent.confirm;
    }

    return UvcResetIntent.unrelated;
  }
}

class AppTool {
  final AppToolType type;
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  const AppTool({
    required this.type,
    required this.name,
    required this.description,
    this.parameters = const {},
  });

  Tool toFlutterGemmaTool() {
    return Tool(name: name, description: description, parameters: parameters);
  }

  factory AppTool.fromType(AppToolType type) {
    switch (type) {
      case AppToolType.openSettings:
        return const AppTool(
          type: AppToolType.openSettings,
          name: 'openSettings',
          description: '打开应用设置页面，用于查看和修改应用配置',
        );
      case AppToolType.clearChatHistory:
        return const AppTool(
          type: AppToolType.clearChatHistory,
          name: 'clearChatHistory',
          description: '清除当前所有聊天记录',
        );
      case AppToolType.toggleVoiceInput:
        return const AppTool(
          type: AppToolType.toggleVoiceInput,
          name: 'toggleVoiceInput',
          description: '切换语音输入功能的开关状态',
          parameters: {
            'type': 'object',
            'properties': {
              'enable': {'type': 'boolean', 'description': '是否启用语音输入'},
            },
            'required': ['enable'],
          },
        );
      case AppToolType.toggleTts:
        return const AppTool(
          type: AppToolType.toggleTts,
          name: 'toggleTts',
          description: '切换语音合成（TTS）功能的开关状态',
          parameters: {
            'type': 'object',
            'properties': {
              'enable': {'type': 'boolean', 'description': '是否启用语音合成'},
            },
            'required': ['enable'],
          },
        );
      case AppToolType.downloadModel:
        return const AppTool(
          type: AppToolType.downloadModel,
          name: 'downloadModel',
          description: '开始下载AI模型',
        );
      case AppToolType.reloadModel:
        return const AppTool(
          type: AppToolType.reloadModel,
          name: 'reloadModel',
          description: '重新加载当前模型',
        );
      case AppToolType.getAppStatus:
        return const AppTool(
          type: AppToolType.getAppStatus,
          name: 'getAppStatus',
          description: '获取应用当前状态，包括模型加载状态、语音功能状态等',
        );
      case AppToolType.getWarningReasons:
        return const AppTool(
          type: AppToolType.getWarningReasons,
          name: 'getWarningReasons',
          description:
              '获取当前激活的警告来源及原因（雷达方面障碍物、摄像头检测到障碍物、USB摄像头故障三类，互解耦），用于回答"为什么报警/警告原因"等问题',
        );
      case AppToolType.startImageAnalysis:
        return const AppTool(
          type: AppToolType.startImageAnalysis,
          name: 'startImageAnalysis',
          description: '打开摄像头并开始实时图像分析，用于识别和描述拍摄到的物体',
        );
      case AppToolType.startYoloVision:
        return const AppTool(
          type: AppToolType.startYoloVision,
          name: 'startYoloVision',
          description: '打开YOLO26实时视觉页面，进行离线目标检测与障碍物探测',
        );
      case AppToolType.startUvcVision:
        return const AppTool(
          type: AppToolType.startUvcVision,
          name: 'startUvcVision',
          description: '打开USB摄像头（UVC）实时视觉页面，连接外接USB摄像头并进行离线目标检测和视觉指导',
        );
      case AppToolType.toggleUvcVision:
        return const AppTool(
          type: AppToolType.toggleUvcVision,
          name: 'toggleUvcVision',
          description: '切换USB摄像头（UVC）视觉页面的开关状态',
          parameters: {
            'type': 'object',
            'properties': {
              'enable': {'type': 'boolean', 'description': '是否开启USB摄像头视觉'},
            },
            'required': ['enable'],
          },
        );
      case AppToolType.resetUvcCamera:
        return const AppTool(
          type: AppToolType.resetUvcCamera,
          name: 'resetUvcCamera',
          description:
              '重置USB摄像头：关闭当前UVC连接，重新打开同一设备并恢复图像帧流。摄像头故障提示后，仅在用户明确同意时调用。',
        );
    }
  }

  static List<AppTool> getAllTools() {
    return AppToolType.values.map(AppTool.fromType).toList();
  }

  static List<Tool> getAllFlutterGemmaTools() {
    return getAllTools().map((t) => t.toFlutterGemmaTool()).toList();
  }

  static AppToolType? fromName(String name) {
    for (final type in AppToolType.values) {
      if (AppTool.fromType(type).name == name) {
        return type;
      }
    }
    return null;
  }
}

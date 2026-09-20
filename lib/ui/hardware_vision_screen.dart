import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../services/hardware_vision_service.dart';
import '../services/vision_warning_service.dart';

/// YOLO26 实时视觉页（单视觉模型方案）
///
/// 参考 "an app" 的单视觉模型实现：由 ultralytics_yolo 插件的 [YOLOView]
/// 直接采集内置摄像头并推理通用检测模型（yolo26n_w8a32.tflite），
/// 检测结果交给 [HardwareVisionService] 过滤、排序并生成视觉引导。
class HardwareVisionScreen extends StatefulWidget {
  const HardwareVisionScreen({super.key});

  @override
  State<HardwareVisionScreen> createState() => _HardwareVisionScreenState();
}

class _HardwareVisionScreenState extends State<HardwareVisionScreen> {
  HardwareVisionService? _visionService;
  VisionWarningService? _visionWarningService;
  final YOLOViewController _yoloController = YOLOViewController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visionService ??= context.read<HardwareVisionService>();
    _visionWarningService ??= context.read<VisionWarningService>();
    _visionWarningService?.attachInternalCamera(_yoloController);
    // start() 会触发 notifyListeners，不能在 didChangeDependencies（build 阶段）
    // 内同步调用，否则会抛 "markNeedsBuild() called during build"；延后到首帧结束。
    if (!_visionService!.isRunning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_visionService!.isRunning) {
          _visionService!.start();
        }
      });
    }
  }

  @override
  void dispose() {
    _visionWarningService?.detachInternalCamera();
    _yoloController.dispose();
    _visionService?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('YOLO26 视觉检测'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          YOLOView(
            controller: _yoloController,
            modelPath: HardwareVisionService.generalModelAsset,
            task: YOLOTask.detect,
            cameraResolution: '720p',
            confidenceThreshold: HardwareVisionService.confidenceThreshold,
            useGpu: true,
            lensFacing: LensFacing.back,
            onResult: (results) {
              _visionService?.updateDetections(results);
            },
            onModelLoad: (_, _) {
              _visionService?.markModelLoaded();
            },
            onModelError: (error, _, _) {
              _visionService?.markModelError(error);
            },
          ),
          // 检测标注层（类别+置信度+图像空间方位）
          Positioned.fill(
            child: Consumer<HardwareVisionService>(
              builder: (context, service, child) {
                final detections = service.detections.take(4).toList();
                if (detections.isEmpty) {
                  return const SizedBox.shrink();
                }
                return Align(
                  alignment: Alignment.topLeft,
                  child: IgnorePointer(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final d in detections)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4, left: 12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _labelText(d),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          // 模型加载状态面板
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Consumer<HardwareVisionService>(
              builder: (context, service, child) {
                final hasError = service.errorMessage != null;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(
                          hasError
                              ? Icons.error_outline
                              : service.isModelLoaded
                              ? Icons.visibility
                              : Icons.hourglass_top,
                          color: hasError
                              ? Colors.redAccent
                              : service.isModelLoaded
                              ? Colors.greenAccent
                              : Colors.orangeAccent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            hasError
                                ? '模型加载失败: ${service.errorMessage}'
                                : service.isModelLoaded
                                    ? '通用模型 (w8a32) 检测中'
                                    : '正在加载通用模型...',
                            style: const TextStyle(color: Colors.white),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          // 视觉引导面板
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Consumer<HardwareVisionService>(
              builder: (context, service, child) {
                final guidance = service.guidance;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.78),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _actionColor(guidance.action),
                      width: 1.5,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _actionIcon(guidance.action),
                              color: _actionColor(guidance.action),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                guidance.message,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '建议指令: ${guidance.command}（仅显示，未自动发送）',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        if (service.detections.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: service.detections
                                .take(4)
                                .map(
                                  (result) => Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      '${result.className} '
                                      '${(result.confidence * 100).toStringAsFixed(0)}%'
                                      ' ${_directionText(result)}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _labelText(VisionDetection d) {
    return '${d.className} '
        '${(d.confidence * 100).toStringAsFixed(0)}%'
        ' ${_directionText(d)}';
  }

  /// 图像空间方位文案（无测距）：由检测框水平中心映射左右/正前
  String _directionText(VisionDetection d) {
    if (d.centerX < 0.35) return '左侧';
    if (d.centerX > 0.65) return '右侧';
    return '正前方';
  }

  Color _actionColor(VisionAction action) {
    switch (action) {
      case VisionAction.forward:
        return Colors.greenAccent;
      case VisionAction.slowDown:
        return Colors.orangeAccent;
      case VisionAction.turnLeft:
      case VisionAction.turnRight:
        return Colors.lightBlueAccent;
      case VisionAction.stop:
        return Colors.redAccent;
    }
  }

  IconData _actionIcon(VisionAction action) {
    switch (action) {
      case VisionAction.forward:
        return Icons.arrow_upward;
      case VisionAction.slowDown:
        return Icons.speed;
      case VisionAction.turnLeft:
        return Icons.turn_left;
      case VisionAction.turnRight:
        return Icons.turn_right;
      case VisionAction.stop:
        return Icons.stop_circle_outlined;
    }
  }
}
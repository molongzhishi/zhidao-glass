import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../services/hardware_vision_service.dart';
import '../services/inference_service.dart';
import '../services/tts_service.dart';
import '../services/uvc_camera_service.dart';
import '../services/vision_warning_service.dart';

class UvcVisionScreen extends StatefulWidget {
  const UvcVisionScreen({super.key});

  @override
  State<UvcVisionScreen> createState() => _UvcVisionScreenState();
}

class _UvcVisionScreenState extends State<UvcVisionScreen> {
  UvcCameraService? _uvc;
  HardwareVisionService? _vision;
  VisionWarningService? _visionWarning;
  YOLO? _yolo;
  bool _yoloReady = false;
  bool _busy = false;
  bool _connecting = false;
  String? _status;
  StreamSubscription<dynamic>? _frameSub;
  StreamSubscription<UvcDeviceEvent>? _deviceSub;
  final ValueNotifier<String> _sheetResultNotifier = ValueNotifier('正在分析图片...');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _uvc ??= context.read<UvcCameraService>();
    _vision ??= context.read<HardwareVisionService>();
    _visionWarning ??= context.read<VisionWarningService>();
    _init();
  }

  Future<void> _init() async {
    final supported = await _uvc!.checkSupported();
    if (!supported) {
      setState(() => _status = '此设备不支持 USB Host，无法使用 USB 摄像头');
      return;
    }
    await _uvc!.listDevices();
    _deviceSub ??= _uvc!.deviceEvents.listen((event) {
      if (event.type == UvcDeviceEventType.detached && _uvc!.isOpened) {
        _disconnect();
      }
      _uvc!.listDevices();
    });
  }

  Future<void> _ensureYolo() async {
    if (_yoloReady || _yolo != null) return;
    setState(() => _status = '加载 YOLO26 模型...');
    try {
      _yolo = YOLO(
        modelPath: HardwareVisionService.generalModelAsset,
        task: YOLOTask.detect,
        useGpu: true,
      );
      final ok = await _yolo!.loadModel();
      if (ok && mounted) {
        _yoloReady = true;
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = 'YOLO 模型加载失败: $e');
      }
    }
  }

  Future<void> _connect(UvcDevice device) async {
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _status = '请求相机权限...';
    });
    final cameraPermission = await Permission.camera.request();
    if (!cameraPermission.isGranted) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _status = cameraPermission.isPermanentlyDenied
              ? '相机权限已被永久拒绝，请在系统设置中允许后重试'
              : '需要相机权限才能访问 USB 摄像头';
        });
      }
      return;
    }
    if (mounted) {
      setState(() => _status = '请求 USB 设备权限...');
    }
    final granted = await _uvc!.requestPermission(device.name);
    if (!granted) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _status = _uvc!.errorMessage ?? '未获得 USB 权限';
        });
      }
      return;
    }
    setState(() => _status = '打开摄像头...');
    try {
      await _uvc!.open(device.name, width: 1280, height: 720);
      await _ensureYolo();
      await _uvc!.startFrameStream();
      _frameSub ??= _uvc!.frameStream.listen(_handleFrame);
      _vision!.start();
      if (mounted) {
        setState(() {
          _connecting = false;
          _status = '运行中';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _status = '连接失败: ${_uvc!.errorMessage ?? e}';
        });
      }
    }
  }

  Future<void> _handleFrame(dynamic data) async {
    if (data is! Uint8List) return;
    _uvc!.markFrameReceived();
    _visionWarning?.submitFrame(data);
    final yolo = _yolo;
    if (!_yoloReady || yolo == null || _busy) return;
    _busy = true;
    try {
      final map = await yolo.predict(
        data,
        confidenceThreshold: HardwareVisionService.confidenceThreshold,
      );
      final detections = YOLODetectionResults.fromMap(map).detections;
      _vision!.updateDetections(detections);
    } catch (e) {
      // 单帧推理失败忽略，等待下一帧
    } finally {
      _busy = false;
    }
  }

  Future<void> _captureAndAnalyze() async {
    final path = await _uvc!.takePicture();
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_uvc!.errorMessage ?? '拍照失败')));
      }
      return;
    }
    if (!mounted) return;
    final inference = context.read<InferenceService>();
    if (!inference.isModelLoaded) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('大模型未加载，请先返回下载模型')));
      }
      return;
    }
    _sheetResultNotifier.value = '正在分析图片...';
    _showAnalysisSheet(path);
    try {
      final response = await inference.generateWithTools(
        '请详细描述这张图片中的内容，包括物体名称、颜色、特征、可能的用途等。如果是食物或饮品，请描述其外观、口感和营养价值。',
        imagePath: path,
      );
      if (response.type == InferenceResponseType.text &&
          response.text != null &&
          mounted) {
        _sheetResultNotifier.value = response.text!;
        final tts = context.read<TtsService>();
        if (tts.isInitialized) {
          await tts.speak(response.text!);
        }
      }
    } catch (e) {
      if (mounted) {
        _sheetResultNotifier.value = '分析失败: ${e.toString().substring(0, 80)}';
      }
    }
  }

  void _showAnalysisSheet(String path) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (ctx, scrollController) => Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'USB 摄像头拍照分析',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Container(
                height: 200,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  image: DecorationImage(
                    image: FileImage(File(path)),
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '分析结果',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  child: ValueListenableBuilder<String>(
                    valueListenable: _sheetResultNotifier,
                    builder: (context, result, child) => Text(
                      result,
                      style: const TextStyle(fontSize: 14, height: 1.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _disconnect() async {
    await _frameSub?.cancel();
    _frameSub = null;
    await _uvc!.close();
    _vision!.stop();
    _busy = false;
    if (mounted) {
      setState(() => _status = null);
    }
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    _deviceSub?.cancel();
    unawaited(_uvc?.close());
    _vision?.stop();
    unawaited(_yolo?.dispose());
    _sheetResultNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uvc = context.watch<UvcCameraService>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('USB 摄像头 (UVC)'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: uvc.isOpened && uvc.preview != null
          ? _buildPreview()
          : _buildDeviceList(uvc),
    );
  }

  Widget _buildDeviceList(UvcCameraService uvc) {
    final displayStatus = uvc.notice ?? uvc.errorMessage ?? _status;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (displayStatus != null) ...[
              Text(
                displayStatus,
                style: TextStyle(
                  color:
                      displayStatus.contains('失败') ||
                          displayStatus.contains('故障')
                      ? Colors.redAccent
                      : Colors.white70,
                ),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              '可用 USB 摄像头（通过 OTG 连接，基于 libuvc）',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Consumer<UvcCameraService>(
                builder: (context, uvc, child) {
                  if (uvc.devices.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.videocam_off,
                            color: Colors.white38,
                            size: 48,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '未检测到 USB 摄像头\n请确认已用 OTG 连接',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white54),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: () async {
                              await uvc.listDevices();
                            },
                            icon: const Icon(Icons.refresh),
                            label: const Text('重新检测'),
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView(
                    children: uvc.devices.map((device) {
                      return Card(
                        color: Colors.white10,
                        child: ListTile(
                          leading: const Icon(
                            Icons.videocam,
                            color: Colors.greenAccent,
                          ),
                          title: Text(
                            device.label,
                            style: const TextStyle(color: Colors.white),
                          ),
                          subtitle: Text(
                            'VID:${device.vendorId.toRadixString(16)} '
                            'PID:${device.productId.toRadixString(16)}',
                            style: const TextStyle(color: Colors.white54),
                          ),
                          trailing: _connecting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : ElevatedButton(
                                  onPressed: () => _connect(device),
                                  child: const Text('连接'),
                                ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final preview = _uvc!.preview!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final displaySize = applyBoxFit(
          BoxFit.contain,
          Size(preview.width.toDouble(), preview.height.toDouble()),
          constraints.biggest,
        );
        final displayRect = Alignment.center.inscribe(
          displaySize.destination,
          Offset.zero & constraints.biggest,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(
              rect: displayRect,
              child: ClipRect(child: Texture(textureId: preview.textureId)),
            ),
            Positioned.fromRect(
              rect: displayRect,
              child: Consumer<HardwareVisionService>(
                builder: (context, service, child) {
                  return CustomPaint(
                    painter: _DetectionOverlayPainter(service.detections),
                  );
                },
              ),
            ),
            _buildStatusCard(_uvc!),
            _buildGuidancePanel(),
            _buildActionButtons(_uvc!),
          ],
        );
      },
    );
  }

  Widget _buildStatusCard(UvcCameraService uvc) {
    final hasFault = uvc.awaitingResetConfirmation;
    final statusText =
        uvc.notice ??
        (_yoloReady ? 'YOLO26 实时检测中（USB 摄像头）' : (_status ?? '等待模型加载...'));
    final statusIcon = uvc.isResetting
        ? Icons.sync
        : hasFault
        ? Icons.warning_amber
        : _yoloReady
        ? Icons.visibility
        : Icons.hourglass_top;
    final statusColor = uvc.isResetting
        ? Colors.lightBlueAccent
        : hasFault
        ? Colors.orangeAccent
        : _yoloReady
        ? Colors.greenAccent
        : Colors.orangeAccent;
    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(statusIcon, color: statusColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  statusText,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGuidancePanel() {
    return Positioned(
      left: 12,
      right: 12,
      bottom: 84,
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
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  if (service.detections.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: service.detections.take(4).map((result) {
                        return Container(
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
                            '${(result.confidence * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildActionButtons(UvcCameraService uvc) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            ElevatedButton.icon(
              onPressed: uvc.isResetting ? null : _captureAndAnalyze,
              icon: const Icon(Icons.camera_alt),
              label: const Text('拍照分析'),
            ),
            ElevatedButton.icon(
              onPressed: _disconnect,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
              ),
              icon: const Icon(Icons.link_off),
              label: const Text('断开'),
            ),
          ],
        ),
      ),
    );
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

class _DetectionOverlayPainter extends CustomPainter {
  _DetectionOverlayPainter(this.detections);

  final List<VisionDetection> detections;

  @override
  void paint(Canvas canvas, Size size) {
    for (final detection in detections) {
      final box = Rect.fromLTWH(
        detection.normalizedBox.left * size.width,
        detection.normalizedBox.top * size.height,
        detection.normalizedBox.width * size.width,
        detection.normalizedBox.height * size.height,
      );
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.greenAccent;
      canvas.drawRect(box, paint);

      final label =
          '${detection.className} '
          '${(detection.confidence * 100).toStringAsFixed(0)}%';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.greenAccent,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(box.left, box.top - tp.height));
    }
  }

  @override
  bool shouldRepaint(covariant _DetectionOverlayPainter oldDelegate) {
    return oldDelegate.detections != detections;
  }
}

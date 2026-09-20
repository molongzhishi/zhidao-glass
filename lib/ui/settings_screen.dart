import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/model_download_service.dart';
import '../services/inference_service.dart';
import '../services/tts_service.dart';
import '../services/wakeup_service.dart';
import '../services/hardware_vision_service.dart';
import 'hardware_vision_screen.dart';
import 'uvc_vision_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: Colors.blue[900],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '模型管理',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          _buildLlmModelCard(context),
          const SizedBox(height: 16),
          _buildSpeechModelCard(context),
          const SizedBox(height: 16),
          _buildYoloModelCard(context),
          const SizedBox(height: 16),
          _buildUvcCameraCard(context),
          const SizedBox(height: 16),
          _buildTtsStatusCard(context),
          const SizedBox(height: 16),
          _buildStorageInfoCard(context),
        ],
      ),
    );
  }

  Widget _buildLlmModelCard(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.smart_toy, color: Colors.blue),
                const SizedBox(width: 8),
                const Text(
                  '大语言模型 (LLM)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Consumer<ModelDownloadService>(
                  builder: (context, downloadService, child) {
                    if (downloadService.needsUpdate) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '可更新',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Consumer<ModelDownloadService>(
              builder: (context, downloadService, child) {
                if (!downloadService.isDownloadComplete) {
                  return const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('状态: 未下载', style: TextStyle(color: Colors.red)),
                      SizedBox(height: 8),
                      Text(
                        '点击下方按钮下载模型',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '状态: 已下载',
                      style: TextStyle(color: Colors.green),
                    ),
                    if (downloadService.currentModelVersion != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '版本: ${downloadService.currentModelVersion}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    if (downloadService.lastUpdateTime != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '更新时间: ${_formatDate(downloadService.lastUpdateTime!)}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            Consumer<InferenceService>(
              builder: (context, inferenceService, child) {
                if (!inferenceService.isModelLoaded) {
                  return const Text('加载状态: 未加载');
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('加载状态: 已加载'),
                    if (inferenceService.modelName != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('模型名称: ${inferenceService.modelName}'),
                      ),
                    if (inferenceService.modelSize != null)
                      Text('模型大小: ${inferenceService.modelSize}'),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            Consumer<ModelDownloadService>(
              builder: (context, downloadService, child) {
                if (downloadService.llmModelFilePath != null) {
                  return Column(
                    children: [
                      Text(
                        '文件路径: ${downloadService.llmModelFilePath}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.grey,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor:
                                    downloadService.isDownloadComplete
                                    ? Colors.orange
                                    : Colors.blue,
                              ),
                              onPressed: () async {
                                if (downloadService.isDownloadComplete) {
                                  // 强制重新下载
                                  await downloadService.downloadModel(
                                    force: true,
                                  );
                                } else {
                                  await downloadService.downloadModel();
                                }
                              },
                              child: Text(
                                downloadService.isDownloadComplete
                                    ? '重新下载'
                                    : '下载模型',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                              ),
                              onPressed: () async {
                                showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('确认删除'),
                                    content: const Text(
                                      '确定要删除已下载的模型吗？\n删除后需要重新下载。',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx),
                                        child: const Text('取消'),
                                      ),
                                      TextButton(
                                        onPressed: () async {
                                          Navigator.pop(ctx);
                                          await downloadService.clearCache();
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              const SnackBar(
                                                content: Text('模型已删除'),
                                              ),
                                            );
                                          }
                                        },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.red,
                                        ),
                                        child: const Text(
                                          '删除',
                                          style: TextStyle(color: Colors.white),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                              child: const Text(
                                '删除',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(String dateStr) {
    try {
      final dt = DateTime.parse(dateStr);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return dateStr;
    }
  }

  Widget _buildSpeechModelCard(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Consumer<VoiceService>(
              builder: (context, voiceService, child) {
                return Row(
                  children: [
                    const Icon(Icons.mic, color: Colors.green),
                    const SizedBox(width: 8),
                    Text(
                      '语音识别模型 (${voiceService.modelName})',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            Consumer<VoiceService>(
              builder: (context, voiceService, child) {
                if (voiceService.isDownloading) {
                  return Column(
                    children: [
                      Text('状态: 下载中 ${voiceService.downloadProgress}%'),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: voiceService.downloadProgress / 100,
                      ),
                    ],
                  );
                }
                if (!voiceService.isModelDownloaded) {
                  return Column(
                    children: [
                      ElevatedButton(
                        onPressed: () => voiceService.downloadModel(),
                        child: const Text('下载语音模型'),
                      ),
                      const SizedBox(height: 12),
                      if (voiceService.errorMessage != null)
                        Text(
                          '错误: ${voiceService.errorMessage}',
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 12,
                          ),
                        ),
                      const SizedBox(height: 12),
                      const Text(
                        '手动下载指引:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Qwen3-ASR-1.7B INT8 ONNX模型共约2.24 GiB，'
                        '首次下载完成后可完全离线使用。支持断点续传，'
                        '已有Q4 GGUF、VibeVoice、Moonshine、Gemma和YOLO模型'
                        '不会被删除。\n\n'
                        '手机端下载仓库:\n'
                        'https://www.modelscope.cn/models/zengshuishui/'
                        'Qwen3-ASR-onnx\n\n'
                        '仅下载:\n'
                        'model_1.7B/conv_frontend.onnx\n'
                        'model_1.7B/encoder.int8.onnx\n'
                        'model_1.7B/decoder.int8.onnx\n'
                        'tokenizer/merges.txt\n'
                        'tokenizer/tokenizer_config.json\n'
                        'tokenizer/vocab.json',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    const Text(
                      '状态: 已下载',
                      style: TextStyle(color: Colors.green),
                    ),
                    const SizedBox(height: 8),
                    Text('模型名称: ${voiceService.modelName}'),
                    if (voiceService.modelSize != null) ...[
                      const SizedBox(height: 8),
                      Text('模型大小: ${voiceService.modelSize}'),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                            ),
                            onPressed: () async {
                              await voiceService.clearModelFiles();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('模型已删除')),
                              );
                            },
                            child: const Text(
                              '删除模型',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              await voiceService.clearModelFiles();
                              await voiceService.downloadModel();
                            },
                            child: const Text('重新下载'),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTtsStatusCard(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.volume_up, color: Colors.orange),
                SizedBox(width: 8),
                Text(
                  '文字转语音 (TTS)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Consumer<TtsService>(
              builder: (context, ttsService, child) {
                if (!ttsService.isInitialized) {
                  return ElevatedButton(
                    onPressed: () => ttsService.init(),
                    child: const Text('初始化TTS'),
                  );
                }
                return Column(
                  children: [
                    const Text(
                      '状态: 已初始化',
                      style: TextStyle(color: Colors.green),
                    ),
                    const SizedBox(height: 8),
                    if (ttsService.availableLanguages.isNotEmpty)
                      Text('可用语言: ${ttsService.availableLanguages.join(', ')}'),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildYoloModelCard(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.visibility, color: Colors.teal),
                SizedBox(width: 8),
                Text(
                  'YOLO26 障碍物探测',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('状态: 已随App打包', style: TextStyle(color: Colors.green)),
            const SizedBox(height: 6),
            const Text(
              '运行模型: yolo26n_w8a32.tflite (LiteRT)',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            Consumer<HardwareVisionService>(
              builder: (context, service, child) {
                return Text(
                  service.isRunning ? '实时视觉: 运行中' : '实时视觉: 未启动',
                  style: TextStyle(
                    color: service.isRunning ? Colors.green : Colors.grey,
                    fontSize: 12,
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const HardwareVisionScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.videocam),
                label: const Text('打开实时视觉'),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '视觉指导与障碍物提示仅作显示，不会自动控制雷达模块。',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUvcCameraCard(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.usb, color: Colors.indigo),
                SizedBox(width: 8),
                Text(
                  'USB 摄像头 (UVC)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              '通过 OTG 连接 USB 摄像头，基于 libuvc 原生方案。',
              style: TextStyle(fontSize: 12),
            ),
            const Text(
              '支持 YOLO 实时检测与拍照分析，与手机内置摄像头互补。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const UvcVisionScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.videocam),
                label: const Text('打开 USB 摄像头视觉'),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '需要 Android USB Host（OTG）支持，并首次连接时授予 USB 权限。',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStorageInfoCard(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.storage, color: Colors.purple),
                SizedBox(width: 8),
                Text('存储信息', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            Consumer<ModelDownloadService>(
              builder: (context, downloadService, child) {
                if (downloadService.isDownloadComplete) {
                  return const Text('模型占用: 约 2.4GB (Gemma 4 E2B)');
                }
                return const Text('模型占用: 0MB');
              },
            ),
            const SizedBox(height: 8),
            Consumer<VoiceService>(
              builder: (context, voiceService, child) {
                if (voiceService.isModelDownloaded &&
                    voiceService.modelSize != null) {
                  return Text('语音模型占用: ${voiceService.modelSize}');
                }
                return const Text('语音模型占用: 0MB');
              },
            ),
            const SizedBox(height: 8),
            const Text('YOLO模型占用: 约 8.0MB（已随App打包）'),
          ],
        ),
      ),
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../services/inference_service.dart';
import '../services/tts_service.dart';

class ImageAnalysisScreen extends StatefulWidget {
  const ImageAnalysisScreen({super.key});

  @override
  State<ImageAnalysisScreen> createState() => _ImageAnalysisScreenState();
}

class _ImageAnalysisScreenState extends State<ImageAnalysisScreen> {
  final ImagePicker _imagePicker = ImagePicker();
  String? _currentImagePath;
  String _analysisResult = '点击下方按钮拍照或选择图片进行分析';
  bool _isAnalyzing = false;
  bool _ttsEnabled = true;

  Future<void> _captureAndAnalyze() async {
    try {
      final pickedFile = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 80,
      );

      if (pickedFile != null) {
        await _analyzeImage(pickedFile.path);
      }
    } catch (e) {
      setState(() {
        _analysisResult = '拍照失败: ${e.toString().substring(0, 50)}';
      });
    }
  }

  Future<void> _pickAndAnalyze() async {
    try {
      final pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
      );

      if (pickedFile != null) {
        await _analyzeImage(pickedFile.path);
      }
    } catch (e) {
      setState(() {
        _analysisResult = '选择图片失败: ${e.toString().substring(0, 50)}';
      });
    }
  }

  Future<void> _analyzeImage(String imagePath) async {
    setState(() {
      _isAnalyzing = true;
      _currentImagePath = imagePath;
      _analysisResult = '正在分析图片...';
    });

    try {
      final inferenceService = Provider.of<InferenceService>(
        context,
        listen: false,
      );

      if (!inferenceService.isModelLoaded) {
        setState(() {
          _analysisResult = '模型未加载，请先返回下载模型';
        });
        return;
      }

      final response = await inferenceService.generateWithTools(
        '请详细描述这张图片中的内容，包括物体名称、颜色、特征、可能的用途等。如果是食物或饮品，请描述其外观、口感和营养价值。',
        imagePath: imagePath,
      );

      if (response.type == InferenceResponseType.text && response.text != null) {
        setState(() {
          _analysisResult = response.text!;
        });

        if (_ttsEnabled) {
          if (!mounted) return;
          final ttsService = Provider.of<TtsService>(
            context,
            listen: false,
          );
          await ttsService.speak(response.text!);
        }
      }
    } catch (e) {
      setState(() {
        _analysisResult = '分析失败: ${e.toString().substring(0, 50)}';
      });
    } finally {
      setState(() {
        _isAnalyzing = false;
      });
    }
  }

  void _toggleTts() {
    setState(() {
      _ttsEnabled = !_ttsEnabled;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('图像分析'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
        actions: [
          IconButton(
            icon: Icon(_ttsEnabled ? Icons.volume_up : Icons.volume_off),
            onPressed: _toggleTts,
            tooltip: _ttsEnabled ? '关闭语音播报' : '开启语音播报',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (_currentImagePath != null)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                height: 300,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  image: DecorationImage(
                    image: FileImage(File(_currentImagePath!)),
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '分析结果',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (_isAnalyzing)
                    const Center(child: CircularProgressIndicator())
                  else
                    Text(
                      _analysisResult,
                      style: const TextStyle(fontSize: 14, height: 1.5),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FloatingActionButton(
            onPressed: _isAnalyzing ? null : _captureAndAnalyze,
            heroTag: 'camera',
            tooltip: '拍照分析',
            child: _isAnalyzing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(color: Colors.white),
                  )
                : const Icon(Icons.camera_alt),
          ),
          const SizedBox(width: 24),
          FloatingActionButton(
            onPressed: _isAnalyzing ? null : _pickAndAnalyze,
            heroTag: 'gallery',
            tooltip: '从相册选择',
            child: const Icon(Icons.photo_library),
          ),
        ],
      ),
      bottomNavigationBar: const BottomAppBar(
        child: SizedBox(height: 56),
      ),
    );
  }
}
import 'package:image_picker/image_picker.dart';

/// 拍照 / 相册选图服务
///
/// 供聊天气泡的"拍照"按钮与图像流程获取图片文件路径。
/// 注意：与"摄像头实时视觉"(HardwareVisionService/UvcCameraService) 无关——
/// 这里只是单帧图片采集。
class PhotoService {
  final ImagePicker _imagePicker = ImagePicker();

  Future<String?> takePhoto() async {
    try {
      final pickedFile = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 80,
      );

      return pickedFile?.path;
    } catch (e) {
      throw Exception('拍照失败: $e');
    }
  }

  Future<String?> pickImage() async {
    try {
      final pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
      );

      return pickedFile?.path;
    } catch (e) {
      throw Exception('选择图片失败: $e');
    }
  }
}
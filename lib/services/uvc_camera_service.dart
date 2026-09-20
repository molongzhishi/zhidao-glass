import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'camera_source.dart';

enum UvcDeviceEventType {
  attached,
  detached,
  connected,
  disconnected,
  permissionDenied,
}

class UvcDeviceEvent {
  const UvcDeviceEvent({required this.type, required this.device});

  final UvcDeviceEventType type;
  final UvcDevice device;

  static UvcDeviceEventType _typeFromString(String raw) {
    switch (raw) {
      case 'attached':
        return UvcDeviceEventType.attached;
      case 'detached':
        return UvcDeviceEventType.detached;
      case 'connected':
        return UvcDeviceEventType.connected;
      case 'disconnected':
        return UvcDeviceEventType.disconnected;
      case 'permission_denied':
        return UvcDeviceEventType.permissionDenied;
      default:
        return UvcDeviceEventType.connected;
    }
  }

  static UvcDeviceEvent? fromMap(Map<dynamic, dynamic> map) {
    final deviceRaw = map['device'];
    if (deviceRaw is! Map) return null;
    return UvcDeviceEvent(
      type: _typeFromString(map['type'] as String? ?? 'connected'),
      device: UvcDevice.fromMap(deviceRaw),
    );
  }
}

class UvcDevice {
  const UvcDevice({
    required this.name,
    required this.vendorId,
    required this.productId,
    required this.deviceClass,
    this.productName = '',
    this.manufacturerName = '',
  });

  final String name;
  final int vendorId;
  final int productId;
  final int deviceClass;
  final String productName;
  final String manufacturerName;

  factory UvcDevice.fromMap(Map<dynamic, dynamic> map) {
    return UvcDevice(
      name: map['name'] as String? ?? '',
      vendorId: (map['vendorId'] as num?)?.toInt() ?? 0,
      productId: (map['productId'] as num?)?.toInt() ?? 0,
      deviceClass: (map['deviceClass'] as num?)?.toInt() ?? 0,
      productName: map['productName'] as String? ?? '',
      manufacturerName: map['manufacturerName'] as String? ?? '',
    );
  }

  String get label {
    if (productName.isNotEmpty) return productName;
    final vid = vendorId.toRadixString(16).padLeft(4, '0');
    final pid = productId.toRadixString(16).padLeft(4, '0');
    return 'USB 摄像头($vid:$pid)';
  }
}

class UvcPreviewInfo {
  const UvcPreviewInfo({
    required this.textureId,
    required this.width,
    required this.height,
  });

  final int textureId;
  final int width;
  final int height;
}

enum UvcCameraStatusEventType { frameTimeout, frameRecovered }

class UvcCameraStatusEvent {
  const UvcCameraStatusEvent({required this.type, required this.message});

  final UvcCameraStatusEventType type;
  final String message;
}

/// USB 摄像头（UVC）服务
///
/// 通过原生 UVC 插件（com.banai.zhidao_app/uvc）枚举/连接外接摄像头并预览。
/// 与内置摄像头视觉（HardwareVisionService）解耦；画面帧转交视觉服务做检测，
/// 喂给 [UvcCameraListener]，并在 frameTimeout 内无帧时发出故障状态事件。
class UvcCameraService extends ChangeNotifier implements UvcOpenState {
  static const Duration frameTimeout = Duration(seconds: 10);
  static const Duration _watchdogInterval = Duration(seconds: 1);

  static const MethodChannel _channel = MethodChannel(
    'com.banai.zhidao_app/uvc',
  );
  static const EventChannel _deviceEvents = EventChannel(
    'com.banai.zhidao_app/uvc/device_events',
  );
  static const EventChannel _frameEvents = EventChannel(
    'com.banai.zhidao_app/uvc/frame_events',
  );

  bool _supportedChecked = false;
  bool _supported = false;
  bool _opened = false;
  UvcPreviewInfo? _preview;
  String? _errorMessage;
  String? _notice;
  List<UvcDevice> _devices = const [];
  StreamSubscription<dynamic>? _frameSubscription;
  StreamController<UvcDeviceEvent>? _deviceEventController;
  final StreamController<UvcCameraStatusEvent> _statusEventController =
      StreamController<UvcCameraStatusEvent>.broadcast();
  Timer? _frameWatchdog;
  Timer? _noticeTimer;
  DateTime? _lastFrameTime;
  String? _openedDeviceName;
  String? _lastOpenedDeviceName;
  int _requestedWidth = 1280;
  int _requestedHeight = 720;
  bool _awaitingResetConfirmation = false;
  bool _resetDeclinedForCurrentStall = false;

  /// 是否存在"帧流卡死"故障：等待重置确认期间，或用户暂缓重置但帧尚未恢复？
  @override
  bool get hasFrameStallFault =>
      _awaitingResetConfirmation || _resetDeclinedForCurrentStall;
  bool _resetting = false;

  bool get isSupported => _supported;
  @override
  bool get isOpened => _opened;
  bool get isResetting => _resetting;
  bool get awaitingResetConfirmation => _awaitingResetConfirmation;
  UvcPreviewInfo? get preview => _preview;
  String? get errorMessage => _errorMessage;
  String? get notice => _notice;
  List<UvcDevice> get devices => _devices;
  Stream<UvcCameraStatusEvent> get statusEvents =>
      _statusEventController.stream;

  @override
  int? get previewWidth => _preview?.width;

  @override
  int? get previewHeight => _preview?.height;

  Stream<UvcDeviceEvent> get deviceEvents {
    _deviceEventController ??= StreamController<UvcDeviceEvent>.broadcast();
    _deviceEvents.receiveBroadcastStream().listen((event) {
      final parsed = UvcDeviceEvent.fromMap(
        (event as Map).cast<dynamic, dynamic>(),
      );
      if (parsed != null) {
        _deviceEventController!.add(parsed);
      }
    });
    return _deviceEventController!.stream;
  }

  Stream<Uint8List> get frameStream =>
      _frameEvents.receiveBroadcastStream().cast<Uint8List>();

  Future<bool> checkSupported() async {
    if (_supportedChecked) return _supported;
    _supportedChecked = true;
    try {
      _supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (e) {
      _supported = false;
    }
    notifyListeners();
    return _supported;
  }

  Future<List<UvcDevice>> listDevices() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listDevices');
      _devices = (raw ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map(UvcDevice.fromMap)
          .toList();
      _errorMessage = null;
    } catch (e) {
      _errorMessage = '枚举 USB 设备失败: $e';
    }
    notifyListeners();
    return _devices;
  }

  Future<bool> requestPermission(String name) async {
    try {
      final granted = await _channel.invokeMethod<bool>('requestPermission', {
        'name': name,
      });
      _errorMessage = null;
      return granted ?? false;
    } catch (e) {
      _errorMessage = '请求 USB 权限失败: $e';
      notifyListeners();
      return false;
    }
  }

  Future<UvcPreviewInfo> open(
    String name, {
    int width = 1280,
    int height = 720,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'open',
        {'name': name, 'width': width, 'height': height},
      );
      if (result == null) {
        throw Exception('open 返回为空');
      }
      _preview = UvcPreviewInfo(
        textureId: (result['textureId'] as num).toInt(),
        width: (result['width'] as num).toInt(),
        height: (result['height'] as num).toInt(),
      );
      _opened = true;
      _openedDeviceName = name;
      _lastOpenedDeviceName = name;
      _requestedWidth = width;
      _requestedHeight = height;
      _errorMessage = null;
      if (!_resetting) {
        _notice = null;
      }
      notifyListeners();
      return _preview!;
    } catch (e) {
      _errorMessage = '打开 USB 摄像头失败: $e';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> startFrameStream() async {
    try {
      await _channel.invokeMethod<void>('startFrameStream');
      _lastFrameTime = DateTime.now();
      _awaitingResetConfirmation = false;
      _resetDeclinedForCurrentStall = false;
      _startFrameWatchdog();
    } catch (e) {
      _errorMessage = '启动 USB 摄像头帧流失败: $e';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> stopFrameStream() async {
    _stopFrameWatchdog();
    _lastFrameTime = null;
    await _channel.invokeMethod<void>('stopFrameStream');
  }

  void markFrameReceived() {
    _lastFrameTime = DateTime.now();
    final wasWaitingForRecovery =
        _awaitingResetConfirmation || _resetDeclinedForCurrentStall;
    if (!wasWaitingForRecovery) return;

    _awaitingResetConfirmation = false;
    _resetDeclinedForCurrentStall = false;
    if (_resetting) return;

    const message = 'USB 摄像头图像帧已恢复，无需重置';
    _setNotice(message, clearAfter: const Duration(seconds: 4));
    _statusEventController.add(
      const UvcCameraStatusEvent(
        type: UvcCameraStatusEventType.frameRecovered,
        message: message,
      ),
    );
  }

  void declineReset() {
    if (!_awaitingResetConfirmation) return;
    _awaitingResetConfirmation = false;
    _resetDeclinedForCurrentStall = true;
    _setNotice('已取消摄像头重置，将继续等待新图像帧');
  }

  Future<bool> resetCamera() async {
    if (_resetting) {
      _errorMessage = 'USB 摄像头正在重置';
      notifyListeners();
      return false;
    }

    final deviceName = _openedDeviceName ?? _lastOpenedDeviceName;
    if (deviceName == null) {
      _errorMessage = '没有可重置的 USB 摄像头';
      notifyListeners();
      return false;
    }

    final width = _requestedWidth;
    final height = _requestedHeight;
    _resetting = true;
    _awaitingResetConfirmation = false;
    _resetDeclinedForCurrentStall = false;
    _errorMessage = null;
    _setNotice('正在重置 USB 摄像头...');
    _stopFrameWatchdog();

    try {
      await close();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await open(deviceName, width: width, height: height);
      await startFrameStream();
      _setNotice('USB 摄像头已重置，正在等待新图像帧', clearAfter: const Duration(seconds: 4));
      return true;
    } catch (e) {
      _errorMessage = 'USB 摄像头重置失败: $e';
      _setNotice(_errorMessage!);
      return false;
    } finally {
      _resetting = false;
      notifyListeners();
    }
  }

  Future<String?> takePicture() async {
    try {
      final path = await _channel.invokeMethod<String>('takePicture');
      _errorMessage = null;
      return path;
    } catch (e) {
      _errorMessage = '拍照失败: $e';
      notifyListeners();
      return null;
    }
  }

  Future<void> close() async {
    _stopFrameWatchdog();
    _noticeTimer?.cancel();
    try {
      await stopFrameStream();
    } catch (_) {}
    try {
      await _channel.invokeMethod<void>('close');
    } catch (_) {}
    _opened = false;
    _openedDeviceName = null;
    _preview = null;
    _lastFrameTime = null;
    _awaitingResetConfirmation = false;
    _resetDeclinedForCurrentStall = false;
    notifyListeners();
  }

  void _startFrameWatchdog() {
    _frameWatchdog?.cancel();
    _frameWatchdog = Timer.periodic(
      _watchdogInterval,
      (_) => _checkFrameTimeout(),
    );
  }

  void _stopFrameWatchdog() {
    _frameWatchdog?.cancel();
    _frameWatchdog = null;
  }

  void _checkFrameTimeout() {
    if (!_opened ||
        _resetting ||
        _awaitingResetConfirmation ||
        _resetDeclinedForCurrentStall) {
      return;
    }
    final lastFrameTime = _lastFrameTime;
    if (lastFrameTime == null ||
        DateTime.now().difference(lastFrameTime) < frameTimeout) {
      return;
    }

    _awaitingResetConfirmation = true;
    const message =
        'USB 摄像头已连续 10 秒没有新的图像帧，可能发生故障。是否重置摄像头？请在聊天中通过文字或语音回复“重置”或“暂不重置”。';
    _setNotice(message);
    _statusEventController.add(
      const UvcCameraStatusEvent(
        type: UvcCameraStatusEventType.frameTimeout,
        message: message,
      ),
    );
  }

  void _setNotice(String? value, {Duration? clearAfter}) {
    _noticeTimer?.cancel();
    _notice = value;
    notifyListeners();
    if (value == null || clearAfter == null) return;
    _noticeTimer = Timer(clearAfter, () {
      if (_notice == value) {
        _notice = null;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _stopFrameWatchdog();
    _noticeTimer?.cancel();
    _frameSubscription?.cancel();
    _deviceEventController?.close();
    _statusEventController.close();
    super.dispose();
  }
}

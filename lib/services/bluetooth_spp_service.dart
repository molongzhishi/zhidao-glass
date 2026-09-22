import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 统一蓝牙设备模型（BLE + 经典蓝牙）
class BluetoothDeviceItem {
  final String address;
  final String name;
  final int rssi;
  final bool isClassic; // true=经典蓝牙, false=BLE

  BluetoothDeviceItem({
    required this.address,
    required this.name,
    required this.rssi,
    required this.isClassic,
  });
}

/// 蓝牙SPP服务 - 负责与外部蓝牙设备进行串口通信
/// 支持 BLE GATT 和经典蓝牙 SPP 双协议
class BluetoothSppService extends ChangeNotifier {
  BluetoothSppService._();
  
  factory BluetoothSppService() {
    return _instance;
  }
  
  static final BluetoothSppService _instance = BluetoothSppService._();
  static BluetoothSppService get instance => _instance;

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _txCharacteristic;
  BluetoothCharacteristic? _rxCharacteristic;

  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  /// 持久的事件通道监听：扫描结果与 SPP 接收数据各自独立通道
  StreamSubscription<dynamic>? _scanEventSubscription;
  StreamSubscription<dynamic>? _sppEventSubscription;
  Timer? _sppResubscribeTimer;
  Timer? _scanResubscribeTimer;
  bool _disposed = false;

  /// SPP 原始行数据广播流，供雷达预警等业务订阅
  final StreamController<String> _sppDataController =
      StreamController<String>.broadcast();

  final List<ScanResult> _scanResults = [];
  final List<BluetoothDeviceItem> _classicDevices = [];
  final Map<String, String> _deviceNameCache = {};
  static const int _maxCachedDevices = 64;
  bool _isScanning = false;
  bool _isConnected = false;
  bool _isInitialized = false;
  String? _errorMessage;
  String _connectionStatus = '未连接';

  static const MethodChannel _channel = MethodChannel('com.banai.zhidao_app/bluetooth');
  static const EventChannel _scanEvents = EventChannel(
    'com.banai.zhidao_app/bluetooth/scan_events',
  );
  static const EventChannel _sppEvents = EventChannel(
    'com.banai.zhidao_app/bluetooth/spp_events',
  );

  bool get isScanning => _isScanning;
  bool get isConnected => _isConnected;
  bool get isInitialized => _isInitialized;
  List<ScanResult> get scanResults => _scanResults;
  List<BluetoothDeviceItem> get classicDevices => _classicDevices;
  String? get errorMessage => _errorMessage;
  String get connectionStatus => _connectionStatus;
  BluetoothDevice? get connectedDevice => _connectedDevice;
  bool get isBleConnection => _isBleConnection;
  bool get isSppConnection => _isSppConnection;

  /// 订阅 SPP 接收到的每一行原始数据（不包含连接状态事件）
  Stream<String> get sppDataStream => _sppDataController.stream;

  /// 初始化蓝牙服务 - 仅在用户打开蓝牙设置页面时调用
  Future<bool> init() async {
    if (_isInitialized) return true;

    try {
      // 检查蓝牙是否可用，但不强制开启
      final isSupported = await FlutterBluePlus.isSupported;
      if (!isSupported) {
        _errorMessage = '设备不支持蓝牙';
        notifyListeners();
        return false;
      }

      // 建立持久的事件通道监听：经典蓝牙扫描与 SPP 接收数据分别路由
      _subscribeScanEvents();
      _subscribeSppEvents();

      _isInitialized = true;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = '初始化失败: $e';
      notifyListeners();
      return false;
    }
  }

  /// 订阅经典蓝牙扫描事件通道；出错/完成自动重建订阅（防通道中途丢失）
  void _subscribeScanEvents() {
    if (_disposed) return;
    _scanEventSubscription?.cancel();
    _scanEventSubscription = _scanEvents
        .receiveBroadcastStream()
        .listen(
          _handleScanEvent,
          onError: (e) {
            debugPrint('[Bluetooth] 扫描事件通道错误: $e');
            _scheduleResubscribe(
              () => _subscribeScanEvents(),
              () => _scanResubscribeTimer,
              (t) => _scanResubscribeTimer = t,
            );
          },
          onDone: () {
            debugPrint('[Bluetooth] 扫描事件通道结束，重新订阅');
            _scheduleResubscribe(
              () => _subscribeScanEvents(),
              () => _scanResubscribeTimer,
              (t) => _scanResubscribeTimer = t,
            );
          },
        );
  }

  /// 订阅 SPP 数据事件通道；出错/完成自动重建订阅（防通道中途丢失）
  void _subscribeSppEvents() {
    if (_disposed) return;
    _sppEventSubscription?.cancel();
    _sppEventSubscription = _sppEvents
        .receiveBroadcastStream()
        .listen(
          _handleSppEvent,
          onError: (e) {
            debugPrint('[Bluetooth] SPP 事件通道错误: $e');
            _scheduleResubscribe(
              () => _subscribeSppEvents(),
              () => _sppResubscribeTimer,
              (t) => _sppResubscribeTimer = t,
            );
          },
          onDone: () {
            debugPrint('[Bluetooth] SPP 事件通道结束，重新订阅');
            _scheduleResubscribe(
              () => _subscribeSppEvents(),
              () => _sppResubscribeTimer,
              (t) => _sppResubscribeTimer = t,
            );
          },
        );
  }

  /// 防抖重建订阅：2s 后执行重建；期间多次错误只调度一次
  void _scheduleResubscribe(
    VoidCallback rebuild,
    Timer? Function() timerGet,
    void Function(Timer?) timerSet,
  ) {
    if (_disposed) return;
    if (timerGet() != null) return;
    timerSet(Timer(const Duration(seconds: 2), () {
      timerSet(null);
      rebuild();
    }));
  }

  /// 处理经典蓝牙扫描事件通道：设备发现 + 扫描结束
  void _handleScanEvent(dynamic event) {
    if (event is! Map) return;

    final action = event['action'];
    if (action == 'scan_finished') {
      debugPrint('[Bluetooth] 经典蓝牙扫描完成');
      _isScanning = false;
      notifyListeners();
      return;
    }
    _handleClassicDeviceEvent(event);
  }

  /// 处理 SPP 数据事件通道：串口接收到的原始数据 + 断连通知
  void _handleSppEvent(dynamic event) {
    if (event is! Map) return;
    if (_disposed) return;

    final action = event['action'] as String? ?? 'spp_data';
    if (action == 'spp_disconnected') {
      debugPrint('[Bluetooth] SPP 连接已断开');
      _markSppDisconnected();
      return;
    }

    final data = event['data'] as String? ?? '';
    if (data.isNotEmpty) {
      _emitSppData(data);
      debugPrint('[Bluetooth] SPP 接收: ${data.trim()}');
    }
  }

  /// 广播一行 SPP 数据；防御性检查控制器未被关闭（本单例从不主动 close）
  void _emitSppData(String data) {
    if (_disposed) return;
    if (_sppDataController.isClosed) return;
    _sppDataController.add(data);
  }

  /// 标记 SPP 连接断开（对端关闭 / 链路异常，非用户主动断开）
  void _markSppDisconnected() {
    if (!_isSppConnection) return;
    _isConnected = false;
    _isSppConnection = false;
    _connectedDevice = null;
    _connectionStatus = 'SPP 连接已断开';
    _errorMessage = null;
    notifyListeners();
  }

  /// 处理经典蓝牙设备扫描事件
  void _handleClassicDeviceEvent(Map event) {
    final address = event['address'] as String?;
    final name = event['name'] as String? ?? '';
    final rssi = (event['rssi'] as num?)?.toInt() ?? -100;

    if (address == null || address.isEmpty) return;
    // 缓存名称（带容量上限，防止长扫描期无界膨胀）
    if (name.isNotEmpty) {
      _cacheDeviceName(address, name);
    }

    // 去重
    final existingIndex = _classicDevices.indexWhere(
      (d) => d.address == address,
    );
    final device = BluetoothDeviceItem(
      address: address,
      name: name.isNotEmpty ? name : (_deviceNameCache[address] ?? '未知设备'),
      rssi: rssi,
      isClassic: true,
    );

    if (existingIndex < 0) {
      _classicDevices.add(device);
      debugPrint('[Bluetooth] 发现经典蓝牙设备: $name ($address)');
    } else {
      _classicDevices[existingIndex] = device;
    }

    _classicDevices.sort((a, b) => b.rssi.compareTo(a.rssi));
    notifyListeners();
  }

  /// 请求蓝牙权限 - 仅在用户主动操作时调用
  Future<bool> requestPermissions() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final statuses = await [
          Permission.bluetooth,
          Permission.bluetoothConnect,
          Permission.bluetoothScan,
          Permission.location,
        ].request();

        final allGranted = statuses.values.every((status) => status.isGranted);
        if (!allGranted) {
          _errorMessage = '蓝牙权限未完全授予';
          notifyListeners();
          return false;
        }
      }
      return true;
    } catch (e) {
      _errorMessage = '权限请求失败: $e';
      notifyListeners();
      return false;
    }
  }

  /// 开始扫描蓝牙设备（同时扫描 BLE 和经典蓝牙）
  Future<void> startScan() async {
    try {
      _scanResults.clear();
      _classicDevices.clear();
      _isScanning = true;
      _errorMessage = null;
      notifyListeners();

      // 1. 启动 BLE 扫描
      _scanResultsSubscription = FlutterBluePlus.scanResults.listen(
        (results) {
          for (final result in results) {
            final existingIndex = _scanResults.indexWhere(
              (r) => r.device.remoteId == result.device.remoteId,
            );
            if (existingIndex < 0) {
              _scanResults.add(result);
            } else {
              _scanResults[existingIndex] = result;
            }
          }
          _scanResults.sort((a, b) => b.rssi.compareTo(a.rssi));
          notifyListeners();
        },
        onError: (e) {
          debugPrint('[Bluetooth] BLE 扫描错误: $e');
        },
      );

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
      );

      // 2. 同时启动经典蓝牙扫描
      _startClassicScan();

      _isScanning = false;
      notifyListeners();
    } catch (e) {
      _errorMessage = '扫描失败: $e';
      _isScanning = false;
      notifyListeners();
    }
  }

  /// 启动经典蓝牙扫描（扫描结果由 init 时建立的持久监听路由）
  void _startClassicScan() {
    _channel.invokeMethod('startClassicScan').catchError((e) {
      debugPrint('[Bluetooth] 启动经典蓝牙扫描失败: $e');
    });
  }

  /// 获取系统已配对设备列表
  Future<List<Map<String, String>>> getBondedDevices() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return [];
    }
    
    try {
      final List<dynamic> result = await _channel.invokeMethod('getBondedDevices');
      final devices = result.map((e) => Map<String, String>.from(e as Map)).toList();
      
      // 缓存已配对设备的名称
      for (final device in devices) {
        final address = device['address'] ?? '';
        final name = device['name'] ?? '';
        if (address.isNotEmpty && name.isNotEmpty) {
          _cacheDeviceName(address, name);
        }
      }
      
      debugPrint('[Bluetooth] 获取到 ${devices.length} 个已配对设备');
      return devices;
    } catch (e) {
      debugPrint('[Bluetooth] 获取已配对设备失败: $e');
      return [];
    }
  }

  /// 缓存设备名称，容量达到 [_maxCachedDevices] 时淘汰最早写入的条目
  void _cacheDeviceName(String address, String name) {
    if (name.isEmpty) return;
    if (!_deviceNameCache.containsKey(address) &&
        _deviceNameCache.length >= _maxCachedDevices) {
      final oldest = _deviceNameCache.keys.first;
      _deviceNameCache.remove(oldest);
    }
    _deviceNameCache[address] = name;
  }

  /// 从扫描结果中获取设备显示名称
  String getDeviceDisplayName(ScanResult result) {
    final device = result.device;
    final adv = result.advertisementData;
    final address = device.remoteId.toString();

    // 优先级：
    // 1. 已配对设备缓存（系统保存的名称）
    if (_deviceNameCache.containsKey(address)) {
      return _deviceNameCache[address]!;
    }
    
    // 2. 广播名称（设备主动广播的名称）
    if (adv.advName.isNotEmpty) return adv.advName;
    
    // 3. 平台名称（系统已知的名称）
    if (device.platformName.isNotEmpty) return device.platformName;

    // 4. 厂商ID识别
    if (adv.manufacturerData.isNotEmpty) {
      final manufacturerId = adv.manufacturerData.keys.first;
      final manufacturerName = _getManufacturerName(manufacturerId);
      if (manufacturerName.isNotEmpty) {
        return '$manufacturerName 设备';
      }
    }

    // 5. MAC地址后段作为兜底
    final macStr = device.remoteId.toString();
    final lastSegment = macStr.length >= 8 ? macStr.substring(macStr.length - 8) : macStr;
    return '未知设备 ($lastSegment)';
  }

  /// 通过连接设备获取真实名称（异步操作）
  Future<String?> fetchDeviceName(BluetoothDevice device) async {
    try {
      // 检查缓存
      final cachedName = device.platformName;
      if (cachedName.isNotEmpty) return cachedName;

      // 尝试连接获取名称
      await device.connect(timeout: const Duration(seconds: 5));
      await Future.delayed(const Duration(milliseconds: 500));

      final name = device.platformName;
      await device.disconnect();

      if (name.isNotEmpty) {
        debugPrint('[Bluetooth] 获取到设备名称: $name');
        return name;
      }
      return null;
    } catch (e) {
      debugPrint('[Bluetooth] 获取设备名称失败: $e');
      try {
        await device.disconnect();
      } catch (_) {}
      return null;
    }
  }

  /// 获取设备图标（根据外观或服务UUID）
  IconData getDeviceIcon(ScanResult result) {
    final adv = result.advertisementData;
    final appearance = adv.appearance;

    // 外观值映射（GAP Appearance）
    if (appearance != null) {
      final category = (appearance >> 6) & 0x3F;
      switch (category) {
        case 1: return Icons.phone_android;   // 手机
        case 2: return Icons.desktop_windows;  // 电脑
        case 3: return Icons.keyboard;          // 键盘
        case 4: return Icons.mouse;             // 鼠标
        case 5: return Icons.headphones;        // 音频设备
        case 6: return Icons.camera_alt;        // 摄像头
        case 13: return Icons.watch;            // 手表
        case 14: return Icons.speaker;          // 扬声器
        default: break;
      }
    }

    // 服务UUID判断
    for (final uuid in adv.serviceUuids) {
      final uuidStr = uuid.toString().toLowerCase();
      if (uuidStr.contains('110b')) return Icons.headphones;  // A2DP Source
      if (uuidStr.contains('110d')) return Icons.headphones;  // A2DP Sink
      if (uuidStr.contains('110e')) return Icons.mic;         // HFP
      if (uuidStr.contains('1112')) return Icons.phone_android; // HFP Audio
      if (uuidStr.contains('180a')) return Icons.sensors;    // 设备信息
      if (uuidStr.contains('180f')) return Icons.battery_full;     // 电池服务
      if (uuidStr.contains('1124')) return Icons.phone_android; // GATT Phone
    }

    // 厂商ID判断
    if (adv.manufacturerData.isNotEmpty) {
      final manufacturerId = adv.manufacturerData.keys.first;
      if (manufacturerId == 0x004C) return Icons.phone_iphone;   // Apple
      if (manufacturerId == 0x0075) return Icons.phone_android;  // Samsung
      if (manufacturerId == 0x00B0) return Icons.phone_android;  // Sony
      if (manufacturerId == 0x00DC) return Icons.headphones;     // Beats
      if (manufacturerId == 0x0045) return Icons.phone_android;  // Xiaomi
      if (manufacturerId == 0x0131) return Icons.phone_android;  // Huawei
      if (manufacturerId == 0x0006) return Icons.laptop;         // Microsoft
      if (manufacturerId == 0x011A) return Icons.mouse;           // Logitech
    }

    return Icons.bluetooth;
  }

  /// 获取信号强度描述
  String getSignalStrength(ScanResult result) {
    final rssi = result.rssi;
    if (rssi >= -50) return '极强';
    if (rssi >= -65) return '强';
    if (rssi >= -75) return '中等';
    return '弱';
  }

  /// 获取信号强度对应的图标颜色
  Color getSignalColor(ScanResult result) {
    final rssi = result.rssi;
    if (rssi >= -65) return Colors.green;
    if (rssi >= -75) return Colors.orange;
    return Colors.grey;
  }

  /// 厂商ID转名称
  String _getManufacturerName(int manufacturerId) {
    const manufacturers = {
      0x004C: 'Apple',
      0x0075: 'Samsung',
      0x00B0: 'Sony',
      0x00DC: 'Beats',
      0x0006: 'Microsoft',
      0x000F: 'Qualcomm',
      0x001D: 'Qualcomm',
      0x0037: 'Motorola',
      0x0045: 'Xiaomi',
      0x0055: 'Amazon',
      0x00E0: 'Google',
      0x00E8: 'OnePlus',
      0x011A: 'Logitech',
      0x0167: 'Nordic',
      0x0131: 'Huawei',
      0x0185: 'HUAWEI',
    };
    return manufacturers[manufacturerId] ?? '';
  }

  /// 停止扫描
  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
      await _scanResultsSubscription?.cancel();
      _scanResultsSubscription = null;
      await _channel.invokeMethod('stopClassicScan');
      _isScanning = false;
      notifyListeners();
    } catch (e) {
      _errorMessage = '停止扫描失败: $e';
      notifyListeners();
    }
  }

  /// 读取 SPP 密码。
  ///
  /// Android 上由原生侧经 Keystore 加密存储（见 MainActivity.saveSppPassword），
  /// 明文只存在于内存中；非 Android／原生不可用（如测试）时回退 SharedPreferences。
  Future<String> getSppPassword() async {
    try {
      final encrypted = await _channel.invokeMethod<String>('getSppPassword');
      if (encrypted != null) return encrypted;
    } catch (e) {
      debugPrint('[Bluetooth] Keystore 读取密码失败，回退本地存储: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('spp_password') ?? '';
  }

  /// 保存 SPP 连接密码。
  ///
  /// Android 上加密落盘（Keystore），不在 SharedPreferences 明文存储，
  /// 仅当加密写入成功后才清除历史明文键完成迁移；原生不可用时回退本地
  /// 存储（保证测试/非 Android 环境可用）。
  Future<void> setSppPassword(String password) async {
    final trimmed = password.trim();
    try {
      final ok = await _channel.invokeMethod<bool>('saveSppPassword', {
            'password': trimmed,
          }) ??
          false;
      if (ok) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('spp_password');
        return;
      }
      debugPrint('[Bluetooth] Keystore 保存密码失败，回退本地存储');
    } catch (e) {
      debugPrint('[Bluetooth] Keystore 保存密码失败，回退本地存储: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('spp_password', trimmed);
  }

  /// 组合 connectSpp 参数（地址 + 用户配置的密码）
  Future<Map<String, String>> _buildSppConnectArgs(String address) async {
    final password = await getSppPassword();
    return {'address': address, 'password': password};
  }

  /// 连接经典蓝牙设备（通过 MAC 地址）
  Future<bool> connectClassicDevice(BluetoothDeviceItem device) async {
    try {
      _connectionStatus = '正在连接 SPP...';
      _errorMessage = null;
      notifyListeners();

      final result =
          await _channel.invokeMethod('connectSpp', await _buildSppConnectArgs(device.address));

      if (result == true) {
        _isSppConnection = true;
        _isBleConnection = false;
        _isConnected = true;
        _connectionStatus = '已连接(SPP): ${device.name}';
        debugPrint('[Bluetooth] ✅ SPP 连接成功: ${device.name}');
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      _errorMessage = _describeSppError(e);
      _connectionStatus = '连接失败';
      debugPrint('[Bluetooth] SPP 连接失败: $e');
      notifyListeners();
      return false;
    }
  }

  String _describeSppError(Object e) {
    if (e is PlatformException && e.code == 'PASSWORD_NOT_SET') {
      return '未设置蓝牙连接密码，请先在“设置”中配置 SPP 密码';
    }
    return 'SPP 连接失败: $e';
  }

  /// 连接类型
  bool _isBleConnection = false;
  bool _isSppConnection = false;

  /// 连接到指定设备
  /// 优先尝试经典蓝牙 SPP，失败后自动回退到 BLE GATT
  Future<bool> connectToDevice(BluetoothDevice device) async {
    final address = device.remoteId.toString();
    String name = device.platformName;
    if (name.isEmpty) {
      name = _deviceNameCache[address] ?? '未知设备';
    }

    // 1. 先尝试经典蓝牙 SPP（ESP32-CAM 等设备使用）
    debugPrint('[Bluetooth] 尝试经典蓝牙 SPP 连接: $name ($address)');
    final sppSuccess = await _connectSpp(address, name);
    if (sppSuccess) {
      return true;
    }

    // 2. SPP 失败，尝试 BLE GATT 连接
    debugPrint('[Bluetooth] SPP 失败，尝试 BLE GATT 连接: $name');
    return await _connectBle(device, name);
  }

  /// 经典蓝牙 SPP 连接
  Future<bool> _connectSpp(String address, String name) async {
    try {
      _connectionStatus = '正在连接 SPP...';
      _errorMessage = null;
      notifyListeners();

      final result =
          await _channel.invokeMethod('connectSpp', await _buildSppConnectArgs(address));

      if (result == true) {
        _isSppConnection = true;
        _isBleConnection = false;
        _isConnected = true;
        _connectionStatus = '已连接(SPP): $name';
        debugPrint('[Bluetooth] ✅ SPP 连接成功: $name');
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[Bluetooth] SPP 连接失败: $e');
      return false;
    }
  }

  /// BLE GATT 连接
  Future<bool> _connectBle(BluetoothDevice device, String name) async {
    try {
      _connectionStatus = '正在连接 BLE...';
      notifyListeners();

      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _isConnected = false;
          _isBleConnection = false;
          _connectionStatus = '已断开';
          _connectedDevice = null;
          _txCharacteristic = null;
          _rxCharacteristic = null;
          notifyListeners();
        }
      });

      await device.connect(timeout: const Duration(seconds: 15));

      _connectedDevice = device;
      _isBleConnection = true;
      _isSppConnection = false;
      _connectionStatus = '已连接(BLE): $name';
      notifyListeners();

      await _discoverServices(device);
      return _isConnected;
    } catch (e) {
      _errorMessage = 'BLE 连接失败: $e';
      _connectionStatus = '连接失败';
      _isBleConnection = false;
      notifyListeners();
      return false;
    }
  }

  /// 发现服务和特征值
  Future<void> _discoverServices(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();

      // 优先查找SPP特征值
      for (final service in services) {
        for (final characteristic in service.characteristics) {
          if (characteristic.properties.write && _txCharacteristic == null) {
            _txCharacteristic = characteristic;
          }
          if (characteristic.properties.notify && _rxCharacteristic == null) {
            _rxCharacteristic = characteristic;
            await _setupNotification(characteristic);
          }
        }
      }

      if (_txCharacteristic != null) {
        _isConnected = true;
        _connectionStatus = '已连接: ${device.localName}';
        debugPrint('[Bluetooth] SPP连接成功');
      } else {
        _errorMessage = '未找到可写特征值';
        await disconnect();
      }
      notifyListeners();
    } catch (e) {
      _errorMessage = '服务发现失败: $e';
      notifyListeners();
    }
  }

  /// 设置通知监听
  Future<void> _setupNotification(BluetoothCharacteristic characteristic) async {
    try {
      characteristic.onValueReceived.listen((data) {
        final text = String.fromCharCodes(data);
        if (text.isNotEmpty) {
          _emitSppData(text);
          debugPrint('[Bluetooth] BLE 接收数据: $text');
        }
      });
      await characteristic.setNotifyValue(true);
    } catch (e) {
      debugPrint('[Bluetooth] 设置通知失败: $e');
    }
  }

  /// 断开连接
  Future<void> disconnect() async {
    try {
      // 断开 SPP 连接
      if (_isSppConnection) {
        await _channel.invokeMethod('disconnectSpp');
      }

      // 断开 BLE 连接
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;
      _scanResultsSubscription?.cancel();
      _scanResultsSubscription = null;

      if (_connectedDevice != null) {
        await _connectedDevice!.disconnect();
      }

      _connectedDevice = null;
      _txCharacteristic = null;
      _rxCharacteristic = null;
      _isConnected = false;
      _isBleConnection = false;
      _isSppConnection = false;
      _connectionStatus = '已断开';
      notifyListeners();
    } catch (e) {
      _errorMessage = '断开失败: $e';
      notifyListeners();
    }
  }

  /// 获取已连接设备列表
  Future<List<BluetoothDevice>> getConnectedDevices() async {
    try {
      return await FlutterBluePlus.connectedDevices;
    } catch (e) {
      _errorMessage = '获取已连接设备失败: $e';
      return [];
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sppResubscribeTimer?.cancel();
    _sppResubscribeTimer = null;
    _scanResubscribeTimer?.cancel();
    _scanResubscribeTimer = null;
    _scanEventSubscription?.cancel();
    _scanEventSubscription = null;
    _sppEventSubscription?.cancel();
    _sppEventSubscription = null;
    // 单例广播流不主动 close：否则任何迟到 add 会抛 StateError，
    // 且生命周期内需可继续被雷达订阅（关闭后的 StreamController 无法恢复）。
    disconnect();
    super.dispose();
  }
}

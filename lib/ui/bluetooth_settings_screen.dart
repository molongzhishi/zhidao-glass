import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../services/bluetooth_spp_service.dart';

class BluetoothSettingsScreen extends StatefulWidget {
  const BluetoothSettingsScreen({super.key});

  @override
  State<BluetoothSettingsScreen> createState() =>
      _BluetoothSettingsScreenState();
}

class _BluetoothSettingsScreenState extends State<BluetoothSettingsScreen> {
  bool _isFetchingNames = false;
  bool _isLoadingBondedDevices = false;
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initBluetooth();
      _loadSppPassword();
    });
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadSppPassword() async {
    final service = context.read<BluetoothSppService>();
    final password = await service.getSppPassword();
    if (mounted) {
      _passwordController.text = password;
    }
  }

  Future<void> _saveSppPassword() async {
    final service = context.read<BluetoothSppService>();
    final password = _passwordController.text.trim();
    if (password.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入通话设备匹配的蓝牙密码')),
        );
      }
      return;
    }
    await service.setSppPassword(password);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('蓝牙密码已保存')),
      );
    }
  }

  Future<void> _initBluetooth() async {
    final service = context.read<BluetoothSppService>();
    await service.requestPermissions();
    await service.init();
    
    // 获取系统已配对设备列表，缓存名称供扫描时使用
    setState(() => _isLoadingBondedDevices = true);
    final bondedDevices = await service.getBondedDevices();
    debugPrint('[Bluetooth] 已配对设备: ${bondedDevices.length} 个');
    setState(() => _isLoadingBondedDevices = false);
  }

  Future<void> _fetchDeviceNames() async {
    if (_isFetchingNames) return;

    setState(() => _isFetchingNames = true);

    final service = context.read<BluetoothSppService>();
    final results = List<ScanResult>.from(service.scanResults);

    final updatedResults = <ScanResult>[];
    int processed = 0;
    final total = results.length;

    for (final result in results) {
      final displayName = service.getDeviceDisplayName(result);
      final isUnknown = displayName.startsWith('未知设备');

      if (isUnknown) {
        debugPrint('[Bluetooth] 获取设备名称 ${result.device.remoteId} ($processed/$total)');
        final newName = await service.fetchDeviceName(result.device);

        if (newName != null && newName.isNotEmpty) {
          debugPrint('[Bluetooth] 获取到名称: $newName');
        }
      }

      updatedResults.add(result);
      processed++;

      if (mounted) {
        setState(() {});
      }
    }

    setState(() => _isFetchingNames = false);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已获取 $total 个设备的名称')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('蓝牙SPP设置'),
      ),
      body: Consumer<BluetoothSppService>(
        builder: (context, service, child) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSppPasswordCard(),
                const SizedBox(height: 16),
                _buildConnectionStatusCard(service),
                const SizedBox(height: 16),
                _buildScanSection(service),
                const SizedBox(height: 16),
                if (service.errorMessage != null)
                  _buildErrorWidget(service.errorMessage!),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSppPasswordCard() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.lock, color: Colors.orange),
                SizedBox(width: 8),
                Text(
                  'SPP 连接密码',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '与 ESP32-CAM 等服务端固件中设置的密码保持一致，'
              '保存在本机，不会写入代码或上传。未设置的设备将无法通过 SPP 连接。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: '蓝牙连接密码',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility
                        : Icons.visibility_off,
                  ),
                  onPressed: () {
                    setState(() => _obscurePassword = !_obscurePassword);
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saveSppPassword,
                icon: const Icon(Icons.save),
                label: const Text('保存密码'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionStatusCard(BluetoothSppService service) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  service.isConnected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  color: service.isConnected ? Colors.blue : Colors.grey,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        service.isConnected ? '已连接' : '未连接',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        service.connectionStatus,
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 13,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (service.isConnected) ...[
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () async {
                  await service.disconnect();
                },
                icon: const Icon(Icons.link_off),
                label: const Text('断开连接'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildScanSection(BluetoothSppService service) {
    return Card(
      elevation: 2,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '扫描设备',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (_isFetchingNames)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (service.isScanning)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else ...[
                      IconButton(
                        onPressed: service.scanResults.isNotEmpty && !_isFetchingNames
                            ? () => _fetchDeviceNames()
                            : null,
                        icon: const Icon(Icons.contact_page),
                        color: service.scanResults.isNotEmpty ? Colors.green : Colors.grey,
                        tooltip: '获取设备名称',
                      ),
                      IconButton(
                        onPressed: service.isScanning
                            ? () => service.stopScan()
                            : () => service.startScan(),
                        icon: Icon(
                          service.isScanning ? Icons.stop : Icons.search,
                        ),
                        color: Colors.blue,
                      ),
                    ],
                  ],
                ),
                if (_isFetchingNames)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(),
                  ),
                if (_isLoadingBondedDevices)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text('正在获取已配对设备...', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                if (!_isLoadingBondedDevices && service.scanResults.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '已识别 ${service.scanResults.where((r) => !service.getDeviceDisplayName(r).startsWith('未知')).length} 个设备',
                      style: const TextStyle(color: Colors.green, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(),
          if (service.scanResults.isEmpty && service.classicDevices.isEmpty && !service.isScanning)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                '点击搜索按钮扫描蓝牙设备',
                style: TextStyle(color: Colors.grey),
              ),
            )
          else if (service.scanResults.isEmpty && service.classicDevices.isEmpty && service.isScanning)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('正在搜索蓝牙设备...'),
                ],
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: service.scanResults.length + service.classicDevices.length,
              itemBuilder: (context, index) {
                // BLE 设备
                if (index < service.scanResults.length) {
                  final result = service.scanResults[index];
                  final device = result.device;
                  final isConnected = service.connectedDevice?.remoteId == device.remoteId;

                  final displayName = service.getDeviceDisplayName(result);
                  final deviceIcon = service.getDeviceIcon(result);
                  final signalStrength = service.getSignalStrength(result);
                  final signalColor = service.getSignalColor(result);

                  return ListTile(
                    leading: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(deviceIcon, color: isConnected ? Colors.blue : null, size: 28),
                        const SizedBox(height: 2),
                        Container(
                          width: 6, height: 6,
                          decoration: BoxDecoration(color: signalColor, shape: BoxShape.circle),
                        ),
                      ],
                    ),
                    title: Text(displayName, style: const TextStyle(fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Row(
                      children: [
                        Expanded(child: Text(device.remoteId.toString(), style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 8),
                        Text(signalStrength, style: TextStyle(fontSize: 11, color: signalColor)),
                      ],
                    ),
                    trailing: isConnected
                        ? TextButton(onPressed: () => service.disconnect(), child: const Text('断开', style: TextStyle(color: Colors.red)))
                        : ElevatedButton(onPressed: () => service.connectToDevice(device), child: const Text('连接')),
                  );
                }

                // 经典蓝牙设备
                final classicIndex = index - service.scanResults.length;
                final device = service.classicDevices[classicIndex];
                final signalStrength = device.rssi >= -50 ? '极强' : device.rssi >= -65 ? '强' : device.rssi >= -75 ? '中等' : '弱';
                final signalColor = device.rssi >= -65 ? Colors.green : device.rssi >= -75 ? Colors.orange : Colors.grey;

                return ListTile(
                  leading: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.bluetooth, color: Colors.blue, size: 28),
                      const SizedBox(height: 2),
                      Container(
                        width: 6, height: 6,
                        decoration: BoxDecoration(color: signalColor, shape: BoxShape.circle),
                      ),
                    ],
                  ),
                  title: Text(
                    device.name.isNotEmpty ? device.name : '未知设备',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Row(
                    children: [
                      Expanded(child: Text(device.address, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 8),
                      Text(signalStrength, style: TextStyle(fontSize: 11, color: signalColor)),
                    ],
                  ),
                  trailing: service.isConnected
                      ? TextButton(onPressed: () => service.disconnect(), child: const Text('断开', style: TextStyle(color: Colors.red)))
                      : ElevatedButton(onPressed: () => service.connectClassicDevice(device), child: const Text('连接')),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildErrorWidget(String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

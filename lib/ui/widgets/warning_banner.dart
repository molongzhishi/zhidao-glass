import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/bluetooth_receiver.dart';
import '../../services/warning_center.dart';

/// 统一报警横幅：聚合各类互解耦的警告来源，
/// 各自独立显示与复位。
class WarningBanner extends StatelessWidget {
  const WarningBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<WarningCenter>(
      builder: (context, warnings, _) {
        final active = warnings.activeWarningSources;
        if (active.isEmpty) {
          return const _RadarStatusBanner();
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: Colors.red.shade700,
              borderRadius: BorderRadius.circular(12),
              elevation: 6,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final source in active) _WarningItem(source: source),
                  ],
                ),
              ),
            ),
            const _RadarStatusBanner(),
          ],
        );
      },
    );
  }
}

/// 雷达通道自身的连接/降级状态横幅（非障碍物报警）
class _RadarStatusBanner extends StatelessWidget {
  const _RadarStatusBanner();

  @override
  Widget build(BuildContext context) {
    return Consumer<BluetoothReceiver>(
      builder: (context, radar, _) {
        if (!radar.isDegraded) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Material(
            color: Colors.orange.shade700,
            borderRadius: BorderRadius.circular(12),
            elevation: 4,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.bluetooth_disabled, color: Colors.white),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '蓝牙已断开：雷达预警不可用，当前仅依靠视觉检测',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WarningItem extends StatelessWidget {
  const _WarningItem({required this.source});

  final WarningSource source;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              WarningCenter.sourceLabel(source),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
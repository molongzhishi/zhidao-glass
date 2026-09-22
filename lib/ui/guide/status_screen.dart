import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../services/azimuth_mapper.dart';
import '../../services/bluetooth_spp_service.dart';
import '../../services/bluetooth_receiver.dart';
import '../../services/camera_source.dart';
import '../../services/camera_source_manager.dart';
import '../../services/voice_announcer.dart';
import '../../services/coco_labels_zh.dart';
import '../../services/fusion_warning_service.dart';
import '../../services/guide_state_service.dart';
import '../../services/vision_warning_service.dart';
import '../../services/warning_center.dart';
import '../bluetooth_settings_screen.dart';
import 'guide_widgets.dart';

/// 运行状态页（随需进入）
///
/// 聚合雷达 / 摄像头 / 播报三路实时状态与异常提示；
/// 提供「开始 / 停止分析」开关，显式点击时才启动 / 停止视觉分析通道。
/// 不主动实例化 YOLO，仅在用户点击开始时懒加载。
class StatusScreen extends StatefulWidget {
  const StatusScreen({super.key});

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<GuideStateService>().refreshPermissions(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kGuideBackground,
      appBar: AppBar(
        title: const Text('设备状态'),
        backgroundColor: kGuideBackground,
        foregroundColor: kGuideOnSurface,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新检查权限',
            onPressed: () =>
                context.read<GuideStateService>().refreshPermissions(),
          ),
        ],
      ),
      body: const _StatusBody(),
    );
  }
}

class _StatusBody extends StatelessWidget {
  const _StatusBody();

  @override
  Widget build(BuildContext context) {
    final bluetooth = context.watch<BluetoothSppService>();
    final radar = context.watch<BluetoothReceiver>();
    final vision = context.watch<VisionWarningService>();
    final fusion = context.watch<FusionWarningService>();
    final broadcast = context.watch<VoiceAnnouncer>();
    final camera = context.watch<CameraSourceManager>();
    final warnings = context.watch<WarningCenter>();
    final guide = context.watch<GuideStateService>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _AlertBlock(
          entries: [
            _AlertEntry.error(
              visible: radar.isDegraded || (bluetooth.isInitialized && !bluetooth.isConnected),
              icon: Icons.bluetooth_disabled,
              text: '蓝牙已断开：雷达预警不可用，当前仅依靠视觉检测',
              actionLabel: '去连接',
              onAction: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const BluetoothSettingsScreen(),
                ),
              ),
            ),
            _AlertEntry.warning(
              visible: radar.isRadarDataMissing,
              icon: Icons.sensors_off,
              text: '雷达已连接但未收到数据：请检查雷达模块是否正常工作',
            ),
            _AlertEntry.error(
              visible: !guide.cameraGranted,
              icon: Icons.videocam_off,
              text: '摄像头权限未开启：雷达触发后将无法取帧识别障碍物',
              actionLabel: '去开启',
              onAction: () async {
                await Permission.camera.request();
                guide.refreshPermissions();
              },
            ),
            _AlertEntry.error(
              visible: warnings.usbCameraFault,
              icon: Icons.usb,
              text: 'USB 摄像头故障：超过 10 秒未收到新帧',
            ),
            _AlertEntry.warning(
              visible: !guide.notificationGranted,
              icon: Icons.notifications_off,
              text: '通知权限未开启：影响后台监测提醒',
              actionLabel: '去开启',
              onAction: () async {
                await Permission.notification.request();
                guide.refreshPermissions();
              },
            ),
          ],
        ),
        const SizedBox(height: 16),

        // ── 雷达状态 ──────────────────────────────────────────────
        GuideCard(
          leading: const Icon(Icons.radar, color: kGuidePrimary),
          title: '雷达状态',
          trailing: StatusPill(
            text: bluetooth.isConnected ? '已连接' : '未连接',
            tone: bluetooth.isConnected ? PillTone.ok : PillTone.error,
          ),
          child: Column(
            children: [
              InfoRow(
                label: '链路',
                value: bluetooth.isConnected ? 'SPP 串口已建立' : '未连接 · 仅视觉',
                valueColor:
                    bluetooth.isConnected ? kGuideOnSurface : kGuideError,
              ),
              InfoRow(
                label: '障碍物',
                value: radar.hasObstacle ? radar.obstacleText : '前方无阻 · 通行正常',
                valueColor: radar.hasObstacle ? kGuideError : kGuideOk,
                icon: radar.hasObstacle ? Icons.warning_amber : Icons.check_circle,
                bold: radar.hasObstacle,
              ),
              InfoRow(
                label: '触发计数',
                value: '本会话 ${radar.radarTriggerCount} 次',
                valueColor:
                    radar.radarTriggerCount > 0 ? kGuideOnSurface : kGuideMuted,
              ),
              InfoRow(
                label: '最近触发',
                value: _fmtRadarTrigger(radar.lastRadarTriggerAt),
                valueColor: kGuideMuted,
              ),
              InfoRow(
                label: '最近数据',
                value: _fmtRadarTrigger(radar.lastRadarDataAt),
                valueColor: radar.lastRadarDataAt == null
                    ? (radar.isRadarDataMissing ? kGuideError : kGuideMuted)
                    : kGuideMuted,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // ── 实时视觉分析 ──────────────────────────────────────────
        GuideCard(
          leading: const Icon(Icons.visibility, color: kGuideWarning),
          title: '实时分析',
          trailing: StatusPill(
            text: vision.isRunning ? '分析中' : '已停止',
            tone: vision.isRunning ? PillTone.ok : PillTone.neutral,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InfoRow(
                label: '画面源',
                value: _activeSourceText(camera, vision),
                valueColor: vision.isRunning ? kGuideOnSurface : kGuideMuted,
              ),
              InfoRow(
                label: '识别物品',
                value: _recognizedItem(fusion),
                valueColor: _visionColor(fusion),
                bold: fusion.visionItem != null,
              ),
              if (fusion.visionItem?.hasTarget ?? false) ...[
                InfoRow(
                  label: '目标画面坐标',
                  value: _visionCoords(fusion),
                  valueColor: kGuideWarning,
                ),
                InfoRow(
                  label: '映射方位',
                  value: _frontAzimuth(fusion),
                  valueColor: kGuidePrimary,
                ),
              ],
              if (vision.lastObservations.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final o in vision.lastObservations.take(3))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: kGuideBorder,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${CocoLabelsZh.resolve(o.className)} · ${(o.weight * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                            color: kGuideOnSurface,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              if (!guide.cameraGranted) ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: kGuidePrimary,
                    ),
                    icon: const Icon(Icons.videocam, size: 18),
                    label: const Text(
                      '开启摄像头权限',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    onPressed: () async {
                      await Permission.camera.request();
                      guide.refreshPermissions();
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: vision.isRunning ? kGuideError : kGuideOk,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: Icon(
                    vision.isRunning ? Icons.stop_circle : Icons.play_arrow,
                    size: 20,
                  ),
                  label: Text(
                    vision.isRunning ? '停止分析' : '开始分析',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  onPressed: () {
                    final target = context.read<VisionWarningService>();
                    if (target.isRunning) {
                      target.stop();
                    } else {
                      target.start();
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // ── 最终播报文案 ──────────────────────────────────────────
        GuideCard(
          leading: const Icon(Icons.record_voice_over, color: kGuidePrimary),
          title: '最终播报文案',
          trailing: StatusPill(
            text: _broadcastPillText(broadcast),
            tone: _broadcastPillTone(broadcast),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                broadcast.currentSpeakText ??
                    broadcast.lastSpeakText ??
                    '暂无播报记录',
                style: TextStyle(
                  color: broadcast.currentSpeakText != null
                      ? kGuideOnSurface
                      : kGuideMuted,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                broadcast.isSpeaking
                    ? '正在播报中…'
                    : broadcast.isFallbackVibrating
                        ? 'TTS 不可用，当前采用振动提醒'
                        : broadcast.lastSpeakText != null
                            ? '最近一次播报'
                            : '等待触发（雷达障碍物 / 视觉目标）',
                style: const TextStyle(color: kGuideMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _recognizedItem(FusionWarningService fusion) {
    final item = fusion.visionItem;
    if (item == null || !item.hasTarget) return '未识别到目标';
    return '${CocoLabelsZh.resolve(item.className)} · ${(item.weight * 100).toStringAsFixed(0)}%';
  }

  Color _visionColor(FusionWarningService fusion) {
    final item = fusion.visionItem;
    if (item == null || !item.hasTarget) return kGuideMuted;
    return item.weight > 0.30 ? kGuideError : kGuideWarning;
  }

  String _broadcastPillText(VoiceAnnouncer broadcast) {
    if (broadcast.isSpeaking) return '播报中';
    if (broadcast.isFallbackVibrating) return '振动回退';
    return '空闲';
  }

  PillTone _broadcastPillTone(VoiceAnnouncer broadcast) {
    if (broadcast.isSpeaking) return PillTone.ok;
    if (broadcast.isFallbackVibrating) return PillTone.warning;
    return PillTone.neutral;
  }

  /// 收音画面源：分析运行中时按当前激活源（内置 / UVC）显示，否则待命
  String _activeSourceText(CameraSourceManager camera, VisionWarningService vision) {
    if (!vision.isRunning) return '分析已停止 · 未取帧';
    final kind = camera.activeKind;
    if (kind == null) return '等待画面源';
    return switch (kind) {
      CameraSourceKind.builtin => '内置摄像头',
      CameraSourceKind.uvc => 'UVC 摄像头',
    };
  }

  /// 最近触发时刻（HH:mm:ss）
  String _fmtRadarTrigger(DateTime? at) {
    if (at == null) return '—';
    final t = at.toLocal();
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  /// 视觉最大目标的归一化坐标换算为百分比
  String _visionCoords(FusionWarningService fusion) {
    final item = fusion.visionItem;
    if (item == null || !item.hasTarget) return '—';
    final x = (item.centerX * 100).clamp(0, 100).round();
    final y = (item.centerY * 100).clamp(0, 100).round();
    return 'X:$x% Y:$y%';
  }

  /// 视觉最大目标的映射方位（左前 / 正前 / 右前）
  String _frontAzimuth(FusionWarningService fusion) {
    final item = fusion.visionItem;
    if (item == null || !item.hasTarget) return '—';
    return xToFrontAzimuth(item.centerX).zh;
  }
}

/// 异常提示区：逐条列出当前异常，全部正常时显示绿色就绪横幅
class _AlertBlock extends StatelessWidget {
  const _AlertBlock({required this.entries});

  final List<_AlertEntry> entries;

  @override
  Widget build(BuildContext context) {
    final active = entries.where((e) => e.visible).toList();
    if (active.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: kGuideOk,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '所有系统运行正常',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (final entry in active) ...[
          _buildEntry(entry),
          if (entry != active.last) const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildEntry(_AlertEntry entry) {
    final isError = entry.isError;
    final color = isError ? kGuideError : kGuideWarning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(entry.icon, color: Colors.white, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry.text,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
          if (entry.actionLabel != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: entry.onAction,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.white.withValues(alpha: 0.18),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              ),
              child: Text(
                entry.actionLabel!,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AlertEntry {
  const _AlertEntry._({
    required this.isError,
    required this.visible,
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  factory _AlertEntry.error({required bool visible, required IconData icon, required String text, String? actionLabel, VoidCallback? onAction}) =>
      _AlertEntry._(isError: true, visible: visible, icon: icon, text: text, actionLabel: actionLabel, onAction: onAction);

  factory _AlertEntry.warning({required bool visible, required IconData icon, required String text, String? actionLabel, VoidCallback? onAction}) =>
      _AlertEntry._(isError: false, visible: visible, icon: icon, text: text, actionLabel: actionLabel, onAction: onAction);

  final bool isError;
  final bool visible;
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;
}
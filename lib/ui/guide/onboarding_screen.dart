import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../services/bluetooth_spp_service.dart';
import '../../services/guide_state_service.dart';
import 'guide_widgets.dart';

/// 首启全屏引导：三步开启基础权限
///
/// 蓝牙 / 摄像头 / 通知。仅做权限请求与查询，
/// 不会实例化 YOLO、不启动取帧监控，不影响主流程资源。
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    await context.read<GuideStateService>().refreshPermissions();
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<bool> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      await _refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _requestBluetooth() {
    return context.read<BluetoothSppService>().requestPermissions().then((ok) {
      if (!ok && mounted) {
        _toast('部分蓝牙权限未授予，可在系统设置中开启');
      }
      return ok;
    });
  }

  Future<bool> _requestCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted && mounted) {
      _toast('未获得摄像头权限，雷达触发后将无法取帧分析');
    }
    return status.isGranted;
  }

  Future<bool> _requestNotification() async {
    final status = await Permission.notification.request();
    if (!status.isGranted && mounted) {
      _toast('通知权限未开启，将影响后台监测提醒');
    }
    return status.isGranted;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: kGuideError),
    );
  }

  void _finish() {
    context.read<GuideStateService>().completeFirstRun();
  }

  @override
  Widget build(BuildContext context) {
    final guide = context.watch<GuideStateService>();
    final busyIcon = _busy ? const Icon(Icons.hourglass_top, size: 18) : null;

    final bluetoothOk = guide.bluetoothGranted;
    final cameraOk = guide.cameraGranted;
    final notifyOk = guide.notificationGranted;
    final allDone = bluetoothOk && cameraOk && notifyOk;

    return Scaffold(
      backgroundColor: kGuideBackground,
      body: SafeArea(
        child: Column(
          children: [
            // ── 头部 ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: kGuidePrimary,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.shield, color: Colors.white, size: 28),
                      ),
                      const SizedBox(width: 12),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'zhidao_glass',
                            style: TextStyle(
                              color: kGuideOnSurface,
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            '智能眼镜 · 使用引导',
                            style: TextStyle(color: kGuideMuted, fontSize: 13),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '完成以下 3 项设置，雷达避障与视觉检测即可可靠运行',
                    style: TextStyle(
                      color: kGuideOnSurface,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _StepDot(filled: bluetoothOk, color: kGuidePrimary),
                      const SizedBox(width: 6),
                      _StepDot(filled: cameraOk, color: kGuidePrimary),
                      const SizedBox(width: 6),
                      _StepDot(filled: notifyOk, color: kGuidePrimary),
                    ],
                  ),
                ],
              ),
            ),
            // ── 三步卡片 ──────────────────────────────────────────
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                children: [
                  _buildStepCard(
                    icon: Icons.bluetooth,
                    color: kGuidePrimary,
                    title: '蓝牙权限',
                    desc: '用于连接雷达模块；前方探测到障碍物时实时报警',
                    done: bluetoothOk,
                    busyIcon: busyIcon,
                    actionLabel: '立即开启',
                    onAction: () => _run(_requestBluetooth),
                  ),
                  const SizedBox(height: 12),
                  _buildStepCard(
                    icon: Icons.videocam,
                    color: kGuidePrimary,
                    title: '摄像头权限',
                    desc: '雷达触发后从摄像头取帧，识别障碍物并确定方位；仅检测，不录像',
                    done: cameraOk,
                    busyIcon: busyIcon,
                    actionLabel: '立即开启',
                    onAction: () => _run(_requestCamera),
                  ),
                  const SizedBox(height: 12),
                  _buildStepCard(
                    icon: Icons.notifications_active,
                    color: kGuidePrimary,
                    title: '通知权限',
                    desc: '保持前台服务常驻，异常时推送提醒',
                    done: notifyOk,
                    busyIcon: busyIcon,
                    actionLabel: '立即开启',
                    onAction: () => _run(_requestNotification),
                  ),
                ],
              ),
            ),
            // ── 底部按钮 ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: allDone ? kGuideOk : kGuidePrimary,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _busy
                          ? null
                          : () {
                              if (allDone) {
                                _finish();
                              } else {
                                _toast('请先完成 3 项设置，或选择稍后设置');
                              }
                            },
                      child: Text(
                        allDone ? '全部就绪，开始使用' : '完成设置',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _finish,
                    child: const Text(
                      '稍后设置，直接进入',
                      style: TextStyle(color: kGuideMuted),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepCard({
    required IconData icon,
    required Color color,
    required String title,
    required String desc,
    required bool done,
    String? doneNote,
    required Widget? busyIcon,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return GuideCard(
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: color, size: 24),
      ),
      title: title,
      trailing: StatusPill(
        text: done ? '已开启' : '未开启',
        tone: done ? PillTone.ok : PillTone.warning,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(desc, style: const TextStyle(color: kGuideMuted, fontSize: 13)),
          const SizedBox(height: 12),
          if (done)
            Row(
              children: [
                const Icon(Icons.check_circle, color: kGuideOk, size: 18),
                const SizedBox(width: 6),
                Text(
                  doneNote ?? '权限已就绪',
                  style: const TextStyle(color: kGuideOk, fontWeight: FontWeight.w700),
                ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: busyIcon ?? const SizedBox.shrink(),
                label: Text(actionLabel),
                onPressed: _busy ? null : onAction,
              ),
            ),
        ],
      ),
    );
  }
}

class _StepDot extends StatelessWidget {
  const _StepDot({required this.filled, required this.color});

  final bool filled;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: filled ? color : kGuideBorder,
        shape: BoxShape.circle,
        border: Border.all(color: kGuideMuted, width: 1),
      ),
    );
  }
}
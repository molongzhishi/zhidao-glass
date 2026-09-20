import 'package:flutter/material.dart';

/// 引导页 / 状态页共享的高对比深色配色与基础组件
const kGuideBackground = Color(0xFF0E1116);
const kGuideSurface = Color(0xFF161C24);
const kGuideBorder = Color(0xFF262E3A);
const kGuidePrimary = Color(0xFF2F7BFF);
const kGuideOk = Color(0xFF22C55E);
const kGuideWarning = Color(0xFFF59E0B);
const kGuideError = Color(0xFFEF4444);
const kGuideOnSurface = Color(0xFFF5F7FA);
const kGuideMuted = Color(0xFF9AA6B4);

enum PillTone { ok, warning, error, neutral }

/// 高对比状态胶囊（实心色块 + 圆点 + 文字）
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.text,
    this.tone = PillTone.neutral,
    this.onTap,
  });

  final String text;
  final PillTone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (tone) {
      PillTone.ok => (kGuideOk, const Color(0xFF04210F)),
      PillTone.warning => (kGuideWarning, const Color(0xFF241503)),
      PillTone.error => (kGuideError, const Color(0xFF2A0606)),
      PillTone.neutral => (kGuideBorder, kGuideOnSurface),
    };
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              text,
              style: TextStyle(
                color: fg,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 深色表面卡片（标题行 + 内容）
class GuideCard extends StatelessWidget {
  const GuideCard({
    super.key,
    this.title,
    this.leading,
    this.trailing,
    this.child,
  });

  final String? title;
  final Widget? leading;
  final Widget? trailing;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kGuideSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kGuideBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null || leading != null || trailing != null) ...[
            Row(
              children: [
                ?leading,
                if (leading != null) const SizedBox(width: 10),
                if (title != null)
                  Expanded(
                    child: Text(
                      title!,
                      style: const TextStyle(
                        color: kGuideOnSurface,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 14),
          ],
          ?child,
        ],
      ),
    );
  }
}

/// 卡片内的一行信息（标签 + 值，值可着色）
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor = kGuideOnSurface,
    this.icon,
    this.bold = false,
  });

  final String label;
  final String value;
  final Color valueColor;
  final IconData? icon;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 92, child: Text(label, style: const TextStyle(color: kGuideMuted, fontSize: 13))),
          if (icon != null) ...[
            Icon(icon, size: 16, color: valueColor),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor,
                fontSize: 14,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
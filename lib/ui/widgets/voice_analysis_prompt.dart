import 'package:flutter/material.dart';

class VoiceAnalysisPrompt extends StatefulWidget {
  const VoiceAnalysisPrompt({super.key, required this.isAnalyzing});

  final bool isAnalyzing;

  @override
  State<VoiceAnalysisPrompt> createState() => _VoiceAnalysisPromptState();
}

class _VoiceAnalysisPromptState extends State<VoiceAnalysisPrompt> {
  bool _dismissed = false;

  @override
  void didUpdateWidget(covariant VoiceAnalysisPrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isAnalyzing != widget.isAnalyzing) {
      _dismissed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isAnalyzing || _dismissed) {
      return const SizedBox.shrink();
    }

    return Center(
      child: GestureDetector(
        key: const Key('voice-analysis-prompt'),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _dismissed = true),
        child: const Dialog(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                SizedBox(width: 16),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '正在语音分析',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '点击可隐藏提示，分析将继续',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

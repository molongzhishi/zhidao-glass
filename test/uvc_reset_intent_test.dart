import 'package:flutter_test/flutter_test.dart';
import 'package:multimodal_chat/services/app_tools.dart';

void main() {
  group('UvcResetIntentParser', () {
    test('recognizes affirmative reset replies', () {
      expect(UvcResetIntentParser.parse('重置吧'), UvcResetIntent.confirm);
      expect(UvcResetIntentParser.parse('可以，重新连接摄像头'), UvcResetIntent.confirm);
      expect(UvcResetIntentParser.parse('是'), UvcResetIntent.confirm);
    });

    test('recognizes declined reset replies before affirmative keywords', () {
      expect(UvcResetIntentParser.parse('暂不重置'), UvcResetIntent.decline);
      expect(UvcResetIntentParser.parse('不需要重置摄像头'), UvcResetIntent.decline);
      expect(UvcResetIntentParser.parse('不是'), UvcResetIntent.decline);
    });

    test('leaves unrelated replies for normal chat handling', () {
      expect(UvcResetIntentParser.parse('画面现在是什么内容'), UvcResetIntent.unrelated);
    });
  });

  test('resetUvcCamera is registered as an app tool', () {
    expect(AppTool.fromName('resetUvcCamera'), AppToolType.resetUvcCamera);
  });
}

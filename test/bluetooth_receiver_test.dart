import 'package:flutter_test/flutter_test.dart';
import 'package:multimodal_chat/services/bluetooth_receiver.dart';
import 'package:multimodal_chat/services/bluetooth_spp_service.dart';
import 'package:multimodal_chat/services/warning_center.dart';

void main() {
  group('BluetoothReceiver.parse', () {
    test('parses RADAR:OBSTACLE as hasObstacle with unknown direction', () {
      final signal = BluetoothReceiver.parse('RADAR:OBSTACLE');
      expect(signal, isNotNull);
      expect(signal!.hasObstacle, isTrue);
      expect(signal.direction, RadarDirection.unknown);
    });

    test('parses explicit direction markers', () {
      expect(
        BluetoothReceiver.parse('RADAR:OBSTACLE LEFT')!.direction,
        RadarDirection.left,
      );
      expect(
        BluetoothReceiver.parse('RADAR:OBSTACLE RIGHT')!.direction,
        RadarDirection.right,
      );
      expect(
        BluetoothReceiver.parse('RADAR:OBSTACLE FRONT')!.direction,
        RadarDirection.front,
      );
      expect(
        BluetoothReceiver.parse('前方障碍物')!.direction,
        RadarDirection.front,
      );
    });

    test('parses RADAR:CLEAR as no obstacle', () {
      final signal = BluetoothReceiver.parse('RADAR:CLEAR');
      expect(signal, isNotNull);
      expect(signal!.hasObstacle, isFalse);
    });

    test('parses chinese compatibility keywords', () {
      expect(
        BluetoothReceiver.parse('障碍物')!.hasObstacle,
        isTrue,
      );
      expect(
        BluetoothReceiver.parse('危险')!.hasObstacle,
        isTrue,
      );
      expect(
        BluetoothReceiver.parse('恢复通行')!.hasObstacle,
        isFalse,
      );
      expect(
        BluetoothReceiver.parse('无障碍物')!.hasObstacle,
        isFalse,
      );
    });

    test('ignores unrelated or empty lines', () {
      expect(BluetoothReceiver.parse(''), isNull);
      expect(BluetoothReceiver.parse('   '), isNull);
      expect(BluetoothReceiver.parse('hello world'), isNull);
      expect(BluetoothReceiver.parse('RADAR:WARMING_UP'), isNull);
    });

    test('trims surrounding whitespace/newlines', () {
      final signal = BluetoothReceiver.parse('  RADAR:OBSTACLE\r\n');
      expect(signal, isNotNull);
      expect(signal!.hasObstacle, isTrue);
    });
  });

  group('BluetoothReceiver degradation', () {
    RadarSpeechIntent? lastIntent;
    late BluetoothReceiver receiver;

    setUp(() {
      receiver = BluetoothReceiver(
        bluetoothSpp: BluetoothSppService(),
        warningCenter: WarningCenter(),
        ttsService: null,
      );
      receiver.onSpeech = (intent) => lastIntent = intent;
    });

    tearDown(() {
      receiver.dispose();
    });

    test('bluetooth disconnect degrades to vision-only and announces', () {
      // 先处于已连接状态
      receiver.simulateConnectionChange(true);
      expect(receiver.isDegraded, isFalse);

      // 断连 → 降级 + 清空障碍 + 播报提示
      receiver.simulateConnectionChange(false);
      expect(receiver.isDegraded, isTrue);
      expect(receiver.hasObstacle, isFalse);
      expect(lastIntent?.kind, RadarSpeechKind.disconnected);
      expect(lastIntent?.text, BluetoothReceiver.disconnectAnnouncement);
    });

    test('degraded receiver ignores radar lines (vision-only)', () {
      receiver.simulateConnectionChange(true);
      receiver.simulateConnectionChange(false);
      expect(receiver.isDegraded, isTrue);

      // 降级后即便残留雷达行也不应再触发报警
      receiver.feedSensorLine('RADAR:OBSTACLE LEFT');
      expect(receiver.hasObstacle, isFalse);
      expect(lastIntent?.kind, RadarSpeechKind.disconnected,
          reason: '不应重新触发 obstacle 播报');
    });

    test('reconnect restores radar and announces recovery', () {
      receiver.simulateConnectionChange(true);
      receiver.simulateConnectionChange(false);

      receiver.simulateConnectionChange(true);
      expect(receiver.isDegraded, isFalse);
      expect(lastIntent?.kind, RadarSpeechKind.reconnected);
      expect(lastIntent?.text, BluetoothReceiver.reconnectAnnouncement);

      // 重连后雷达行恢复生效
      receiver.feedSensorLine('RADAR:OBSTACLE RIGHT');
      expect(receiver.hasObstacle, isTrue);
      expect(receiver.direction, RadarDirection.right);
      expect(lastIntent?.kind, RadarSpeechKind.obstacle);
    });
  });
}
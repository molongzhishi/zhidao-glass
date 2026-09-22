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

    test('parses lowercase / mixed-case direction markers', () {
      expect(
        BluetoothReceiver.parse('RADAR:OBSTACLE left')!.direction,
        RadarDirection.left,
      );
      expect(
        BluetoothReceiver.parse('radar:obstacle right')!.direction,
        RadarDirection.right,
      );
      expect(
        BluetoothReceiver.parse('RADAR:OBSTACLE Front')!.direction,
        RadarDirection.front,
      );
    });

    test('parses RADAR:CLEAR as no obstacle', () {
      final signal = BluetoothReceiver.parse('RADAR:CLEAR');
      expect(signal, isNotNull);
      expect(signal!.hasObstacle, isFalse);
    });

    test('RADAR: protocol tag wins over negation keywords', () {
      // 协议前缀显式 ALARM 优于"净空"等否定词（修复既有误判/不一致）
      final signal = BluetoothReceiver.parse('RADAR:ALARM 净空');
      expect(signal, isNotNull);
      expect(signal!.hasObstacle, isTrue);
    });

    test('RADAR:CLEAR wins over obstacle keywords', () {
      expect(
        BluetoothReceiver.parse('RADAR:CLEAR 有障碍')!.hasObstacle,
        isFalse,
      );
    });

    test('unknown RADAR tag falls through to Chinese keywords', () {
      expect(
        BluetoothReceiver.parse('RADAR:已清除')!.hasObstacle,
        isFalse,
      );
      expect(BluetoothReceiver.parse('RADAR:WARMING_UP'), isNull);
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
    late WarningCenter center;

    BluetoothReceiver buildReceiver({Duration initialDataTimeout = const Duration(seconds: 10)}) =>
        BluetoothReceiver(
          bluetoothSpp: BluetoothSppService(),
          warningCenter: center,
          ttsService: null,
          initialDataTimeout: initialDataTimeout,
        );

    setUp(() {
      center = WarningCenter();
      receiver = buildReceiver();
      receiver.onSpeech = (intent) => lastIntent = intent;
    });

    tearDown(() {
      receiver.dispose();
    });

    test('bluetooth disconnect degrades to vision-only and announces', () {
      // 先处于已连接状态
      receiver.simulateConnectionChange(true);
      expect(receiver.isDegraded, isFalse);

      // 断连 → 降级 + 播报提示
      receiver.simulateConnectionChange(false);
      expect(receiver.isDegraded, isTrue);
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

    test('disconnect preserves last known obstacle (disconnect != clear)', () {
      receiver.simulateConnectionChange(true);
      receiver.feedSensorLine('RADAR:OBSTACLE LEFT');
      expect(receiver.hasObstacle, isTrue);
      expect(center.radarObstacle, isTrue);

      // 断连不清除障碍：避免用户误以为障碍消失
      receiver.simulateConnectionChange(false);
      expect(receiver.isDegraded, isTrue);
      expect(receiver.hasObstacle, isTrue,
          reason: '断连后应保留最后已知障碍状态');
      expect(center.radarObstacle, isTrue);

      // 重连后由下一帧雷达数据同步真实状态
      receiver.simulateConnectionChange(true);
      expect(receiver.hasObstacle, isTrue);
      receiver.feedSensorLine('RADAR:CLEAR');
      expect(receiver.hasObstacle, isFalse);
      expect(center.radarObstacle, isFalse);
    });
  });

  group('BluetoothReceiver data health', () {
    late BluetoothReceiver receiver;

    setUp(() {
      receiver = BluetoothReceiver(
        bluetoothSpp: BluetoothSppService(),
        warningCenter: WarningCenter(),
        ttsService: null,
        initialDataTimeout: const Duration(milliseconds: 10),
      );
    });

    tearDown(() {
      receiver.dispose();
    });

    test('connected but no radar data within timeout marks data missing', () async {
      receiver.simulateConnectionChange(true);
      expect(receiver.isRadarDataMissing, isFalse);
      expect(receiver.hasReceivedRadarData, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(receiver.isRadarDataMissing, isTrue);

      // 首帧数据到达即恢复健康
      receiver.feedSensorLine('RADAR:CLEAR');
      expect(receiver.isRadarDataMissing, isFalse);
      expect(receiver.hasReceivedRadarData, isTrue);
      expect(receiver.lastRadarDataAt, isNotNull);
    });

    test('not connected never reports data missing', () async {
      expect(receiver.isRadarDataMissing, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(receiver.isRadarDataMissing, isFalse);
    });

    test('disconnect clears data-missing health state', () async {
      receiver.simulateConnectionChange(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(receiver.isRadarDataMissing, isTrue);

      receiver.simulateConnectionChange(false);
      expect(receiver.isRadarDataMissing, isFalse);
    });
  });
}
import 'dart:math';
import 'dart:typed_data';

/// Stateful first-order high-pass filter for little-endian PCM16 audio.
class PcmHighPassFilter {
  PcmHighPassFilter({required int sampleRate, double cutoffFrequency = 80})
    : assert(sampleRate > 0),
      assert(cutoffFrequency > 0),
      _alpha = _calculateAlpha(sampleRate, cutoffFrequency);

  final double _alpha;
  double _previousInput = 0;
  double _previousOutput = 0;

  static double _calculateAlpha(int sampleRate, double cutoffFrequency) {
    final timeStep = 1 / sampleRate;
    final resistanceCapacitance = 1 / (2 * pi * cutoffFrequency);
    return resistanceCapacitance / (resistanceCapacitance + timeStep);
  }

  void processInPlace(Uint8List pcmBytes) {
    if (pcmBytes.lengthInBytes.isOdd) {
      throw ArgumentError.value(
        pcmBytes.lengthInBytes,
        'pcmBytes.lengthInBytes',
        'PCM16 data must contain complete samples',
      );
    }

    final byteData = ByteData.sublistView(pcmBytes);
    for (var offset = 0; offset < pcmBytes.lengthInBytes; offset += 2) {
      final input = byteData.getInt16(offset, Endian.little).toDouble();
      final output = _alpha * (_previousOutput + input - _previousInput);
      final filteredSample = output.round().clamp(-32768, 32767).toInt();
      byteData.setInt16(offset, filteredSample, Endian.little);
      _previousInput = input;
      _previousOutput = output;
    }
  }

  void reset() {
    _previousInput = 0;
    _previousOutput = 0;
  }
}

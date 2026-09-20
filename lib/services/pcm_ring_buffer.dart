import 'dart:typed_data';

/// Fixed-capacity byte ring buffer for recent PCM audio.
class PcmRingBuffer {
  PcmRingBuffer(int capacity)
    : assert(capacity > 0),
      _buffer = Uint8List(capacity);

  final Uint8List _buffer;
  int _writeIndex = 0;
  int _length = 0;

  int get capacity => _buffer.length;
  int get length => _length;
  bool get isEmpty => _length == 0;

  void add(Uint8List data) {
    if (data.isEmpty) return;

    if (data.length >= capacity) {
      _buffer.setRange(0, capacity, data, data.length - capacity);
      _writeIndex = 0;
      _length = capacity;
      return;
    }

    final firstPart = data.length.clamp(0, capacity - _writeIndex);
    _buffer.setRange(_writeIndex, _writeIndex + firstPart, data);
    final remaining = data.length - firstPart;
    if (remaining > 0) {
      _buffer.setRange(0, remaining, data, firstPart);
    }

    _writeIndex = (_writeIndex + data.length) % capacity;
    _length = (_length + data.length).clamp(0, capacity);
  }

  Uint8List tail(int byteCount) {
    final count = byteCount.clamp(0, _length);
    if (count == 0) return Uint8List(0);

    final result = Uint8List(count);
    final start = (_writeIndex - count + capacity) % capacity;
    final firstPart = count.clamp(0, capacity - start);
    result.setRange(0, firstPart, _buffer, start);
    if (firstPart < count) {
      result.setRange(firstPart, count, _buffer);
    }
    return result;
  }

  void clear() {
    _writeIndex = 0;
    _length = 0;
  }
}

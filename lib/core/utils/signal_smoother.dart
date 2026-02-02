import 'dart:collection';

class SignalSmoother {
  final int _windowSize;
  final Queue<double> _buffer = Queue<double>();

  SignalSmoother({int windowSize = 5}) : _windowSize = windowSize;

  double smooth(double newValue) {
    if (_buffer.length >= _windowSize) {
      _buffer.removeFirst();
    }
    _buffer.add(newValue);
    return _buffer.reduce((a, b) => a + b) / _buffer.length;
  }

  void reset() {
    _buffer.clear();
  }
}
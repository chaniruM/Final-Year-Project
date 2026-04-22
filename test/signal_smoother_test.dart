import 'package:flutter_test/flutter_test.dart';
import 'package:drive_safe/core/utils/signal_smoother.dart';

void main() {
  group('SignalSmoother White-Box Tests', () {
    test('Calculates correct moving average for window size 3', () {
      final smoother = SignalSmoother(windowSize: 3);

      // 1 value: avg is 0.30
      expect(smoother.smooth(0.30), 0.30); 
      // 2 values: (0.30 + 0.20) / 2 = 0.25
      expect(smoother.smooth(0.20), 0.25); 
      // 3 values: (0.30 + 0.20 + 0.25) / 3 = 0.25
      expect(smoother.smooth(0.25), 0.25); 
      // 4th value (prunes oldest 0.30): (0.20 + 0.25 + 0.45) / 3 = 0.30
      expect(smoother.smooth(0.45), 0.30); 
    });

    test('Smoother resets correctly', () {
      final smoother = SignalSmoother(windowSize: 3);
      smoother.smooth(1.0);
      smoother.reset();
      expect(smoother.smooth(0.5), 0.5); // Should start fresh
    });
  });
}
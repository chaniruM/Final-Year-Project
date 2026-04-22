import 'package:flutter_test/flutter_test.dart';
import 'package:drive_safe/features/detector/logic/fusion_engine.dart';

void main() {
  group('FusionEngine Tests', () {
    late FusionEngine engine;

    setUp(() {
      engine = FusionEngine(baselinePerclos: 0.1);
    });

    test('Initial state processes frame correctly', () {
      final result = engine.processFrame(
        currentEar: 0.3, // Open
        headPitch: 0.0,
        mar: 0.0,
        earThreshold: 0.2,
        marThreshold: 0.4,
        baselinePitch: 0.0,
      );

      // We expect the score to be low and status to be normal.
      expect(result['alertLevel'], 0);
      expect(result['score'], lessThan(10.0));
      expect(result['isOccluded'], isFalse);
    });

    test('updateBaseline updates baseline perclos correctly', () {
      engine.updateBaseline(0.2);
      
      final result = engine.processFrame(
        currentEar: 0.3,
        headPitch: 0.0,
        mar: 0.0,
        earThreshold: 0.2,
        marThreshold: 0.4,
        baselinePitch: 0.0,
      );

      expect(result['alertLevel'], 0);
    });

    test('Detects occlusion when EAR is consistently -1.0', () async {
      // Send multiple occluded frames
      for (int i = 0; i < 50; i++) {
        engine.processFrame(
          currentEar: -1.0, 
          headPitch: 0.0,
          mar: -1.0,
          earThreshold: 0.2,
          marThreshold: 0.4,
          baselinePitch: 0.0,
        );
      }
      
      // Wait to simulate time passing for occlusion (requires > 2 seconds without eyes, so >= 3 seconds because inSeconds truncates)
      await Future.delayed(const Duration(milliseconds: 3100));

      final result = engine.processFrame(
        currentEar: -1.0, 
        headPitch: 0.0,
        mar: -1.0,
        earThreshold: 0.2,
        marThreshold: 0.4,
        baselinePitch: 0.0,
      );

      expect(result['isOccluded'], isTrue);
    });

    test('Detects microsleep and alerts', () async {
      // To simulate microsleep, eyes must be closed for > 1500 ms.
      // First frame starts the blink timer
      engine.processFrame(
        currentEar: 0.1, // Closed
        headPitch: 0.0,
        mar: 0.0,
        earThreshold: 0.2,
        marThreshold: 0.4,
        baselinePitch: 0.0,
      );

      await Future.delayed(const Duration(milliseconds: 1600));

      final result = engine.processFrame(
        currentEar: 0.1, // Still closed
        headPitch: 0.0,
        mar: 0.0,
        earThreshold: 0.2,
        marThreshold: 0.4,
        baselinePitch: 0.0,
      );

      expect(result['alertLevel'], 2); // Critical alert
      expect(result['status'], contains('MICROSLEEP DETECTED'));
    });

    test('Reset clears engine state', () {
      engine.processFrame(
        currentEar: 0.1, 
        headPitch: 0.0,
        mar: 0.0,
        earThreshold: 0.2,
        marThreshold: 0.4,
        baselinePitch: 0.0,
      );
      
      engine.reset();
      
      final result = engine.processFrame(
        currentEar: 0.3, 
        headPitch: 0.0,
        mar: 0.0,
        earThreshold: 0.2,
        marThreshold: 0.4,
        baselinePitch: 0.0,
      );

      expect(result['alertLevel'], 0);
      expect(result['score'], lessThan(10.0));
    });
  });
}

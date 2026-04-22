import 'package:flutter_test/flutter_test.dart';
import 'package:drive_safe/core/constants/drowsiness_constants.dart';

void main() {
  group('DrowsinessConstants White-Box Tests', () {
    
    test('ARKit EAR calculation inverts and scales correctly', () {
      // 1. Open eyes: blink values = 0.0 -> expected (1.0 - 0.0) * 0.35 = 0.35
      expect(DrowsinessConstants.calculateArKitEAR(0.0, 0.0), closeTo(0.35, 0.001));
      
      // 2. Closed eyes: blink values = 1.0 -> expected (1.0 - 1.0) * 0.35 = 0.0
      expect(DrowsinessConstants.calculateArKitEAR(1.0, 1.0), closeTo(0.0, 0.001));
      
      // 3. Half closed: blink values = 0.5 -> expected (1.0 - 0.5) * 0.35 = 0.175
      expect(DrowsinessConstants.calculateArKitEAR(0.5, 0.5), closeTo(0.175, 0.001));
    });

    test('ARKit EAR handles occlusion flag (isTracked = false)', () {
      // If the 3D mesh is lost, it should explicitly return -1.0
      expect(DrowsinessConstants.calculateArKitEAR(0.0, 0.0, isTracked: false), -1.0);
    });

    test('isDrowsy returns correct boolean based on threshold', () {
      const threshold = 0.20;
      
      // Below threshold (Closed)
      expect(DrowsinessConstants.isDrowsy(0.15, threshold), isTrue); 
      
      // Above threshold (Open)
      expect(DrowsinessConstants.isDrowsy(0.25, threshold), isFalse); 
      
      // Edge Case: Should NOT be drowsy if occluded (-1.0)
      expect(DrowsinessConstants.isDrowsy(-1.0, threshold), isFalse); 
    });
  });
}
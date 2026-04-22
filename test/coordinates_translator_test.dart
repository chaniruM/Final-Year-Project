import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:drive_safe/features/detector/presentation/painters/coordinates_translator.dart';

void main() {
  group('CoordinatesTranslator White-Box Tests', () {
    
    test('translateX properly scales and MIRRORS coordinates for FRONT camera', () {
      const canvasSize = Size(400, 800);
      const imageSize = Size(1080, 1920);
      const xPos = 270.0; // 25% of the raw image width from the left

      // Mathematical expectation:
      // 1. scaledX = 270 * 400 / 1080 = 100.0
      // 2. front camera mirror = 400 - 100 = 300.0
      
      final result = translateX(
        xPos,
        canvasSize,
        imageSize,
        InputImageRotation.rotation0deg,
        CameraLensDirection.front,
      );

      expect(result, closeTo(300.0, 0.1));
    });

    test('translateX properly scales but DOES NOT mirror for BACK camera', () {
      const canvasSize = Size(400, 800);
      const imageSize = Size(1080, 1920);
      const xPos = 270.0; 

      // Mathematical expectation:
      // 1. scaledX = 270 * 400 / 1080 = 100.0
      // 2. back camera (no mirror) = 100.0
      
      final result = translateX(
        xPos,
        canvasSize,
        imageSize,
        InputImageRotation.rotation0deg,
        CameraLensDirection.back,
      );

      expect(result, closeTo(100.0, 0.1));
    });
  });
}
import 'dart:math';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Constants, thresholds, and calculations used for detecting drowsiness and distraction.
class DrowsinessConstants {
  // --- THRESHOLDS ---
  static const double defaultEyeClosedThreshold = 0.25;
  static const double yawnMarThreshold = 0.4;
  static const double headNodPitchThreshold = -15.0;

  // PERCLOS Settings (Time-Based)
  static const Duration perclosWindowDuration = Duration(seconds: 60);
  static const double perclosTolerance = 0.15;

  // Microsleep Settings
  static const int microsleepDurationMs = 1500; // 1.5 seconds

  // Continuous Event Settings
  static const int headDroopDurationMs = 2000; // 2 seconds
  static const int yawnDurationMs = 3000; // 3 seconds
  static const Duration yawnHistoryWindow = Duration(minutes: 5);
  static const int frequentYawnCount = 3;
  static const double frequentYawnPenalty = 50.0;

  // --- SCORING WEIGHTS (Normal Mode) ---
  static const double weightEyes = 60.0;
  static const double weightHead = 40.0;
  static const double weightMouth = 20.0;

  // --- SCORING WEIGHTS (Occluded Mode - Sunglasses) ---
  static const double weightHeadOccluded = 80.0;
  static const double weightMouthOccluded = 40.0;

  // --- ALERT LEVELS ---
  static const double scoreThresholdAlert = 100.0;
  static const double scoreThresholdWarning = 75.0;

  // --- METHODS ---

  /// Calculates the Geometric Eye Aspect Ratio (EAR) based on facial contours.
  ///
  /// Returns -1.0 if the eyes cannot be confidently detected (e.g., occlusion).
  static double calculateEAR(Face face, {double? restingEar}) {
    final leftEye = face.contours[FaceContourType.leftEye]?.points;
    final rightEye = face.contours[FaceContourType.rightEye]?.points;

    if (leftEye == null ||
        rightEye == null ||
        leftEye.length < 3 ||
        rightEye.length < 3) {
      return -1.0;
    }

    // Normal Geometric Calculation
    double leftEAR = _getEyeRatio(leftEye);
    double rightEAR = _getEyeRatio(rightEye);

    return (leftEAR + rightEAR) / 2.0;
  }

  static double _getEyeRatio(List<Point<int>> points) {
    int minX = 10000, maxX = -10000;
    int minY = 10000, maxY = -10000;

    for (var p in points) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }

    double width = (maxX - minX).toDouble();
    double height = (maxY - minY).toDouble();

    if (width <= 0) return 0.0;
    return height / width;
  }

  /// Calculates the Mouth Aspect Ratio (MAR) using inner lip contours.
  ///
  /// Used primarily to detect yawning. Returns 0.0 if contours are not detected.
  static double calculateMAR(Face face) {
    final upper = face.contours[FaceContourType.upperLipBottom]?.points;
    final lower = face.contours[FaceContourType.lowerLipTop]?.points;

    if (upper == null || lower == null || upper.isEmpty || lower.isEmpty)
      return 0.0;

    int centerU = upper.length ~/ 2;
    int centerL = lower.length ~/ 2;

    if (centerU < 1 || centerU >= upper.length - 1) return 0.0;
    if (centerL < 1 || centerL >= lower.length - 1) return 0.0;

    double avgUpperY =
        (upper[centerU - 1].y + upper[centerU].y + upper[centerU + 1].y) / 3.0;
    double avgLowerY =
        (lower[centerL - 1].y + lower[centerL].y + lower[centerL + 1].y) / 3.0;

    double height = (avgLowerY - avgUpperY).abs();

    final lowerOuter = face.contours[FaceContourType.lowerLipBottom]?.points;
    if (lowerOuter == null || lowerOuter.isEmpty) return 0.0;

    double width = (lowerOuter.last.x - lowerOuter.first.x).abs().toDouble();

    if (width <= 0) return 0.0;
    return height / width;
  }

  /// Calculates EAR using ARKit's blendshape coefficients for eye blinks.
  static double calculateArKitEAR(double eyeBlinkLeft, double eyeBlinkRight,
      {bool isTracked = true}) {
    if (!isTracked) return -1.0;
    double avgBlink = (eyeBlinkLeft + eyeBlinkRight) / 2.0;
    return (1.0 - avgBlink) * 0.35;
  }

  /// Maps ARKit's `jawOpen` blendshape to a Mouth Aspect Ratio format.
  static double calculateArKitMAR(double jawOpen) {
    return jawOpen;
  }

  /// Determines if a given EAR falls below the defined threshold.
  static bool isDrowsy(double currentEAR, double threshold) {
    if (currentEAR < 0.0) return false;
    return currentEAR < threshold;
  }
}

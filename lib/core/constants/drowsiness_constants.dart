import 'dart:math';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

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

  // --- SCORING WEIGHTS (Occluded Mode) ---
  static const double weightHeadOccluded = 80.0;
  static const double weightMouthOccluded = 40.0;

  // --- ALERT LEVELS ---
  static const double scoreThresholdAlert = 100.0;
  static const double scoreThresholdWarning = 75.0;

  // --- METHODS ---

  /// Calculates Geometric Eye Aspect Ratio (EAR)
  static double calculateEAR(Face face) {
    final leftEye = face.contours[FaceContourType.leftEye]?.points;
    final rightEye = face.contours[FaceContourType.rightEye]?.points;

    if (leftEye == null || rightEye == null || leftEye.length < 3 || rightEye.length < 3) {
      if (face.leftEyeOpenProbability == null && face.rightEyeOpenProbability == null) {
        return -1.0; // Eyes completely occluded
      }
      double prob = ((face.leftEyeOpenProbability ?? 0.5) + (face.rightEyeOpenProbability ?? 0.5)) / 2;
      return prob * 0.5;
    }

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

  /// Calculates Mouth Aspect Ratio (MAR) using INNER LIPS
  static double calculateMAR(Face face) {
    final upper = face.contours[FaceContourType.upperLipBottom]?.points;
    final lower = face.contours[FaceContourType.lowerLipTop]?.points;

    if (upper == null || lower == null || upper.isEmpty || lower.isEmpty) return 0.0;

    int centerU = upper.length ~/ 2;
    int centerL = lower.length ~/ 2;

    if (centerU < 1 || centerU >= upper.length - 1) return 0.0;
    if (centerL < 1 || centerL >= lower.length - 1) return 0.0;

    double avgUpperY = (upper[centerU-1].y + upper[centerU].y + upper[centerU+1].y) / 3.0;
    double avgLowerY = (lower[centerL-1].y + lower[centerL].y + lower[centerL+1].y) / 3.0;

    double height = (avgLowerY - avgUpperY).abs();

    final lowerOuter = face.contours[FaceContourType.lowerLipBottom]?.points;
    if (lowerOuter == null || lowerOuter.isEmpty) return 0.0;

    double width = (lowerOuter.last.x - lowerOuter.first.x).abs().toDouble();

    if (width <= 0) return 0.0;
    return height / width;
  }

  // --- ARKIT METHODS ---

  static double calculateArKitEAR(double eyeBlinkLeft, double eyeBlinkRight, {bool isTracked = true}) {
    if (!isTracked) return -1.0; // Mesh is fully lost
    
    // ARKit returns 0.0 for open, 1.0 for closed.
    // We invert this to match EAR logic (High = Open, Low = Closed).
    double avgBlink = (eyeBlinkLeft + eyeBlinkRight) / 2.0;
    return (1.0 - avgBlink) * 0.35; // Scaling factor to match geometric EAR roughly
  }

  static double calculateArKitMAR(double jawOpen) {
    // ARKit jawOpen is 0.0 (closed) to 1.0 (open).
    // This maps directly to MAR logic.
    return jawOpen;
  }

  static bool isDrowsy(double currentEAR, double threshold) {
    return currentEAR < threshold;
  }
}
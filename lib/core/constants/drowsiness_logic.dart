import 'dart:collection';
import 'dart:math';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class DrowsinessLogic {
  // Eye Aspect Ratio thresholds
  static const double defaultEyeClosedThreshold = 0.25;

  // Mouth Aspect Ratio thresholds (Yawning)
  // Since we now measure the INNER opening, the resting value will be near 0.0.
  // A yawn will still be large (e.g., > 0.3 or 0.4).
  static const double yawnMarThreshold = 0.4;

  // Head Pose thresholds (Nodding - Pitch)
  static const double headNodPitchThreshold = -15.0;

  // PERCLOS Constants
  static const int perclosWindowFrames = 300;
  static const double perclosTolerance = 0.15;

  /// Calculates Geometric Eye Aspect Ratio (EAR)
  static double calculateEAR(Face face) {
    final leftEye = face.contours[FaceContourType.leftEye]?.points;
    final rightEye = face.contours[FaceContourType.rightEye]?.points;

    if (leftEye == null || rightEye == null || leftEye.length < 3 || rightEye.length < 3) {
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
  /// This ensures we measure the OPENING, not the lip thickness.
  static double calculateMAR(Face face) {
    // CHANGED: Use Inner Contours
    final upper = face.contours[FaceContourType.upperLipBottom]?.points;
    final lower = face.contours[FaceContourType.lowerLipTop]?.points;

    if (upper == null || lower == null || upper.isEmpty || lower.isEmpty) return 0.0;

    // Use central points
    int centerU = upper.length ~/ 2;
    int centerL = lower.length ~/ 2;

    // Safety check
    if (centerU < 1 || centerU >= upper.length - 1) return 0.0;
    if (centerL < 1 || centerL >= lower.length - 1) return 0.0;

    // Average Y positions of center 3 points
    double avgUpperY = (upper[centerU-1].y + upper[centerU].y + upper[centerU+1].y) / 3.0;
    double avgLowerY = (lower[centerL-1].y + lower[centerL].y + lower[centerL+1].y) / 3.0;

    // Calculate height (The Opening)
    double height = (avgLowerY - avgUpperY).abs();

    // Calculate width (Corners of mouth - use outer loop for stability)
    // We use lowerLipBottom for width as corners are usually stable there
    final lowerOuter = face.contours[FaceContourType.lowerLipBottom]?.points;
    if (lowerOuter == null || lowerOuter.isEmpty) return 0.0;

    double width = (lowerOuter.last.x - lowerOuter.first.x).abs().toDouble();

    if (width <= 0) return 0.0;
    return height / width;
  }

  static bool isDrowsy(double currentEAR, double threshold) {
    return currentEAR < threshold;
  }
}

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

class FusionEngine {
  final Queue<bool> _eyeClosedBuffer = Queue<bool>();

  // Smoothers
  final SignalSmoother _earSmoother = SignalSmoother(windowSize: 5);
  final SignalSmoother _pitchSmoother = SignalSmoother(windowSize: 8);
  final SignalSmoother _marSmoother = SignalSmoother(windowSize: 5);

  double _baselinePerclos = 0.0;
  DateTime? _lastEyesDetectedTime;

  FusionEngine({double baselinePerclos = 0.0}) {
    _baselinePerclos = baselinePerclos;
    _lastEyesDetectedTime = DateTime.now();
  }

  void updateBaseline(double baseline) {
    _baselinePerclos = baseline;
  }

  void reset() {
    _eyeClosedBuffer.clear();
    _earSmoother.reset();
    _pitchSmoother.reset();
    _marSmoother.reset();
    _lastEyesDetectedTime = DateTime.now();
  }

  Map<String, dynamic> processFrame({
    required double currentEar,
    required double headPitch,
    required double mar,
    required double earThreshold,
    required double marThreshold,
  }) {
    final now = DateTime.now();

    double sEar = _earSmoother.smooth(currentEar);
    double sPitch = _pitchSmoother.smooth(headPitch);
    double sMar = _marSmoother.smooth(mar);

    if (currentEar > 0.0) {
      _lastEyesDetectedTime = now;
    }

    final timeSinceEyesLastSeen = now.difference(_lastEyesDetectedTime ?? now);
    final bool isOccluded = timeSinceEyesLastSeen.inSeconds > 2;

    final bool isNodding = sPitch < DrowsinessLogic.headNodPitchThreshold;
    final bool isYawning = sMar > marThreshold;

    if (isOccluded) {
      bool alert = false;
      String status = "Occlusion Mode";

      if (isNodding) {
        status = "WAKE UP (Nodding!)";
        alert = true;
      } else if (isYawning) {
        status = "Fatigue: Yawning";
      }

      return {
        'alert': alert,
        'status': status,
        'perclos': 0.0,
        'isOccluded': true,
        'smoothedMar': sMar,
        'smoothedPitch': sPitch,
        'smoothedEar': sEar,
      };
    } else {
      bool eyesClosed = DrowsinessLogic.isDrowsy(sEar, earThreshold);

      if (_eyeClosedBuffer.length >= DrowsinessLogic.perclosWindowFrames) {
        _eyeClosedBuffer.removeFirst();
      }
      _eyeClosedBuffer.add(eyesClosed);

      int closedFrames = _eyeClosedBuffer.where((c) => c).length;
      double currentPerclos = _eyeClosedBuffer.isEmpty ? 0.0 : closedFrames / _eyeClosedBuffer.length;

      double effectivePerclosThreshold = _baselinePerclos + DrowsinessLogic.perclosTolerance;
      if (isNodding || isYawning) effectivePerclosThreshold -= 0.05;

      final bool perclosAlert = currentPerclos > effectivePerclosThreshold;

      bool alert = false;
      String status = "Monitoring...";

      if (perclosAlert) {
        alert = true;
        status = "DROWSY! (PERCLOS: ${(currentPerclos * 100).toStringAsFixed(1)}%)";
      } else if (isNodding) {
        alert = true;
        status = "WAKE UP! (Head)";
      } else if (eyesClosed) {
        status = "Blink";
      }

      if (isYawning) {
        if (!alert) status = "Yawning...";
      }

      return {
        'alert': alert,
        'status': status,
        'perclos': currentPerclos,
        'isOccluded': false,
        'smoothedMar': sMar,
        'smoothedPitch': sPitch,
        'smoothedEar': sEar,
      };
    }
  }
}


// outer lip
// import 'dart:collection';
// import 'dart:math';
// import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
//
// class DrowsinessLogic {
//   // Default fallback if calibration fails
//   static const double defaultEyeClosedThreshold = 0.20;
//
//   // Mouth Aspect Ratio thresholds (Yawning)
//   static const double yawnMarThreshold = 0.5;
//
//   // Head Pose thresholds (Nodding - Pitch)
//   static const double headNodPitchThreshold = -15.0;
//
//   static const Duration microsleepDuration = Duration(milliseconds: 1500);
//
//   // PERCLOS Constants
//   static const int perclosWindowFrames = 300;
//   static const double perclosTolerance = 0.15;
//
//   /// Calculates Geometric Eye Aspect Ratio (EAR)
//   /// Formula: Average Height / Width
//   static double calculateEAR(Face face) {
//     // 1. Get contours
//     final leftEye = face.contours[FaceContourType.leftEye]?.points;
//     final rightEye = face.contours[FaceContourType.rightEye]?.points;
//
//     if (leftEye == null || rightEye == null || leftEye.length < 3 || rightEye.length < 3) {
//       // Fallback to probability if contours are missing (e.g. too far away)
//       // We return a mapped value: 0.5 prob ~= 0.25 EAR
//       double prob = ((face.leftEyeOpenProbability ?? 0.5) + (face.rightEyeOpenProbability ?? 0.5)) / 2;
//       return prob * 0.5;
//     }
//
//     double leftEAR = _getEyeRatio(leftEye);
//     double rightEAR = _getEyeRatio(rightEye);
//
//     // Average both eyes
//     return (leftEAR + rightEAR) / 2.0;
//   }
//
//   static double _getEyeRatio(List<Point<int>> points) {
//     // Find extreme points to define bounding box of the eye
//     // This is more robust than looking for specific indices which might shift
//     int minX = 10000, maxX = -10000;
//     int minY = 10000, maxY = -10000;
//
//     for (var p in points) {
//       if (p.x < minX) minX = p.x;
//       if (p.x > maxX) maxX = p.x;
//       if (p.y < minY) minY = p.y;
//       if (p.y > maxY) maxY = p.y;
//     }
//
//     double width = (maxX - minX).toDouble();
//     double height = (maxY - minY).toDouble();
//
//     if (width <= 0) return 0.0;
//
//     // Geometric EAR
//     return height / width;
//   }
//
//   /// Calculates Mouth Aspect Ratio (MAR) using the average of 3 central points
//   /// We keep this improvement as it makes the measurement more stable than single-point
//   static double calculateMAR(Face face) {
//     final upper = face.contours[FaceContourType.upperLipTop]?.points;
//     final lower = face.contours[FaceContourType.lowerLipBottom]?.points;
//
//     if (upper == null || lower == null || upper.isEmpty || lower.isEmpty) return 0.0;
//
//     // Use the 3 central points to reduce noise
//     int centerU = upper.length ~/ 2;
//     int centerL = lower.length ~/ 2;
//
//     if (centerU < 1 || centerU >= upper.length - 1) return 0.0;
//     if (centerL < 1 || centerL >= lower.length - 1) return 0.0;
//
//     double avgUpperY = (upper[centerU-1].y + upper[centerU].y + upper[centerU+1].y) / 3.0;
//     double avgLowerY = (lower[centerL-1].y + lower[centerL].y + lower[centerL+1].y) / 3.0;
//
//     double height = (avgLowerY - avgUpperY).abs();
//     double width = (lower.last.x - lower.first.x).abs().toDouble();
//
//     if (width <= 0) return 0.0;
//     return height / width;
//   }
//
//   static bool isDrowsy(double currentEAR, double threshold) {
//     return currentEAR < threshold;
//   }
// }
//
// class SignalSmoother {
//   final int _windowSize;
//   final Queue<double> _buffer = Queue<double>();
//
//   SignalSmoother({int windowSize = 5}) : _windowSize = windowSize;
//
//   double smooth(double newValue) {
//     if (_buffer.length >= _windowSize) {
//       _buffer.removeFirst();
//     }
//     _buffer.add(newValue);
//     return _buffer.reduce((a, b) => a + b) / _buffer.length;
//   }
//
//   void reset() {
//     _buffer.clear();
//   }
// }
//
// class FusionEngine {
//   final Queue<bool> _eyeClosedBuffer = Queue<bool>();
//
//   // Smoothers
//   final SignalSmoother _earSmoother = SignalSmoother(windowSize: 5);
//   final SignalSmoother _pitchSmoother = SignalSmoother(windowSize: 8);
//   final SignalSmoother _marSmoother = SignalSmoother(windowSize: 5);
//
//   double _baselinePerclos = 0.0;
//   DateTime? _lastEyesDetectedTime;
//
//   FusionEngine({double baselinePerclos = 0.0}) {
//     _baselinePerclos = baselinePerclos;
//     _lastEyesDetectedTime = DateTime.now();
//   }
//
//   void updateBaseline(double baseline) {
//     _baselinePerclos = baseline;
//   }
//
//   void reset() {
//     _eyeClosedBuffer.clear();
//     _earSmoother.reset();
//     _pitchSmoother.reset();
//     _marSmoother.reset();
//     _lastEyesDetectedTime = DateTime.now();
//   }
//
//   Map<String, dynamic> processFrame({
//     required double currentEar,
//     required double headPitch,
//     required double mar,
//     required double earThreshold,
//     required double marThreshold,
//   }) {
//     final now = DateTime.now();
//
//     // 1. Smooth Signals
//     double sEar = _earSmoother.smooth(currentEar);
//     double sPitch = _pitchSmoother.smooth(headPitch);
//     double sMar = _marSmoother.smooth(mar);
//
//     // 2. Occlusion Check (Time based)
//     // If EAR is exactly 0.0 for a long time, it's likely occlusion or no face
//     if (currentEar > 0.0) {
//       _lastEyesDetectedTime = now;
//     }
//
//     final timeSinceEyesLastSeen = now.difference(_lastEyesDetectedTime ?? now);
//     final bool isOccluded = timeSinceEyesLastSeen.inSeconds > 2;
//
//     // --- 3. LOGIC & CLASSIFICATION ---
//
//     // These checks apply to BOTH modes (Normal & Occluded)
//     final bool isNodding = sPitch < DrowsinessLogic.headNodPitchThreshold;
//     final bool isYawning = sMar > marThreshold;
//
//     if (isOccluded) {
//       // --- OCCLUSION MODE ---
//       // Relies PURELY on Head Pose & Mouth
//
//       bool alert = false;
//       String status = "Occlusion Mode";
//
//       if (isNodding) {
//         status = "WAKE UP (Nodding!)";
//         alert = true;
//       } else if (isYawning) {
//         status = "Fatigue: Yawning";
//         // Yawning in occlusion mode is a strong indicator, we can treat as warning
//       } else {
//         status = "Occlusion: Monitoring Head/Mouth";
//       }
//
//       return {
//         'alert': alert,
//         'status': status,
//         'perclos': 0.0,
//         'isOccluded': true,
//         'smoothedMar': sMar,
//         'smoothedPitch': sPitch,
//         'smoothedEar': sEar,
//       };
//     } else {
//       // --- NORMAL MODE ---
//       // Fuses PERCLOS + Head + Mouth
//
//       bool eyesClosed = DrowsinessLogic.isDrowsy(sEar, earThreshold);
//
//       // Update PERCLOS Buffer
//       if (_eyeClosedBuffer.length >= DrowsinessLogic.perclosWindowFrames) {
//         _eyeClosedBuffer.removeFirst();
//       }
//       _eyeClosedBuffer.add(eyesClosed);
//
//       // Calculate Real-time PERCLOS
//       int closedFrames = _eyeClosedBuffer.where((c) => c).length;
//       double currentPerclos = _eyeClosedBuffer.isEmpty ? 0.0 : closedFrames / _eyeClosedBuffer.length;
//
//       double effectivePerclosThreshold = _baselinePerclos + DrowsinessLogic.perclosTolerance;
//
//       // Dynamic Sensitivity: If Nodding or Yawning, become STRICTER on eyes
//       if (isNodding || isYawning) {
//         effectivePerclosThreshold -= 0.05;
//       }
//
//       final bool perclosAlert = currentPerclos > effectivePerclosThreshold;
//
//       bool alert = false;
//       String status = "Monitoring...";
//
//       if (perclosAlert) {
//         alert = true;
//         status = "DROWSY! (PERCLOS: ${(currentPerclos * 100).toStringAsFixed(1)}%)";
//       } else if (isNodding) {
//         alert = true;
//         status = "WAKE UP! (Head Dropping)";
//       } else if (eyesClosed) {
//         status = "Blink";
//       }
//
//       // RESTORED: Explicit Yawning Status
//       // This ensures the user sees "Yawning..." even if no alert is triggered yet
//       if (isYawning) {
//         if (!alert) status = "Yawning...";
//       }
//
//       return {
//         'alert': alert,
//         'status': status,
//         'perclos': currentPerclos,
//         'isOccluded': false,
//         'smoothedMar': sMar,
//         'smoothedPitch': sPitch,
//         'smoothedEar': sEar,
//       };
//     }
//   }
// }

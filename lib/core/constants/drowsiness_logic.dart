import 'dart:collection';
import 'dart:math';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';

class DrowsinessLogic {
  static const double defaultEyeClosedThreshold = 0.18;
  static const double yawnMarThreshold = 0.4;
  static const double headNodPitchThreshold = 15.0;

  static const int perclosWindowFrames = 300;
  static const double perclosTolerance = 0.15;

  static const double weightEyes = 60.0;
  static const double weightHead = 40.0;
  static const double weightMouth = 20.0;

  static const double weightHeadOccluded = 80.0;
  static const double weightMouthOccluded = 40.0;

  static const double scoreThresholdAlert = 100.0;
  static const double scoreThresholdWarning = 75.0;

  // --- STANDARD DETECTOR METHODS (Existing) ---

  static double calculateEAR(Face face) {
    final leftEye = face.contours[FaceContourType.leftEye]?.points;
    final rightEye = face.contours[FaceContourType.rightEye]?.points;

    if (leftEye == null || rightEye == null || leftEye.length < 3 || rightEye.length < 3) {
      double prob = ((face.leftEyeOpenProbability ?? 0.5) + (face.rightEyeOpenProbability ?? 0.5)) / 2;
      return prob * 0.5;
    }
    return (_getEyeRatio(leftEye) + _getEyeRatio(rightEye)) / 2.0;
  }

  static double calculateMAR(Face face) {
    final upper = face.contours[FaceContourType.upperLipBottom]?.points;
    final lower = face.contours[FaceContourType.lowerLipTop]?.points;
    if (upper == null || lower == null || upper.isEmpty || lower.isEmpty) return 0.0;

    int centerU = upper.length ~/ 2;
    int centerL = lower.length ~/ 2;
    double avgUpperY = (upper[centerU-1].y + upper[centerU].y + upper[centerU+1].y) / 3.0;
    double avgLowerY = (lower[centerL-1].y + lower[centerL].y + lower[centerL+1].y) / 3.0;
    double height = (avgLowerY - avgUpperY).abs();

    final lowerOuter = face.contours[FaceContourType.lowerLipBottom]?.points;
    if (lowerOuter == null || lowerOuter.isEmpty) return 0.0;
    double width = (lowerOuter.last.x - lowerOuter.first.x).abs().toDouble();
    return width <= 0 ? 0.0 : height / width;
  }

  static double _getEyeRatio(List<Point<int>> points) {
    int minX = 10000, maxX = -10000, minY = 10000, maxY = -10000;
    for (var p in points) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }
    double width = (maxX - minX).toDouble();
    double height = (maxY - minY).toDouble();
    return width <= 0 ? 0.0 : height / width;
  }

  // --- NEW: FACE MESH METHODS ---

  static double calculateMeshEAR(FaceMesh mesh) {
    // Safety check for 468 points
    if (mesh.points.length < 468) return 0.25;

    // Indices based on standard MediaPipe Face Mesh topology
    // Left Eye: Top(159), Bottom(145), Left(33), Right(133)
    final double leftH = _dist(mesh.points[159], mesh.points[145]);
    final double leftW = _dist(mesh.points[33], mesh.points[133]);
    final double leftEAR = leftW == 0 ? 0 : leftH / leftW;

    // Right Eye: Top(386), Bottom(374), Left(362), Right(263)
    final double rightH = _dist(mesh.points[386], mesh.points[374]);
    final double rightW = _dist(mesh.points[362], mesh.points[263]);
    final double rightEAR = rightW == 0 ? 0 : rightH / rightW;

    return (leftEAR + rightEAR) / 2.0;
  }

  static double calculateMeshMAR(FaceMesh mesh) {
    if (mesh.points.length < 468) return 0.0;

    // Indices for Inner Mouth (Matches our Standard Inner-Lip Logic)
    // Top(13), Bottom(14), Left(61), Right(291)
    // Note: 61/291 are mouth corners. 13/14 are inner lip centers.
    final double height = _dist(mesh.points[13], mesh.points[14]);
    final double width = _dist(mesh.points[61], mesh.points[291]);

    return width == 0 ? 0 : height / width;
  }

  static double _dist(FaceMeshPoint p1, FaceMeshPoint p2) {
    // Euclidean distance in 2D (ignoring Z for EAR/MAR ratios is usually sufficient and standard)
    return sqrt(pow(p1.x - p2.x, 2) + pow(p1.y - p2.y, 2));
  }

  // --- ARKIT METHODS ---

  static double calculateArKitEAR(double eyeBlinkLeft, double eyeBlinkRight) {
    double avgBlink = (eyeBlinkLeft + eyeBlinkRight) / 2.0;
    return (1.0 - avgBlink) * 0.35;
  }

  static double calculateArKitMAR(double jawOpen) {
    return jawOpen;
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

  final SignalSmoother _earSmoother = SignalSmoother(windowSize: 3);
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

    final bool isNodding = sPitch > DrowsinessLogic.headNodPitchThreshold;
    final bool isYawning = sMar > marThreshold;

    if (isOccluded) {
      bool alert = false;
      String status = "Occlusion Mode";

      double score = 0;
      score += isNodding ? DrowsinessLogic.weightHeadOccluded : 0;
      score += isYawning ? DrowsinessLogic.weightMouthOccluded : 0;

      if (score >= DrowsinessLogic.scoreThresholdAlert) {
        status = "ALERT: Wake Up! (Occluded)";
        alert = true;
      } else if (score >= DrowsinessLogic.scoreThresholdWarning) {
        status = "Warning: Fatigue Signs";
      }

      return {
        'alert': alert,
        'status': status,
        'score': score,
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
      if (effectivePerclosThreshold == 0) effectivePerclosThreshold = 0.01;

      double perclosRatio = currentPerclos / effectivePerclosThreshold;
      if (perclosRatio > 2.5) perclosRatio = 2.5;

      double score = 0.0;
      score += perclosRatio * DrowsinessLogic.weightEyes;
      score += isNodding ? DrowsinessLogic.weightHead : 0;
      score += isYawning ? DrowsinessLogic.weightMouth : 0;

      bool alert = score >= DrowsinessLogic.scoreThresholdAlert;
      String status = "Monitoring (Score: ${score.toInt()})";

      if (alert) {
        status = isNodding ? "ALERT: Head Dropping!" : "ALERT: Drowsiness Detected!";
      } else if (score >= DrowsinessLogic.scoreThresholdWarning) {
        status = isYawning ? "Warning: Yawning..." : "Warning: Fatigue Signs";
      } else {
        if (isYawning) status = "Yawning (Low Risk)";
        else if (eyesClosed) status = "Blink";
      }

      return {
        'alert': alert,
        'status': status,
        'score': score,
        'perclos': currentPerclos,
        'isOccluded': false,
        'smoothedMar': sMar,
        'smoothedPitch': sPitch,
        'smoothedEar': sEar,
      };
    }
  }
}



// import 'dart:collection';
// import 'dart:math';
// import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
// import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';
//
// class DrowsinessLogic {
//   static const double defaultEyeClosedThreshold = 0.18;
//   static const double yawnMarThreshold = 0.4;
//   static const double headNodPitchThreshold = -15.0;
//
//   static const int perclosWindowFrames = 300;
//   static const double perclosTolerance = 0.15;
//
//   static const double weightEyes = 60.0;
//   static const double weightHead = 40.0;
//   static const double weightMouth = 20.0;
//
//   static const double weightHeadOccluded = 80.0;
//   static const double weightMouthOccluded = 40.0;
//
//   static const double scoreThresholdAlert = 100.0;
//   static const double scoreThresholdWarning = 75.0;
//
//   // --- STANDARD DETECTOR METHODS (Existing) ---
//
//   static double calculateEAR(Face face) {
//     final leftEye = face.contours[FaceContourType.leftEye]?.points;
//     final rightEye = face.contours[FaceContourType.rightEye]?.points;
//
//     if (leftEye == null || rightEye == null || leftEye.length < 3 || rightEye.length < 3) {
//       double prob = ((face.leftEyeOpenProbability ?? 0.5) + (face.rightEyeOpenProbability ?? 0.5)) / 2;
//       return prob * 0.5;
//     }
//     return (_getEyeRatio(leftEye) + _getEyeRatio(rightEye)) / 2.0;
//   }
//
//   static double calculateMAR(Face face) {
//     final upper = face.contours[FaceContourType.upperLipBottom]?.points;
//     final lower = face.contours[FaceContourType.lowerLipTop]?.points;
//     if (upper == null || lower == null || upper.isEmpty || lower.isEmpty) return 0.0;
//
//     int centerU = upper.length ~/ 2;
//     int centerL = lower.length ~/ 2;
//     double avgUpperY = (upper[centerU-1].y + upper[centerU].y + upper[centerU+1].y) / 3.0;
//     double avgLowerY = (lower[centerL-1].y + lower[centerL].y + lower[centerL+1].y) / 3.0;
//     double height = (avgLowerY - avgUpperY).abs();
//
//     final lowerOuter = face.contours[FaceContourType.lowerLipBottom]?.points;
//     if (lowerOuter == null || lowerOuter.isEmpty) return 0.0;
//     double width = (lowerOuter.last.x - lowerOuter.first.x).abs().toDouble();
//     return width <= 0 ? 0.0 : height / width;
//   }
//
//   static double _getEyeRatio(List<Point<int>> points) {
//     int minX = 10000, maxX = -10000, minY = 10000, maxY = -10000;
//     for (var p in points) {
//       if (p.x < minX) minX = p.x;
//       if (p.x > maxX) maxX = p.x;
//       if (p.y < minY) minY = p.y;
//       if (p.y > maxY) maxY = p.y;
//     }
//     double width = (maxX - minX).toDouble();
//     double height = (maxY - minY).toDouble();
//     return width <= 0 ? 0.0 : height / width;
//   }
//
//   // --- MESH METHODS (Placeholder) ---
//   static double calculateMeshEAR(FaceMesh mesh) => 0.25;
//
//   // --- NEW: ARKIT METHODS ---
//
//   /// Converts ARKit 'eyeBlink' (0=open, 1=closed) to EAR (1=open, 0=closed)
//   /// Used to feed the same PERCLOS logic.
//   static double calculateArKitEAR(double eyeBlinkLeft, double eyeBlinkRight) {
//     // Average both eyes
//     double avgBlink = (eyeBlinkLeft + eyeBlinkRight) / 2.0;
//     // Invert: ARKit 1.0 is closed, Logic expects 0.0 to be closed.
//     // However, ARKit is very precise. 0.8 blink is basically closed.
//     // Let's map it: 1.0 (Blink) -> 0.0 (EAR), 0.0 (Open) -> 0.35 (EAR approx)
//     // Formula: (1.0 - avgBlink) * 0.35
//     return (1.0 - avgBlink) * 0.35;
//   }
//
//   /// Converts ARKit 'jawOpen' (0=closed, 1=open) to MAR
//   static double calculateArKitMAR(double jawOpen) {
//     // ARKit jawOpen correlates well with MAR.
//     // 0.0 is closed. 0.5 is wide yawn.
//     // We can use it directly or scale slightly if needed.
//     return jawOpen;
//   }
//
//   static bool isDrowsy(double currentEAR, double threshold) {
//     return currentEAR < threshold;
//   }
// }
//
// // ... SignalSmoother and FusionEngine remain unchanged ...
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
//   final SignalSmoother _earSmoother = SignalSmoother(windowSize: 3);
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
//     double sEar = _earSmoother.smooth(currentEar);
//     double sPitch = _pitchSmoother.smooth(headPitch);
//     double sMar = _marSmoother.smooth(mar);
//
//     if (currentEar > 0.0) {
//       _lastEyesDetectedTime = now;
//     }
//
//     final timeSinceEyesLastSeen = now.difference(_lastEyesDetectedTime ?? now);
//     final bool isOccluded = timeSinceEyesLastSeen.inSeconds > 2;
//
//     final bool isNodding = sPitch < DrowsinessLogic.headNodPitchThreshold;
//     final bool isYawning = sMar > marThreshold;
//
//     if (isOccluded) {
//       bool alert = false;
//       String status = "Occlusion Mode";
//
//       double score = 0;
//       score += isNodding ? DrowsinessLogic.weightHeadOccluded : 0;
//       score += isYawning ? DrowsinessLogic.weightMouthOccluded : 0;
//
//       if (score >= DrowsinessLogic.scoreThresholdAlert) {
//         status = "ALERT: Wake Up! (Occluded)";
//         alert = true;
//       } else if (score >= DrowsinessLogic.scoreThresholdWarning) {
//         status = "Warning: Fatigue Signs";
//       }
//
//       return {
//         'alert': alert,
//         'status': status,
//         'score': score,
//         'perclos': 0.0,
//         'isOccluded': true,
//         'smoothedMar': sMar,
//         'smoothedPitch': sPitch,
//         'smoothedEar': sEar,
//       };
//     } else {
//       bool eyesClosed = DrowsinessLogic.isDrowsy(sEar, earThreshold);
//
//       if (_eyeClosedBuffer.length >= DrowsinessLogic.perclosWindowFrames) {
//         _eyeClosedBuffer.removeFirst();
//       }
//       _eyeClosedBuffer.add(eyesClosed);
//
//       int closedFrames = _eyeClosedBuffer.where((c) => c).length;
//       double currentPerclos = _eyeClosedBuffer.isEmpty ? 0.0 : closedFrames / _eyeClosedBuffer.length;
//
//       double effectivePerclosThreshold = _baselinePerclos + DrowsinessLogic.perclosTolerance;
//       if (effectivePerclosThreshold == 0) effectivePerclosThreshold = 0.01;
//
//       double perclosRatio = currentPerclos / effectivePerclosThreshold;
//       if (perclosRatio > 2.5) perclosRatio = 2.5;
//
//       double score = 0.0;
//       score += perclosRatio * DrowsinessLogic.weightEyes;
//       score += isNodding ? DrowsinessLogic.weightHead : 0;
//       score += isYawning ? DrowsinessLogic.weightMouth : 0;
//
//       bool alert = score >= DrowsinessLogic.scoreThresholdAlert;
//       String status = "Monitoring (Score: ${score.toInt()})";
//
//       if (alert) {
//         status = isNodding ? "ALERT: Head Dropping!" : "ALERT: Drowsiness Detected!";
//       } else if (score >= DrowsinessLogic.scoreThresholdWarning) {
//         status = isYawning ? "Warning: Yawning..." : "Warning: Fatigue Signs";
//       } else {
//         if (isYawning) status = "Yawning (Low Risk)";
//         else if (eyesClosed) status = "Blink";
//       }
//
//       return {
//         'alert': alert,
//         'status': status,
//         'score': score,
//         'perclos': currentPerclos,
//         'isOccluded': false,
//         'smoothedMar': sMar,
//         'smoothedPitch': sPitch,
//         'smoothedEar': sEar,
//       };
//     }
//   }
// }
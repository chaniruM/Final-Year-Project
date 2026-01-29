import 'dart:collection';
import 'dart:math';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class DrowsinessLogic {
  // --- THRESHOLDS ---
  static const double defaultEyeClosedThreshold = 0.25;
  static const double yawnMarThreshold = 0.4;
  static const double headNodPitchThreshold = -15.0;

  // PERCLOS Settings
  static const int perclosWindowFrames = 300;
  static const double perclosTolerance = 0.15;

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

  // --- ML KIT METHODS (Standard) ---

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

  // --- ARKIT METHODS (Added for iOS) ---

  static double calculateArKitEAR(double eyeBlinkLeft, double eyeBlinkRight) {
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

    // 1. Smooth Inputs
    double sEar = _earSmoother.smooth(currentEar);
    double sPitch = _pitchSmoother.smooth(headPitch);
    double sMar = _marSmoother.smooth(mar);

    // 2. Check for Occlusion (Eyes not seen for > 2 seconds)
    if (currentEar > 0.0) {
      _lastEyesDetectedTime = now;
    }
    final timeSinceEyesLastSeen = now.difference(_lastEyesDetectedTime ?? now);
    final bool isOccluded = timeSinceEyesLastSeen.inSeconds > 2;

    // 3. Update History (PERCLOS)
    bool eyesClosed = DrowsinessLogic.isDrowsy(sEar, earThreshold);

    // Only update eye buffer if NOT occluded (garbage data otherwise)
    if (!isOccluded) {
      if (_eyeClosedBuffer.length >= DrowsinessLogic.perclosWindowFrames) {
        _eyeClosedBuffer.removeFirst();
      }
      _eyeClosedBuffer.add(eyesClosed);
    }

    int closedFrames = _eyeClosedBuffer.where((c) => c).length;
    double currentPerclos = _eyeClosedBuffer.isEmpty ? 0.0 : closedFrames / _eyeClosedBuffer.length;

    // 4. Calculate Scores
    double score = 0.0;

    // A. Eyes Score (PERCLOS)
    double effectivePerclosThreshold = _baselinePerclos + DrowsinessLogic.perclosTolerance;
    // Avoid division by zero
    if (effectivePerclosThreshold == 0) effectivePerclosThreshold = 0.01;

    // Calculate ratio: 1.0 means we are AT the threshold. 2.0 means double the threshold.
    double perclosRatio = currentPerclos / effectivePerclosThreshold;
    // Cap ratio at 2.5 to prevent one metric from totally dominating
    if (perclosRatio > 2.5) perclosRatio = 2.5;

    // B. Binary Events
    bool isNodding = sPitch < DrowsinessLogic.headNodPitchThreshold;
    bool isYawning = sMar > marThreshold;

    // 5. Fusion Logic (Adaptive Weights)
    if (isOccluded) {
      // OCCLUSION MODE: Trust Head & Mouth
      score += isNodding ? DrowsinessLogic.weightHeadOccluded : 0;
      score += isYawning ? DrowsinessLogic.weightMouthOccluded : 0;
    } else {
      // NORMAL MODE: Fusion
      // Base score from eyes (e.g. Ratio 1.0 * 60 = 60 points)
      score += perclosRatio * DrowsinessLogic.weightEyes;

      // Adders
      score += isNodding ? DrowsinessLogic.weightHead : 0;
      score += isYawning ? DrowsinessLogic.weightMouth : 0;
    }

    // 6. Determine Status
    bool alert = score >= DrowsinessLogic.scoreThresholdAlert;
    String status = "Monitoring (Score: ${score.toInt()})";

    if (alert) {
      if (isOccluded) {
        status = "ALERT: Wake Up! (No Eyes Detected)";
      } else if (isNodding) {
        status = "ALERT: Head Dropping!";
      } else {
        status = "ALERT: Drowsiness Detected!";
      }
    } else if (score >= DrowsinessLogic.scoreThresholdWarning) {
      if (isYawning) status = "Warning: Yawning...";
      else status = "Warning: Fatigue Signs";
    } else {
      // Informative statuses for low scores
      if (isOccluded) status = "Occlusion Mode";
      else if (isYawning) status = "Yawning (Low Risk)";
      else if (eyesClosed) status = "Blink";
    }

    return {
      'alert': alert,
      'status': status,
      'score': score, // Return score for debugging if needed
      'perclos': currentPerclos,
      'isOccluded': isOccluded,
      'smoothedMar': sMar,
      'smoothedPitch': sPitch,
      'smoothedEar': sEar,
    };
  }
}
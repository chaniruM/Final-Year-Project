import 'dart:collection';
import 'dart:math' as math;
import '../../../core/constants/drowsiness_constants.dart';
import '../../../core/utils/signal_smoother.dart';

class FrameData {
  final DateTime timestamp;
  final bool isEyeClosed;
  FrameData(this.timestamp, this.isEyeClosed);
}

class FusionEngine {
  final Queue<FrameData> _timeBuffer = Queue<FrameData>();
  final Queue<double> _earVarianceBuffer = Queue<double>();

  final SignalSmoother _earSmoother = SignalSmoother(windowSize: 3);
  final SignalSmoother _pitchSmoother = SignalSmoother(windowSize: 8);
  final SignalSmoother _marSmoother = SignalSmoother(windowSize: 5);

  double _baselinePerclos = 0.0;
  DateTime? _lastEyesDetectedTime;
  DateTime? _blinkStartTime; // Tracks continuous closure for microsleeps
  
  DateTime? _droopStartTime; // Tracks continuous head droop
  DateTime? _yawnStartTime; // Tracks continuous yawn
  final List<DateTime> _verifiedYawns = []; // Keeps a history of yawns

  FusionEngine({double baselinePerclos = 0.0}) {
    _baselinePerclos = baselinePerclos;
    _lastEyesDetectedTime = DateTime.now();
  }

  void updateBaseline(double baseline) {
    _baselinePerclos = baseline;
  }

  void reset() {
    _timeBuffer.clear();
    _earVarianceBuffer.clear();
    _earSmoother.reset();
    _pitchSmoother.reset();
    _marSmoother.reset();
    _lastEyesDetectedTime = DateTime.now();
    _blinkStartTime = null;
    _droopStartTime = null;
    _yawnStartTime = null;
    _verifiedYawns.clear();
  }

  Map<String, dynamic> processFrame({
    required double currentEar,
    required double headPitch,
    required double mar,
    required double earThreshold,
    required double marThreshold,
    required double baselinePitch, // Added to receive relative setup
  }) {
    final now = DateTime.now();

    // 0. ARKit Variance Flatline Check
    if (currentEar >= 0.0) {
      _earVarianceBuffer.add(currentEar);
      if (_earVarianceBuffer.length > 60) _earVarianceBuffer.removeFirst();
    }

    bool isFlatlined = false;
    if (_earVarianceBuffer.length >= 60) {
      double mean = _earVarianceBuffer.reduce((a, b) => a + b) / _earVarianceBuffer.length;
      double variance = _earVarianceBuffer.map((e) => math.pow(e - mean, 2)).reduce((a, b) => a + b) / _earVarianceBuffer.length;
      if (variance < 0.0000001) { // Practically zero variance translates to forced ARKit guessing
        isFlatlined = true;
      }
    }

    bool isValidEAR = currentEar >= 0.0 && !isFlatlined;

    // 1. Smooth Inputs
    double sEar = isValidEAR ? _earSmoother.smooth(currentEar) : -1.0;
    double sPitch = _pitchSmoother.smooth(headPitch);
    double sMar = _marSmoother.smooth(mar);

    // Calculate relative pitch to the calibrated 0 degree baseline
    double relativePitch = sPitch - baselinePitch;

    // PRE-CALCULATE EVENTS: We need to know if the user is yawning early on
    // to prevent natural eye-squinting from triggering a false microsleep.
    bool isYawningInstant = sMar > marThreshold;
    bool isNoddingInstant = relativePitch < DrowsinessConstants.headNodPitchThreshold;

    // 2. Check for Occlusion (Eyes not seen for > 2 seconds)
    if (isValidEAR) {
      _lastEyesDetectedTime = now;
    }
    final timeSinceEyesLastSeen = now.difference(_lastEyesDetectedTime ?? now);
    final bool isOccluded = timeSinceEyesLastSeen.inSeconds > 2;

    // 3. Update History & PERCLOS (Time-Based)
    bool eyesClosed = DrowsinessConstants.isDrowsy(sEar, earThreshold);
    bool isMicrosleep = false;

    if (!isOccluded) {
      // Add current frame to time buffer
      _timeBuffer.add(FrameData(now, eyesClosed));

      // Remove frames older than the PERCLOS window duration
      _timeBuffer.removeWhere((frame) => 
          now.difference(frame.timestamp) > DrowsinessConstants.perclosWindowDuration);

      // Microsleep Detection (Continuous Closure)
      // SUPPRESSION: If yawning, eyes naturally close. Reset/pause the microsleep timer.
      if (eyesClosed && !isYawningInstant) {
        _blinkStartTime ??= now;
        if (now.difference(_blinkStartTime!).inMilliseconds > DrowsinessConstants.microsleepDurationMs) {
          isMicrosleep = true;
        }
      } else {
        _blinkStartTime = null;
      }
    } else {
      _blinkStartTime = null; // Reset if occluded
    }

    int closedFrames = _timeBuffer.where((c) => c.isEyeClosed).length;
    double currentPerclos = _timeBuffer.isEmpty ? 0.0 : closedFrames / _timeBuffer.length;

    // 4. Calculate Scores
    double score = 0.0;

    // A. Eyes Score (PERCLOS)
    double effectivePerclosThreshold = _baselinePerclos + DrowsinessConstants.perclosTolerance;
    if (effectivePerclosThreshold == 0) effectivePerclosThreshold = 0.01;

    double perclosRatio = currentPerclos / effectivePerclosThreshold;
    if (perclosRatio > 2.5) perclosRatio = 2.5;

    // B. Duration-Based Binary Events (Approach A)
    bool isContinuousDroop = false;
    
    if (isNoddingInstant) {
      _droopStartTime ??= now;
      if (now.difference(_droopStartTime!).inMilliseconds > DrowsinessConstants.headDroopDurationMs) {
        isContinuousDroop = true;
      }
    } else {
      _droopStartTime = null;
    }

    bool isContinuousYawn = false;

    if (isYawningInstant) {
      _yawnStartTime ??= now;
      if (now.difference(_yawnStartTime!).inMilliseconds > DrowsinessConstants.yawnDurationMs) {
        isContinuousYawn = true;
      }
    } else {
      // If yawn just finished and was a verified long yawn, log it
      if (_yawnStartTime != null && now.difference(_yawnStartTime!).inMilliseconds > DrowsinessConstants.yawnDurationMs) {
        _verifiedYawns.add(now);
      }
      _yawnStartTime = null;
    }

    // Clean up old verified yawns outside the 5-minute window
    _verifiedYawns.removeWhere((timestamp) => 
        now.difference(timestamp) > DrowsinessConstants.yawnHistoryWindow);

    // C. Lingering Penalties (Approach B)
    double penaltyScore = 0.0;
    if (_verifiedYawns.length >= DrowsinessConstants.frequentYawnCount) {
      penaltyScore += DrowsinessConstants.frequentYawnPenalty;
    }

    // 5. Fusion Logic (Adaptive Weights)
    if (isOccluded) {
      // OCCLUSION MODE: Trust Head & Mouth
      score += isNoddingInstant ? DrowsinessConstants.weightHeadOccluded : 0;
      score += isContinuousYawn ? DrowsinessConstants.weightMouthOccluded : 0;
    } else {
      // NORMAL MODE: Fusion
      score += perclosRatio * DrowsinessConstants.weightEyes;
      score += isNoddingInstant ? DrowsinessConstants.weightHead : 0;
      score += isContinuousYawn ? DrowsinessConstants.weightMouth : 0;
    }
    
    score += penaltyScore; // Apply the lingering fatigue penalty

    // 6. Determine Status & Alert Level (State Machine)
    int alertLevel = 0; // 0: Normal, 1: Warning, 2: Critical
    String status = "Monitoring (Score: ${score.toInt()})";

    if (isMicrosleep || isContinuousDroop || score >= DrowsinessConstants.scoreThresholdAlert) {
      alertLevel = 2; // Critical Alert
      if (isMicrosleep) {
        status = "ALERT: MICROSLEEP DETECTED!";
      } else if (isContinuousDroop) {
        status = "ALERT: HEAD DROPPED!";
      } else if (isOccluded) {
        status = "ALERT: Wake Up! (No Eyes Detected)";
      } else if (_verifiedYawns.length >= DrowsinessConstants.frequentYawnCount) {
        status = "ALERT: EXTREME FATIGUE (Frequent Yawns)";
      } else {
        status = "ALERT: Drowsiness Detected!";
      }
    } else if (isContinuousYawn || score >= DrowsinessConstants.scoreThresholdWarning) {
      alertLevel = 1; // Warning Alert
      if (isContinuousYawn) {
        status = "Warning: Yawning Detected";
      } else if (_verifiedYawns.isNotEmpty) {
        status = "Warning: Fatigue Buildup";
      } else {
        status = "Warning: Fatigue Signs";
      }
    } else {
      // Informative statuses for low scores
      if (isOccluded) status = "Occlusion Mode";
      else if (isYawningInstant) status = "Yawning (Low Risk)";
      else if (eyesClosed) status = "Blink";
    }

    return {
      'alertLevel': alertLevel,
      'status': status,
      'score': score,
      'perclos': currentPerclos,
      'isOccluded': isOccluded,
      'smoothedMar': sMar,
      'smoothedPitch': relativePitch, // Return the relative pitch so UI shows "0" at rest
      'smoothedEar': sEar,
    };
  }
}
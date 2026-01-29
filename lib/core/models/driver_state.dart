/// A unified model representing the driver's face state,
/// regardless of the underlying sensor (ARKit, FaceMesh, or MLKit).
class DriverState {
  final double leftEyeOpenProbability;  // 0.0 (closed) -> 1.0 (open)
  final double rightEyeOpenProbability; // 0.0 (closed) -> 1.0 (open)
  final double mouthOpenness;           // 0.0 (closed) -> 1.0 (yawning)
  final double headPitch;               // In degrees
  final double headYaw;                 // In degrees
  final bool isFaceDetected;

  // Helper for EAR-based logic
  // We approximate EAR from probability if using ARKit
  double get simulatedEar {
    double avgOpen = (leftEyeOpenProbability + rightEyeOpenProbability) / 2;
    // ARKit returns 0-1. Normal EAR is ~0.3.
    // We scale it so existing thresholds work.
    return avgOpen * 0.35;
  }

  const DriverState({
    required this.leftEyeOpenProbability,
    required this.rightEyeOpenProbability,
    required this.mouthOpenness,
    required this.headPitch,
    required this.headYaw,
    this.isFaceDetected = true,
  });

  factory DriverState.empty() {
    return const DriverState(
      leftEyeOpenProbability: 0,
      rightEyeOpenProbability: 0,
      mouthOpenness: 0,
      headPitch: 0,
      headYaw: 0,
      isFaceDetected: false,
    );
  }
}
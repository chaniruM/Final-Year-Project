import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';
import '../../../core/constants/drowsiness_logic.dart';
import '../../../core/models/driver_state.dart';

class FaceMeshService {
  final FaceMeshDetector _detector = FaceMeshDetector(
    option: FaceMeshDetectorOptions.faceMesh, // accurate mode
  );

  Future<List<FaceMesh>> processImage(InputImage inputImage) async {
    // FIX: Method name is processImage in v0.4.1
    return await _detector.processImage(inputImage);
  }

  /// Converts a raw ML Kit Face Mesh into our Unified DriverState
  DriverState mapToDriverState(FaceMesh mesh) {
    // 1. Calculate EAR from Mesh (High accuracy)
    double ear = DrowsinessLogic.calculateMeshEAR(mesh);

    // 2. Calculate MAR from Mesh
    double mar = DrowsinessLogic.calculateMeshMAR(mesh);

    // 3. Convert EAR to Probability for uniformity
    // Assuming EAR 0.3 = Open(1.0) and EAR 0.15 = Closed(0.0)
    // This is a rough linear map for the unified state
    double prob = (ear - 0.15) / (0.30 - 0.15);
    if (prob < 0) prob = 0;
    if (prob > 1) prob = 1;

    // 4. Head Pose
    // Fallback: We will return 0.0 for pitch if not calculating geometry.
    double pitch = 0.0;

    return DriverState(
      leftEyeOpenProbability: prob,
      rightEyeOpenProbability: prob,
      mouthOpenness: mar, // Mesh MAR is geometric ratio
      headPitch: pitch,
      headYaw: 0.0,
      isFaceDetected: true,
    );
  }

  void dispose() {
    _detector.close();
  }
}
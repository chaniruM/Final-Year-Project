import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

/// Service responsible for running Google ML Kit models on camera frames.
///
/// This service concurrently processes images through a FaceDetector to extract
/// biometric landmarks/contours, and an ImageLabeler to detect occlusion (e.g., sunglasses).
class FaceDetectorService {
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: false,
      enableContours: true,
      enableLandmarks: true,
      enableTracking: true,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  final ImageLabeler _imageLabeler = ImageLabeler(
    options: ImageLabelerOptions(confidenceThreshold: 0.65) // Only trust confident predictions
  );

  Future<Map<String, dynamic>> processImage(InputImage inputImage) async {
    // Run both AI models concurrently to save processing time
    final facesFuture = _faceDetector.processImage(inputImage);
    final labelsFuture = _imageLabeler.processImage(inputImage);

    final results = await Future.wait([facesFuture, labelsFuture]);

    final List<Face> faces = results[0] as List<Face>;
    final List<ImageLabel> labels = results[1] as List<ImageLabel>;

    bool hasSunglasses = false;
    String? detectedEyewear;

    for (final label in labels) {
      final text = label.label.toLowerCase();

      // Strictly search for 'sunglass' to trigger the -1.0 EAR override
      if (text.contains('sunglass')) {
        hasSunglasses = true;
        detectedEyewear = label.label;
        break;
      } 
      // If it's not sunglasses, check if they are wearing regular glasses/spectacles for the UI
      else if (text.contains('glasses') || text.contains('spectacles') || text.contains('eyewear')) {
        detectedEyewear ??= label.label; 
      }
    }

    return {
      'faces': faces,
      'hasSunglasses': hasSunglasses,
      'detectedEyewear': detectedEyewear,
    };
  }

  /// Releases resources used by the ML Kit models.

  void dispose() {
    _faceDetector.close();
    _imageLabeler.close();
  }
}

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';

enum DetectorType {
  standard, // ML Kit Face Detection (Contours)
  mesh,     // ML Kit Face Mesh (468 points) - Android Only usually
}

class FaceDetectorService {
  // Engines
  FaceDetector? _standardDetector;
  FaceMeshDetector? _meshDetector;

  DetectorType _currentType = DetectorType.standard;
  bool _isMeshSupported = false;

  FaceDetectorService() {
    _initialize();
  }

  Future<void> _initialize() async {
    // 1. Initialize Standard Detector (Always available as fallback)
    _standardDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        enableContours: true,
        enableLandmarks: true,
        enableTracking: true,
        performanceMode: FaceDetectorMode.accurate,
      ),
    );

    // 2. Initialize Mesh Detector (Android Only Preference)
    if (Platform.isAndroid) {
      try {
        _meshDetector = FaceMeshDetector(
          option: FaceMeshDetectorOptions.faceMesh,
        );
        _isMeshSupported = true;
        _currentType = DetectorType.mesh; // Default to mesh on Android
        debugPrint("FaceDetectorService: Using Face Mesh (Tier 1)");
      } catch (e) {
        debugPrint("FaceDetectorService: Mesh init failed, falling back. Error: $e");
        _isMeshSupported = false;
        _currentType = DetectorType.standard;
      }
    } else {
      // iOS: Standard for now (ARKit requires View changes)
      _currentType = DetectorType.standard;
      debugPrint("FaceDetectorService: Using Standard Detector (Tier 2)");
    }
  }

  /// Unified processor that returns a standard Face object
  /// If using Mesh, we convert the mesh data into a compatible format or return it wrapped.
  /// For simplicity in this step, we will expose the specific result types.
  Future<dynamic> processImage(InputImage inputImage) async {
    if (_currentType == DetectorType.mesh && _meshDetector != null) {
      try {
        final meshes = await _meshDetector!.processImage(inputImage);
        if (meshes.isNotEmpty) return meshes; // Return List<FaceMesh>
      } catch (e) {
        debugPrint("Mesh processing failed, switching to standard: $e");
        _currentType = DetectorType.standard; // Fallback runtime
      }
    }

    // Fallback or Standard
    if (_standardDetector != null) {
      return await _standardDetector!.processImage(inputImage); // Return List<Face>
    }

    return [];
  }

  void dispose() {
    _standardDetector?.close();
    _meshDetector?.close();
  }

  DetectorType get currentType => _currentType;
}
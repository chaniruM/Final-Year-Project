import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart'; // Mesh Support
// ARKit
import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

import '../data/face_detector_service.dart';
import '../data/calibration_service.dart';
import '../../../core/constants/drowsiness_logic.dart';
import 'painters/face_detector_painter.dart';

class CalibrationView extends StatefulWidget {
  const CalibrationView({super.key});

  @override
  State<CalibrationView> createState() => _CalibrationViewState();
}

class _CalibrationViewState extends State<CalibrationView> {
  // --- CAMERA (Android/Standard) ---
  CameraController? _cameraController;

  // --- ARKIT (iOS) ---
  ARKitController? _arkitController;
  ARKitNode? _faceNode;

  final FaceDetectorService _detectorService = FaceDetectorService();
  final CalibrationService _calibrationService = CalibrationService();

  bool _isCalibrating = false;
  bool _calibrationSuccess = false;
  bool _isProcessing = false;
  int _timerCount = 10;

  // Data Collection
  List<double> _capturedEarValues = [];
  List<double> _capturedMarValues = [];

  String _message = "Position phone. Ensure face is visible.";
  double _currentPreviewEar = 0.0;
  double _currentPreviewMar = 0.0;

  CustomPaint? _customPaint;
  bool get _isIOS => Platform.isIOS;

  @override
  void initState() {
    super.initState();
    if (!_isIOS) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    final front = cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first
    );

    _cameraController = CameraController(
      front,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.nv21,
    );

    await _cameraController!.initialize();
    if (mounted) setState(() {});
  }

  void _startCalibration() async {
    // Android check only (iOS handles internally)
    if (!_isIOS && _cameraController == null) return;

    setState(() {
      _isCalibrating = true;
      _calibrationSuccess = false;
      _timerCount = 10;
      _capturedEarValues.clear();
      _capturedMarValues.clear();
      _message = "Keep eyes OPEN. Mouth CLOSED (Neutral).";
    });

    if (!_isIOS) {
      await _cameraController!.startImageStream(_processCameraImage);
    }

    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_timerCount <= 0 || !mounted || !_isCalibrating) {
        timer.cancel();
        if (_isCalibrating) _finishCalibration();
      } else {
        setState(() => _timerCount--);
      }
    });
  }

  // --- ANDROID PROCESSING ---
  void _processCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = _prepareInputImage(image);
      if (inputImage != null) {
        // Smart Service: Returns List<Face> OR List<FaceMesh>
        final results = await _detectorService.processImage(inputImage);

        List<Face>? faces;
        List<FaceMesh>? meshes;
        double ear = 0.0;
        double mar = 0.0;

        // Check Type
        if (results is List<FaceMesh> && results.isNotEmpty) {
          meshes = results;
          // TODO: Implement proper Mesh EAR/MAR calculation
          // For now, Mesh support on Android is VISUAL only, falling back logic isn't fully mapped
          // We can assume if mesh is active, logic needs mesh support.
          // For this specific step, if using Mesh, we might need a separate calc.
          // Fallback: If logic isn't ready, service falls back to standard.
          // Assuming service returned meshes:
          ear = DrowsinessLogic.calculateMeshEAR(meshes.first);
          mar = 0.0; // Placeholder
        } else if (results is List<Face> && results.isNotEmpty) {
          faces = results;
          final face = faces.first;
          ear = DrowsinessLogic.calculateEAR(face);
          mar = DrowsinessLogic.calculateMAR(face);
        }

        final painter = FaceDetectorPainter(
          imageSize: inputImage.metadata!.size,
          rotation: inputImage.metadata!.rotation,
          cameraLensDirection: CameraLensDirection.front,
          faces: faces, // Pass if standard
          meshes: meshes, // Pass if mesh
        );

        if (_isCalibrating) {
          if (ear > 0.0) _capturedEarValues.add(ear);
          if (mar > 0.0) _capturedMarValues.add(mar);
        }

        if (mounted) {
          setState(() {
            _currentPreviewEar = ear;
            _currentPreviewMar = mar;
            _customPaint = CustomPaint(painter: painter);
          });
        }
      }
    } catch (e) {
      debugPrint("Calibration stream error: $e");
    } finally {
      _isProcessing = false;
    }
  }

  // --- iOS ARKIT LOGIC ---
  void _onARKitViewCreated(ARKitController arkitController) {
    _arkitController = arkitController;
    _arkitController?.onAddNodeForAnchor = _handleAddAnchor;
    _arkitController?.onUpdateNodeForAnchor = _handleUpdateAnchor;
  }

  void _handleAddAnchor(ARKitAnchor anchor) {
    if (anchor is! ARKitFaceAnchor) return;
    final material = ARKitMaterial(fillMode: ARKitFillMode.lines, diffuse: ARKitMaterialProperty.color(Colors.cyanAccent.withOpacity(0.8)));
    anchor.geometry.materials.value = [material];
    _faceNode = ARKitNode(geometry: anchor.geometry);
    _arkitController?.add(_faceNode!, parentNodeName: anchor.nodeName);
  }

  void _handleUpdateAnchor(ARKitAnchor anchor) {
    if (anchor is ARKitFaceAnchor && mounted) {
      if (_faceNode != null) {
        _arkitController?.updateFaceGeometry(_faceNode!, anchor.identifier);
      }

      // Calculate Metrics
      final blendShapes = anchor.blendShapes;
      final double leftBlink = blendShapes['eyeBlink_L'] ?? 0.0;
      final double rightBlink = blendShapes['eyeBlink_R'] ?? 0.0;
      final double jawOpen = blendShapes['jawOpen'] ?? 0.0;

      final double ear = DrowsinessLogic.calculateArKitEAR(leftBlink, rightBlink);
      final double mar = DrowsinessLogic.calculateArKitMAR(jawOpen);

      // Collect Data
      if (_isCalibrating) {
        _capturedEarValues.add(ear);
        _capturedMarValues.add(mar);
      }

      setState(() {
        _currentPreviewEar = ear;
        _currentPreviewMar = mar;
      });
    }
  }

  Future<void> _finishCalibration() async {
    if (!_isIOS) await _cameraController?.stopImageStream();
    setState(() => _customPaint = null);

    if (_capturedEarValues.isEmpty) {
      setState(() {
        _isCalibrating = false;
        _message = "Calibration Failed. No face detected.";
      });
      return;
    }

    // Logic matches DetectorView
    _capturedEarValues.sort();
    int start = (_capturedEarValues.length * 0.10).toInt();
    int end = (_capturedEarValues.length * 0.90).toInt();
    if (end <= start) { start = 0; end = _capturedEarValues.length; }

    List<double> validEar = _capturedEarValues.sublist(start, end);
    double avgOpenEar = validEar.reduce((a, b) => a + b) / validEar.length;
    double personalEarThreshold = avgOpenEar * 0.60; // Stricter

    double personalMarThreshold = 0.5;
    if (_capturedMarValues.isNotEmpty) {
      _capturedMarValues.sort();
      int mStart = (_capturedMarValues.length * 0.10).toInt();
      int mEnd = (_capturedMarValues.length * 0.90).toInt();
      if (mEnd <= mStart) { mStart = 0; mEnd = _capturedMarValues.length; }
      List<double> validMar = _capturedMarValues.sublist(mStart, mEnd);
      double avgRestingMar = validMar.reduce((a, b) => a + b) / validMar.length;
      personalMarThreshold = avgRestingMar + 0.25;
      if (personalMarThreshold < 0.3) personalMarThreshold = 0.3;
      if (personalMarThreshold > 0.6) personalMarThreshold = 0.6;
    }

    await _calibrationService.saveBaselines(personalEarThreshold, 0.05, personalMarThreshold);

    setState(() {
      _isCalibrating = false;
      _calibrationSuccess = true;
      _message = "Success!\nEAR Thresh: ${personalEarThreshold.toStringAsFixed(3)}\nMAR Thresh: ${personalMarThreshold.toStringAsFixed(3)}";
    });
  }

  Future<void> _safeExit() async {
    _isProcessing = true;
    if (!_isIOS && _cameraController != null) {
      if (_cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
      await _cameraController!.dispose();
    }
    _cameraController = null;

    // Clean ARKit
    _arkitController?.dispose();
    _arkitController = null;

    if (!mounted) return;
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  InputImage? _prepareInputImage(CameraImage image) {
    if (_cameraController == null) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: InputImageRotation.rotation270deg,
        format: Platform.isIOS ? InputImageFormat.bgra8888 : InputImageFormat.nv21,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _detectorService.dispose();
    _arkitController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isCameraReady = _isIOS || (_cameraController != null && _cameraController!.value.isInitialized);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _safeExit();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text("Calibration")),
        body: Stack(
          children: [
            if (_isIOS)
              ARKitSceneView(
                configuration: ARKitConfiguration.faceTracking,
                onARKitViewCreated: _onARKitViewCreated,
                enableTapRecognizer: false,
              )
            else if (isCameraReady)
              Positioned.fill(
                child: Transform.scale(
                  scale: MediaQuery.of(context).size.aspectRatio * _cameraController!.value.aspectRatio,
                  child: Center(
                    child: CameraPreview(_cameraController!, child: _customPaint),
                  ),
                ),
              )
            else
              const Center(child: CircularProgressIndicator()),

            Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (_isCalibrating)
                  Container(
                    padding: const EdgeInsets.only(top: 20),
                    child: Column(
                      children: [
                        Text("EAR: ${_currentPreviewEar.toStringAsFixed(3)}", style: const TextStyle(color: Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 2, color: Colors.black)])),
                        Text("MAR: ${_currentPreviewMar.toStringAsFixed(3)}", style: const TextStyle(color: Colors.yellowAccent, fontSize: 20, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 2, color: Colors.black)])),
                      ],
                    ),
                  )
                else
                  const SizedBox.shrink(),

                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: const BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                  width: double.infinity,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16)),
                      const SizedBox(height: 10),
                      if (_isCalibrating)
                        Text("$_timerCount", style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                      const SizedBox(height: 20),

                      if (!_isCalibrating && _calibrationSuccess)
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton.icon(
                            onPressed: _safeExit,
                            icon: const Icon(Icons.check_circle),
                            label: const Text("DONE - BACK TO DETECTOR"),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                          ),
                        )
                      else
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton(
                            onPressed: _isCalibrating ? null : _startCalibration,
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                            child: Text(_isCalibrating ? "Calibrating..." : "Start Calibration", style: const TextStyle(color: Colors.white)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
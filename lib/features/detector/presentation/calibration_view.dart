import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:arkit_plugin/arkit_plugin.dart'; // iOS ARKit
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';

import '../../../core/constants/drowsiness_logic.dart';
import '../data/calibration_service.dart';
import '../data/face_detector_service.dart';
import '../data/face_mesh_service.dart';
import 'painters/face_detector_painter.dart';
import 'painters/face_mesh_painter.dart';

class CalibrationView extends StatefulWidget {
  const CalibrationView({super.key});

  @override
  State<CalibrationView> createState() => _CalibrationViewState();
}

class _CalibrationViewState extends State<CalibrationView> {
  // Services
  final FaceDetectorService _legacyService = FaceDetectorService();
  final FaceMeshService _meshService = FaceMeshService();
  final CalibrationService _calibrationService = CalibrationService();

  // Android / Legacy State
  CameraController? _controller;
  bool _isProcessing = false;
  CustomPaint? _customPaint;

  // iOS AR State
  bool _useArKit = false;
  ARKitController? _arController;
  ARKitNode? _faceNode;
  // Eye nodes removed as requested

  // Calibration Data
  bool _isCalibrating = false;
  final List<double> _earSamples = [];
  final List<double> _marSamples = [];
  String _statusMessage = "Press 'Start' to calibrate while awake.";

  // Real-time Feedback UI
  double _currentLiveEar = 0.0;
  double _currentLiveMar = 0.0;

  @override
  void initState() {
    super.initState();
    _checkPlatformAndInit();
  }

  Future<void> _checkPlatformAndInit() async {
    if (Platform.isIOS) {
      setState(() {
        _useArKit = true;
      });
    } else {
      _initializeCamera();
    }
  }

  // ----------------------------------------------------------------------
  // 1. iOS ARKit Implementation
  // ----------------------------------------------------------------------

  Widget _buildIOSView() {
    return ARKitSceneView(
      configuration: ARKitConfiguration.faceTracking,
      onARKitViewCreated: _onARViewCreated,
    );
  }

  void _onARViewCreated(ARKitController controller) {
    _arController = controller;
    _arController!.onAddNodeForAnchor = _handleAddAnchor;
    _arController!.onUpdateNodeForAnchor = _handleUpdateAnchor;
  }

  void _handleAddAnchor(ARKitAnchor anchor) {
    if (anchor is! ARKitFaceAnchor) return;

    // Face Mesh (Wireframe/Green tint)
    final material = ARKitMaterial(
      fillMode: ARKitFillMode.lines,
      diffuse: ARKitMaterialProperty.color(Colors.greenAccent.withOpacity(0.6)),
    );

    anchor.geometry.materials.value = [material];

    _faceNode = ARKitNode(geometry: anchor.geometry);
    _arController!.add(_faceNode!, parentNodeName: anchor.nodeName);
  }

  void _handleUpdateAnchor(ARKitAnchor anchor) {
    if (anchor is ARKitFaceAnchor && mounted) {
      // Update the Face Mesh Geometry so it deforms
      if (_faceNode != null) {
        _arController!.updateFaceGeometry(_faceNode!, anchor.identifier);
      }

      final shapes = anchor.blendShapes;
      final leftBlink = shapes['eyeBlink_L'] ?? 0.0;
      final rightBlink = shapes['eyeBlink_R'] ?? 0.0;
      final jawOpen = shapes['jawOpen'] ?? 0.0;

      // Update Logic (Simulated EAR)
      double avgOpenness = 1.0 - ((leftBlink + rightBlink) / 2.0);
      double simulatedEar = avgOpenness * 0.35;

      // Update Live UI
      setState(() {
        _currentLiveEar = simulatedEar;
        _currentLiveMar = jawOpen;
      });

      // Record Calibration Samples
      if (_isCalibrating) {
        _earSamples.add(simulatedEar);
        _marSamples.add(jawOpen);
      }
    }
  }

  // ----------------------------------------------------------------------
  // 2. Android / Legacy Implementation
  // ----------------------------------------------------------------------

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;

    final frontCamera = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _controller = CameraController(
      frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.nv21,
    );

    await _controller!.initialize();
    if (!mounted) return;

    _controller!.startImageStream(_processCameraImage);
    setState(() {});
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) return;

      if (Platform.isAndroid) {
        final meshes = await _meshService.processImage(inputImage);
        if (meshes.isNotEmpty) {
          final mesh = meshes.first;
          final ear = DrowsinessLogic.calculateMeshEAR(mesh);
          final mar = DrowsinessLogic.calculateMeshMAR(mesh);

          if (mounted) {
            setState(() {
              _currentLiveEar = ear;
              _currentLiveMar = mar;
              _customPaint = CustomPaint(
                painter: FaceMeshPainter(
                  meshes,
                  inputImage.metadata!.size,
                  inputImage.metadata!.rotation,
                  CameraLensDirection.front,
                  false,
                ),
              );
            });
          }
          if (_isCalibrating) {
            _earSamples.add(ear);
            _marSamples.add(mar);
          }
        }
      } else {
        final faces = await _legacyService.processImage(inputImage);
        if (faces.isNotEmpty) {
          final face = faces.first;
          final ear = DrowsinessLogic.calculateEAR(face);
          final mar = DrowsinessLogic.calculateLegacyMAR(face);

          if (mounted) {
            setState(() {
              _currentLiveEar = ear;
              _currentLiveMar = mar;
              _customPaint = CustomPaint(
                painter: FaceDetectorPainter(
                  faces,
                  inputImage.metadata!.size,
                  inputImage.metadata!.rotation,
                  CameraLensDirection.front,
                  false,
                ),
              );
            });
          }
          if (_isCalibrating) {
            _earSamples.add(ear);
            _marSamples.add(mar);
          }
        }
      }
    } catch (e) {
      debugPrint("Calibration error: $e");
    } finally {
      _isProcessing = false;
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (_controller == null) return null;
    final camera = _controller!.description;
    final sensorOrientation = camera.sensorOrientation;
    final orientations = {
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeLeft: 90,
      DeviceOrientation.portraitDown: 180,
      DeviceOrientation.landscapeRight: 270,
    };
    final rotationCompensation = (sensorOrientation + orientations[DeviceOrientation.portraitUp]! + 270) % 360;

    return InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: InputImageRotationValue.fromRawValue(rotationCompensation) ?? InputImageRotation.rotation270deg,
        format: Platform.isIOS ? InputImageFormat.bgra8888 : InputImageFormat.nv21,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  // ----------------------------------------------------------------------
  // 3. Calibration Logic & UI
  // ----------------------------------------------------------------------

  void _startCalibration() {
    setState(() {
      _isCalibrating = true;
      _earSamples.clear();
      _marSamples.clear();
      _statusMessage = "Calibrating... Keep eyes open naturally.";
    });
    Future.delayed(const Duration(seconds: 3), _finishCalibration);
  }

  Future<void> _finishCalibration() async {
    if (!mounted) return;
    setState(() => _isCalibrating = false);

    if (_earSamples.isEmpty) {
      setState(() => _statusMessage = "Failed: No face detected. Try again.");
      return;
    }

    double avgEar = _earSamples.reduce((a, b) => a + b) / _earSamples.length;
    double avgMar = _marSamples.reduce((a, b) => a + b) / _marSamples.length;

    double drowsyThreshold = avgEar * 0.8;
    await _calibrationService.saveBaselines(drowsyThreshold, avgMar, 0.0);

    setState(() {
      _statusMessage = "Done! Threshold: ${drowsyThreshold.toStringAsFixed(2)}";
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    _arController?.dispose();
    _legacyService.dispose();
    _meshService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget bodyContent;
    if (_useArKit) {
      bodyContent = _buildIOSView();
    } else {
      if (_controller == null || !_controller!.value.isInitialized) {
        bodyContent = const Center(child: CircularProgressIndicator());
      } else {
        final size = MediaQuery.of(context).size;
        var scale = size.aspectRatio * _controller!.value.aspectRatio;
        if (scale < 1) scale = 1 / scale;

        bodyContent = Transform.scale(
          scale: scale,
          child: Center(
            child: CameraPreview(_controller!, child: _customPaint),
          ),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text("Calibration")),
      body: Stack(
        fit: StackFit.expand,
        children: [
          bodyContent,
          Positioned(
            top: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text("Live EAR: ${_currentLiveEar.toStringAsFixed(2)}",
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  Text("Live MAR: ${_currentLiveMar.toStringAsFixed(2)}",
                      style: const TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 50,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_statusMessage, style: const TextStyle(color: Colors.white, fontSize: 16)),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _isCalibrating ? null : _startCalibration,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white
                    ),
                    child: Text(_isCalibrating ? "Scanning..." : "START CALIBRATION"),
                  ),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }
}
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
// ARKit Imports
import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:device_info_plus/device_info_plus.dart';

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
  // --- CAMERA (Standard/Android/Fallback) ---
  CameraController? _cameraController;
  final FaceDetectorService _detectorService = FaceDetectorService();

  // --- ARKIT (iOS FaceID) ---
  ARKitController? _arkitController;
  ARKitNode? _faceNode;

  final CalibrationService _calibrationService = CalibrationService();

  bool _isCalibrating = false;
  bool _calibrationSuccess = false;
  bool _isProcessing = false;
  int _timerCount = 10;

  // Capability Flag
  bool _useARKit = false;
  bool _capabilityCheckDone = false;

  List<double> _capturedEarValues = [];
  List<double> _capturedMarValues = [];

  String _message = "Position phone. Ensure face is visible.";
  double _currentPreviewEar = 0.0;
  double _currentPreviewMar = 0.0;

  CustomPaint? _customPaint;

  @override
  void initState() {
    super.initState();
    _checkDeviceCapabilities();
  }

  Future<void> _checkDeviceCapabilities() async {
    if (Platform.isIOS) {
      // Manual check using DeviceInfo
      final deviceInfo = DeviceInfoPlugin();
      final iosInfo = await deviceInfo.iosInfo;

      // Fallback logic: Detect if it's a simulator or a physical device.
      // ARKit doesn't work on Simulator.
      if (iosInfo.isPhysicalDevice) {
        // Assume TrueDepth availability for modern iPhones (iPhone X or newer).
        // It's safer to default to True and let it fail gracefully or user switch,
        // but strictly the user asked for fallback.
        setState(() {
          _useARKit = true;
          _capabilityCheckDone = true;
        });
      } else {
        // Simulator -> Fallback to ML Kit
        setState(() {
          _useARKit = false;
          _capabilityCheckDone = true;
        });
        _initCamera();
      }
    } else {
      // Android
      setState(() {
        _useARKit = false;
        _capabilityCheckDone = true;
      });
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
    if (!_useARKit && _cameraController == null) return;

    setState(() {
      _isCalibrating = true;
      _calibrationSuccess = false;
      _timerCount = 10;
      _capturedEarValues.clear();
      _capturedMarValues.clear();
      _message = "Keep eyes OPEN. Mouth CLOSED (Neutral).";
    });

    if (!_useARKit) {
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

  // --- ML KIT LOGIC (Android/Fallback) ---
  void _processCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = _prepareInputImage(image);
      if (inputImage != null) {
        final faces = await _detectorService.processImage(inputImage);

        if (faces.isNotEmpty) {
          final face = faces.first;
          final ear = DrowsinessLogic.calculateEAR(face);
          final mar = DrowsinessLogic.calculateMAR(face);

          final painter = FaceDetectorPainter(
            faces: faces,
            imageSize: inputImage.metadata!.size,
            rotation: inputImage.metadata!.rotation,
            cameraLensDirection: CameraLensDirection.front,
            isAlerting: false,
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
        } else {
          if (mounted) setState(() => _customPaint = null);
        }
      }
    } catch (e) {
      debugPrint("Calibration stream error: $e");
    } finally {
      _isProcessing = false;
    }
  }

  // --- ARKIT LOGIC (iOS FaceID) ---
  void _onARKitViewCreated(ARKitController arkitController) {
    _arkitController = arkitController;
    _arkitController?.onAddNodeForAnchor = _handleAddAnchor;
    _arkitController?.onUpdateNodeForAnchor = _handleUpdateAnchor;
  }

  void _handleAddAnchor(ARKitAnchor anchor) {
    if (anchor is! ARKitFaceAnchor) return;
    final material = ARKitMaterial(
        fillMode: ARKitFillMode.lines,
        diffuse: ARKitMaterialProperty.color(Colors.cyanAccent.withOpacity(0.8))
    );
    anchor.geometry.materials.value = [material];
    _faceNode = ARKitNode(geometry: anchor.geometry);
    _arkitController?.add(_faceNode!, parentNodeName: anchor.nodeName);
  }

  void _handleUpdateAnchor(ARKitAnchor anchor) {
    if (anchor is ARKitFaceAnchor && mounted) {
      if (_faceNode != null) {
        _arkitController?.updateFaceGeometry(_faceNode!, anchor.identifier);
      }

      // Calculate Metrics from Blendshapes
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
    if (!_useARKit) await _cameraController?.stopImageStream();
    setState(() => _customPaint = null);

    if (_capturedEarValues.isEmpty) {
      setState(() {
        _isCalibrating = false;
        _message = "Calibration Failed. No face detected.";
      });
      return;
    }

    // EAR Logic
    _capturedEarValues.sort();
    int start = (_capturedEarValues.length * 0.10).toInt();
    int end = (_capturedEarValues.length * 0.90).toInt();
    if (end <= start) { start = 0; end = _capturedEarValues.length; }

    List<double> validEar = _capturedEarValues.sublist(start, end);
    double avgOpenEar = validEar.reduce((a, b) => a + b) / validEar.length;
    double personalEarThreshold;

    if (_useARKit) {
      // ARKit uses simpler threshold logic due to range 0.0-1.0
      personalEarThreshold = avgOpenEar * 0.60;
    } else {
      // ML Kit
      personalEarThreshold = avgOpenEar * 0.75;
    }

    // MAR Logic
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
      _message = "Success!\n"
          "EAR Thresh: ${personalEarThreshold.toStringAsFixed(3)}\n"
          "MAR Thresh: ${personalMarThreshold.toStringAsFixed(3)}";
    });
  }

  Future<void> _safeExit() async {
    _isProcessing = true;

    // Stop Camera if used
    if (_cameraController != null) {
      if (_cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
      await _cameraController!.dispose();
    }
    _cameraController = null;

    // Dispose ARKit
    _arkitController?.dispose();
    _arkitController = null;

    if (!mounted) return;

    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    }
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
    if (!_capabilityCheckDone) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final bool isCameraReady = _useARKit || (_cameraController != null && _cameraController!.value.isInitialized);

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
            // --- VIDEO LAYER ---
            if (_useARKit)
              ARKitSceneView(
                configuration: ARKitConfiguration.faceTracking,
                onARKitViewCreated: _onARKitViewCreated,
                enableTapRecognizer: false,
              )
            else if (isCameraReady)
              Positioned.fill(
                child: Transform.scale(
                  scale: MediaQuery.of(context).size.aspectRatio * _cameraController!.value.aspectRatio < 1
                      ? 1 / (MediaQuery.of(context).size.aspectRatio * _cameraController!.value.aspectRatio)
                      : MediaQuery.of(context).size.aspectRatio * _cameraController!.value.aspectRatio,
                  child: Center(
                    child: CameraPreview(_cameraController!, child: _customPaint),
                  ),
                ),
              )
            else
              const Center(child: CircularProgressIndicator()),

            // --- UI LAYER ---
            Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (_isCalibrating)
                  Container(
                    padding: const EdgeInsets.only(top: 20),
                    child: Column(
                      children: [
                        Text(
                          "EAR: ${_currentPreviewEar.toStringAsFixed(3)}",
                          style: const TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              shadows: [Shadow(blurRadius: 2, color: Colors.black)]
                          ),
                        ),
                        Text(
                          "MAR: ${_currentPreviewMar.toStringAsFixed(3)}",
                          style: const TextStyle(
                              color: Colors.yellowAccent,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              shadows: [Shadow(blurRadius: 2, color: Colors.black)]
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  const SizedBox.shrink(),

                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: const BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  ),
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
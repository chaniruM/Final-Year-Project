import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class CameraUtils {
  static InputImage? prepareInputImage(
      CameraController controller, CameraImage image) {
    try {
      final plane = image.planes.first;
      return InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: InputImageRotation
              .rotation270deg, // Standard for front camera on most devices
          format: Platform.isIOS
              ? InputImageFormat.bgra8888
              : InputImageFormat.nv21,
          bytesPerRow: plane.bytesPerRow,
        ),
      );
    } catch (e) {
      return null;
    }
  }

  static Future<CameraController?> initializeFrontCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return null;

    final frontCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      frontCamera,
      ResolutionPreset.high,
      // ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup:
          Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.nv21,
    );

    await controller.initialize();
    return controller;
  }
}

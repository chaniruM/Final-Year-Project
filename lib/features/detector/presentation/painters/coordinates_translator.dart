import 'dart:io';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';

/// Translator utility to map absolute coordinates from the camera image stream
/// to the dynamic widget canvas size on the device screen.
double translateX(
  double x,
  Size canvasSize,
  Size imageSize,
  InputImageRotation rotation,
  CameraLensDirection cameraLensDirection,
) {
  double scaledX;

  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      scaledX = x *
          canvasSize.width /
          (Platform.isIOS ? imageSize.width : imageSize.height);
      break;
    case InputImageRotation.rotation0deg:
    case InputImageRotation.rotation180deg:
    default:
      scaledX = x * canvasSize.width / imageSize.width;
      break;
  }

  if (cameraLensDirection == CameraLensDirection.front) {
    // Platform-Specific Sensor Mirroring
    // Apple iOS natively pre-mirrors the raw BGRA8888 camera buffers at the OS level.
    // Android natively outputs raw, unmirrored NV21 buffers.
    // Therefore, we apply mathematical X-axis mirroring ONLY on non-iOS devices.
    if (!Platform.isIOS) {
      return canvasSize.width - scaledX;
    } else {
      return scaledX;
    }
  }

  return scaledX;
}

double translateY(
  double y,
  Size canvasSize,
  Size imageSize,
  InputImageRotation rotation,
  CameraLensDirection cameraLensDirection,
) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      return y *
          canvasSize.height /
          (Platform.isIOS ? imageSize.height : imageSize.width);
    default:
      return y * canvasSize.height / imageSize.height;
  }
}

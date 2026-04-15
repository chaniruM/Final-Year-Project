import 'dart:io';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';

double translateX(
    double x,
    Size canvasSize,
    Size imageSize,
    InputImageRotation rotation,
    CameraLensDirection cameraLensDirection,
    ) {
  double translatedX;
  switch (rotation) {
    case InputImageRotation.rotation90deg:
      translatedX = x * canvasSize.width / (Platform.isIOS ? imageSize.width : imageSize.height);
      break;
    case InputImageRotation.rotation270deg:
      translatedX = canvasSize.width - x * canvasSize.width / (Platform.isIOS ? imageSize.width : imageSize.height);
      break;
    case InputImageRotation.rotation0deg:
    case InputImageRotation.rotation180deg:
      translatedX = x * canvasSize.width / imageSize.width;
      break;
  }

  if (cameraLensDirection == CameraLensDirection.front) {
    return canvasSize.width - translatedX;
  }
  return translatedX;
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
      return y * canvasSize.height / (Platform.isIOS ? imageSize.height : imageSize.width);
    default:
      return y * canvasSize.height / imageSize.height;
  }
}
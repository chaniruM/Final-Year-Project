import 'dart:io';
import 'package:flutter/services.dart';

class CapabilityUtils {
  // Define the channel name
  static const MethodChannel _channel =
      MethodChannel('com.chaniru.drivesafe/capabilities');

  static Future<bool> supportsARKit() async {
    // If not iOS, it definitely doesn't support ARKit/TrueDepth
    if (!Platform.isIOS) return false;

    try {
      // Invoke the native iOS method
      final bool supportsTrueDepth =
          await _channel.invokeMethod('checkTrueDepthSupport');
      return supportsTrueDepth;
    } on PlatformException catch (_) {
      // If the channel fails, safely fallback to false
      return false;
    }
  }
}

import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';

class CapabilityUtils {
  static Future<bool> supportsARKit() async {
    if (!Platform.isIOS) return false;

    final deviceInfo = DeviceInfoPlugin();
    final iosInfo = await deviceInfo.iosInfo;

    // ARKit does not work on Simulators.
    // It assumes TrueDepth camera is available on physical iPhones (Model X+).
    // This is a simplified check.
    return iosInfo.isPhysicalDevice;
  }
}
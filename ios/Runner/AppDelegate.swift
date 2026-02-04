import Flutter
import UIKit
import ARKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // Get reference to the Flutter View Controller
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController

    // Creating the MethodChannel for capability check
    let channel = FlutterMethodChannel(name: "com.chaniru.drivesafe/capabilities", binaryMessenger: controller.binaryMessenger)

    // Set up the handler to listen for Dart calls
    channel.setMethodCallHandler({
        (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in

        // Handle the specific method call
        if call.method == "checkTrueDepthSupport" {
          // Check if ARFaceTracking is supported by the hardware
          if #available(iOS 11.0, *) {
              result(ARFaceTrackingConfiguration.isSupported)
          } else {
              // Fallback for very old iOS versions
              result(false)
          }
        } else {
          result(FlutterMethodNotImplemented)
        }
    })

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

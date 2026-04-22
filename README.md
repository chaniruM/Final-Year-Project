# Drive Safe - Driver Monitoring System

**Interim Progression Demonstration (IPD)**

**Student Name:** Chaniru Mannapperuma  
**Student ID:** w2051988  
**Module:** 6COSC023W - Computer Science Final Project

---

**Drive Safe** is a premium, cross-platform mobile application designed to detect driver drowsiness and distraction in real-time. It leverages advanced computer vision and a **Hybrid Sensing Strategy** that dynamically switches between high-fidelity 3D tracking (ARKit on iOS) and standard 2D tracking (Google ML Kit on Android and older iOS devices) to ensure maximum compatibility and performance without relying on an internet connection.

---

## 📑 Table of Contents

- [Key Features](#-key-features)
- [Tech Stack](#-tech-stack)
- [Project Architecture](#-project-architecture)
- [Setup & Installation](#️-setup--installation)
- [How to Run the Code](#-how-to-run-the-code)
- [Building for Production](#-building-for-production)
- [Testing](#-testing)
- [Usage Guide](#-usage-guide)
- [Algorithms Implementation](#-algorithms-implementation)
- [License](#-license)

---

## 🚀 Key Features

- **Hybrid Sensing Engine:** Seamlessly transitions between ARKit (3D blendshapes) and ML Kit (2D contours).
- **Multi-Factor Fusion Engine:** Aggregates PERCLOS (Percentage of Eye Closure), Head Pose (pitch/yaw), and Yawning (Mouth Aspect Ratio) into a comprehensive drowsiness score.
- **Occlusion Handling (Sunglasses Mode):** Automatically detects if eyes are covered and gracefully relies on head pose and mouth movements.
- **Premium UI/UX:** Built with a modern glassmorphism design, vibrant color palettes, and smooth micro-animations.
- **Privacy-First:** 100% on-device processing. No video feeds or biometric data are sent to the cloud.
- **Background Persistence:** Utilizes Wakelock Plus to keep the screen and camera active during long drives.

---

## 🛠️ Tech Stack

| Category | Technology |
|----------|------------|
| **Framework** | Flutter (Dart) |
| **State Management** | Riverpod |
| **Computer Vision (2D)** | `google_mlkit_face_detection` |
| **Computer Vision (3D)** | `arkit_plugin` |
| **Native Integration** | Swift (iOS AppDelegate MethodChannels) |
| **Local Storage** | `shared_preferences` |

---

## 📂 Project Architecture

The codebase strictly adheres to **Clean Architecture** principles to separate business logic, state management, and the user interface.

```
lib/
├── core/
│   ├── constants/        # Biometric formulas and threshold configurations
│   └── utils/            # Capability checks, signal smoothers, and camera utilities
├── features/
│   └── detector/
│       ├── data/         # Repositories and Services (FaceDetectorService, CalibrationService)
│       ├── logic/        # Fusion Engine & State Management (Riverpod Providers)
│       └── presentation/ # UI Views (Detector, Calibration, Onboarding)
└── main.dart             # Application Entry Point
```

---

## ⚙️ Setup & Installation

Follow these steps to set up the development environment on your local machine.

### Prerequisites

1. **Flutter SDK:** Version `3.3.0` or higher (Managed via FVM is recommended).
2. **Dart SDK:** Included with Flutter.
3. **IDE:** VS Code or Android Studio.
4. **Platform Tools:** 
   - **macOS:** Xcode installed for iOS development.
   - **Windows/macOS/Linux:** Android Studio with Android SDK installed.

### 1. Clone the Repository

```bash
git clone https://github.com/chaniruM/Final-Year-Project.git
cd drive-safe
git checkout IPD-demonstration
```

### 2. Install Dependencies (Using FVM)

If you are using Flutter Version Management (FVM), run the following to sync the SDK and get packages:

```bash
fvm install
fvm flutter clean
fvm flutter pub get
```

*(If you are not using FVM, just use `flutter clean` and `flutter pub get`)*

### 3. iOS Specific Configuration

ARKit and Camera access require specific native permissions.
1. Open `ios/Runner.xcworkspace` in **Xcode**.
2. Go to the **Signing & Capabilities** tab and select your Apple Developer account to sign the app.
3. Verify that `Info.plist` contains the `NSCameraUsageDescription` key explaining camera usage.
4. Verify `AppDelegate.swift` contains the `checkTrueDepthSupport` MethodChannel handler for capabilities checks.

---

## 🏃 How to Run the Code

To properly test camera features, it is **highly recommended** to run the app on a physical device rather than an emulator/simulator.

### Running on Android

1. Enable **Developer Options** and **USB Debugging** on your Android device.
2. Connect your device via USB.
3. Run the application:
   ```bash
   fvm flutter run
   ```

### Running on iOS

1. Connect your iPhone via USB.
2. Ensure the device is selected as the deployment target in Xcode or VS Code.
3. Run the application:
   ```bash
   fvm flutter run
   ```
*(Note: ARKit 3D features are only available on iOS devices with TrueDepth cameras, e.g., iPhone X and newer).*

---

## 📦 Building for Production

To build a standalone executable for distribution or presentation, use the release build commands.

**Build an Android APK:**
```bash
fvm flutter build apk --release
```
*The output APK will be located in `build/app/outputs/flutter-apk/app-release.apk`.*

**Build an iOS IPA (requires Apple Developer Account):**
```bash
fvm flutter build ipa --release
```

---

## 🧪 Testing

The project includes unit testing for core algorithms and business logic, including the `FusionEngine` and `CalibrationService`.

To run the test suite:
```bash
fvm flutter test
```

Tests cover:
- Biometric score calculation and thresholds.
- Microsleep and yawning detection logic.
- Sunglasses/Occlusion mode fallback scenarios.
- Persistent local storage logic.

---

## 📱 Usage Guide

### 1. Onboarding
Upon launching the app for the first time, users are guided through an onboarding flow that explains how the Hybrid Engine works and what biometric signals are tracked.

### 2. Calibration
Before driving, the system needs to learn your "neutral" resting face:
1. Ensure you are in a well-lit environment.
2. Navigate to the **Calibration** screen.
3. Hold the device at eye level and stay still for 10 seconds.
4. The system calculates and securely stores your baseline EAR (Eye Aspect Ratio), MAR (Mouth Aspect Ratio), and Pitch.

### 3. Active Monitoring
1. From the Home Dashboard, tap **Start Drive**.
2. The UI will indicate tracking status:
   - **ARKit Mode:** Green visual mesh (High precision 3D).
   - **ML Kit Mode:** Bounding boxes and contour points (2D Fallback).
3. The system continuously evaluates PERCLOS and alerts you via visual cues, haptics, and audio if drowsiness or distraction is detected.

---

## 🧠 Algorithms Implementation

### Eye Aspect Ratio (EAR) & PERCLOS
- **EAR** measures the opening of the eyes.
- **PERCLOS** tracks the percentage of frames where the eyes are closed over a rolling time window to determine overall fatigue rather than singular blinks.

### Mouth Aspect Ratio (MAR)
- Tracks the distance between the inner upper and lower lips to reliably identify yawning events and filter out talking/singing.

### Head Pose (Pitch & Yaw)
- Uses Quaternion decomposition (ARKit) or direct Euler angles (ML Kit) to detect "nodding off" (pitch) or "looking away" (yaw) distractions.

---

## 📄 License

This project is submitted for academic assessment at the University of Westminster. All rights reserved by the author.

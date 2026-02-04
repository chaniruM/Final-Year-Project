# Driver Monitoring System Proof of Concept (Drive Safe)

**Interim Progression Demonstration (IPD)**

**Student Name:** Chaniru Mannapperuma
**Student ID:** w2051988  
**Module:** 6COSC023W - Computer Science Final Project

---

Drive Safe is a cross-platform mobile application designed to detect driver drowsiness and distraction in real-time. The system utilizes a **Hybrid Sensing Strategy** that dynamically switches between high-fidelity 3D tracking (ARKit) and standard 2D computer vision (Google ML Kit) based on device hardware capabilities.

---

## 📑 Table of Contents

- [Key Features](#-key-features)
- [Tech Stack](#-tech-stack)
- [Project Structure](#-project-structure)
- [Algorithms Implementation](#-algorithms-implementation)
- [Installation & Setup](#️-installation--setup)
- [Usage Guide](#-usage-guide)
- [License](#-license)

---

## 🚀 Key Features

### 1. Hybrid Sensing Engine

- **iOS TrueDepth (ARKit):** Utilizes 3D blendshapes for precise eye-blink and mouth-yawn detection on supported iPhones (X and newer).
- **Universal Fallback (ML Kit):** Automatically falls back to 2D contour detection on Android devices or older iPhones.
- **Native Bridge:** Implements a custom Swift MethodChannel to query hardware capabilities at runtime.

### 2. Multi-Factor Fusion Engine

Detects fatigue by aggregating multiple biometric signals:

- **PERCLOS (Percentage of Eye Closure):** Calculated over a rolling 900-frame window.
- **Head Pose Estimation:** Detects "nodding off" events using Matrix decomposition (ARKit) or Euler angles (ML Kit).
- **Yawn Detection:** Monitors Mouth Aspect Ratio (MAR) specifically using inner-lip contours.

### 3. Adaptive & Robust Logic

- **Occlusion Handling:** Automatically detects if eyes are covered (e.g., by sunglasses) and shifts scoring weights to rely on Head Pose and Mouth signals.
- **Signal Smoothing:** Uses moving average buffers to eliminate camera noise and prevent false positives.

### 4. Privacy-First Architecture

- **On-Device Processing:** All computer vision tasks run locally; no video feed is ever sent to a server.
- **Local Calibration:** User baselines are stored securely on the device using SharedPreferences.

---

## 🛠️ Tech Stack

| Category | Technology |
|----------|------------|
| Framework | Flutter (Dart) |
| Computer Vision (2D) | google_mlkit_face_detection |
| Computer Vision (3D) | arkit_plugin |
| Native Integration | Swift (iOS AppDelegate) |
| Architecture | Clean Architecture (Presentation, Domain, Data) |
| Local Storage | shared_preferences |

---

## 📂 Project Structure

The project follows strict **Clean Architecture** principles to separate business logic from UI and data handling.

```
lib/
├── core/
│   ├── constants/        # Biometric formulas (EAR, MAR, Thresholds)
│   └── utils/            # MethodChannels, Signal Smoothers, Camera Utils
├── features/
│   └── detector/
│       ├── data/         # Face Detector Service, Calibration Service
│       ├── logic/        # Fusion Engine (State Machine)
│       └── presentation/ # DetectorView, CalibrationView, Painters
└── main.dart             # App Entry Point
```

---

## 🧪 Algorithms Implementation

### 1. Eye Aspect Ratio (EAR) - Blink Detection

Used for detecting micro-sleeps. For 2D ML Kit, we use a geometric bounding box approach for stability.

```dart
// 2D ML Kit Logic
double calculateEAR(double eyeHeightMax, double eyeHeightMin, double eyeWidthMax, double eyeWidthMin) {
  // EAR = Distance(Upper, Lower) / Distance(Left, Right)
  return (eyeHeightMax - eyeHeightMin) / (eyeWidthMax - eyeWidthMin);
}
```

### 2. Mouth Aspect Ratio (MAR) - Yawn Detection

To detect yawning, we calculate the ratio of the mouth's vertical opening to its horizontal width.

```dart
// MAR Calculation
double calculateMAR(Point<int> topLip, Point<int> bottomLip, Point<int> leftCorner, Point<int> rightCorner) {
  double verticalDist = euclideanDistance(topLip, bottomLip);
  double horizontalDist = euclideanDistance(leftCorner, rightCorner);
  return verticalDist / horizontalDist;
}
```

### 3. PERCLOS (Percentage of Eye Closure)

Fatigue is quantified using the PERCLOS standard. We maintain a circular buffer of the last 900 frames (approx. 30 seconds at 30fps) to calculate drowsiness trends rather than instantaneous blinks.

```dart
// PERCLOS Logic
double calculatePERCLOS(Queue<bool> eyeClosureHistory) {
  int closedFrames = eyeClosureHistory.where((isClosed) => isClosed).length;
  // Result > 0.15 usually indicates drowsiness
  return closedFrames / eyeClosureHistory.length;
}
```

### 4. Head Pose Estimation (Pitch, Yaw, Roll)

**ARKit Strategy:**  
To avoid Gimbal Lock, rotation is extracted from the 4x4 Transformation Matrix using Quaternions.

```dart
// ARKit Quaternion Conversion
final q = vector.Quaternion.fromRotation(transform.getRotation());
final pitch = -vector.degrees(asin(2 * (q.w * q.x - q.y * q.z)));
```

**ML Kit Strategy:**  
We utilize the Euler angles provided directly by the Face object.

```dart
// ML Kit Fallback
bool isDistracted = (face.headEulerAngleY.abs() > 30) || // Looking side-to-side
                    (face.headEulerAngleX > 20);         // Nodding down
```

### 5. Multi-Factor Fusion (Scoring)

The final drowsiness score is a weighted sum of individual signals.

$$Score = (W_{ear} \times Signal_{ear}) + (W_{mar} \times Signal_{mar}) + (W_{pose} \times Signal_{pose})$$

If occlusion (e.g., sunglasses) is detected, $W_{ear}$ is set to 0, and $W_{pose}$ and $W_{mar}$ are increased dynamically.

---

## ⚙️ Installation & Setup

### Prerequisites

- **Flutter Version Management (FVM)** (Recommended)
- **Flutter SDK:** 3.38.7 (Stable)
- **Dart SDK:** 3.10.7
- Xcode (for iOS deployment)
- Physical iOS Device (Recommended for ARKit features) or Android Device

### 1. Clone & Dependencies

```bash
git clone https://github.com/chaniruM/Final-Year-Project.git
cd drive-safe

# Checkout the IPD demonstration branch
git checkout IPD-demonstration

# Install configured version via FVM
fvm install

# Get dependencies
fvm flutter pub get
```

### 2. iOS Configuration

This project uses a custom native implementation for hardware checking.

1. Open `ios/Runner.xcworkspace` in Xcode.
2. Ensure `NSCameraUsageDescription` is set in `Info.plist` to allow camera access.
3. Verify `AppDelegate.swift` contains the `checkTrueDepthSupport` MethodChannel handler.

### 3. Run the App

**For iOS (Physical Device recommended):**

```bash
fvm flutter run -d <device_id>
```

**For Android:**

```bash
fvm flutter run
```

---

## 📱 Usage Guide

### 1. Calibration (First Run)

1. Navigate to the **Settings (Calibration)** screen.
2. Hold the phone steady for 10 seconds.
3. The app learns your "resting" Eye Aspect Ratio (EAR) and saves it securely.

### 2. Monitoring Mode

1. Return to the Home screen and tap **Start Monitoring**.
2. The interface will show your real-time biometrics.
    - **Green Mesh:** Indicates ARKit (3D) is active.
    - **Bounding Boxes:** Indicates ML Kit (2D) is active.

### 3. Simulating Alerts

To test the system, perform the following actions:

- **Micro-sleep:** Close your eyes for >2 seconds.
- **Distraction:** Turn your head away or nod down.
- **Yawning:** Open mouth wide.

---

## 📄 License

This project is submitted for academic assessment at the University of Westminster.

---

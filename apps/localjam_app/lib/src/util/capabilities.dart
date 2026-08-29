/// What this platform can actually do, so screens gate on a named capability
/// rather than on an inline `Platform.isX` chain.
library;

import 'package:flutter/foundation.dart';

/// Whether a camera scanner exists here. `mobile_scanner` ships no Windows or
/// Linux implementation, so desktop Linux/Windows guests join by link.
bool get canScanQrCodes =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

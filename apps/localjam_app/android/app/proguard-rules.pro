# ---------------------------------------------------------------------------
# LocalJam release shrinking rules.
# Applied on top of proguard-android-optimize.txt (see app/build.gradle.kts).
# ---------------------------------------------------------------------------

# --- Flutter engine + embedding -------------------------------------------
# The engine looks these up reflectively from C++/JNI, and the generated
# plugin registrant instantiates every plugin by name.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# --- localjam_audio --------------------------------------------------------
# JamSessionService is named in the merged manifest, and the plugin class is
# instantiated reflectively by GeneratedPluginRegistrant. JamSession/
# JamMediaLibrary hold the AudioTrack + MediaStore paths reached from JNI.
-keep class dev.bimsina.localjam_audio.** { *; }
-keep class dev.bimsina.localjam.MainActivity { *; }

# Android media-session callbacks are invoked reflectively by the framework.
-keep class android.support.v4.media.** { *; }
-keep class androidx.media.** { *; }

# --- mobile_scanner / ML Kit barcode scanning ------------------------------
# ML Kit ships optional model downloaders; R8 warns about the ones we don't
# bundle. Keep the barcode surface and silence the rest.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-dontwarn com.google.mlkit.vision.**
-dontwarn com.google.android.gms.internal.mlkit_**
-dontwarn com.google.android.play.core.**

# --- Misc plugin surfaces --------------------------------------------------
# permission_handler, share_plus and file_selector reach Android framework
# callbacks through generated Pigeon/MethodChannel classes.
-keep class com.baseflow.permissionhandler.** { *; }
-keep class dev.fluttercommunity.plus.share.** { *; }

# Keep annotations and generic signatures so reflective lookups still resolve.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

# --- Logging ---------------------------------------------------------------
# Debug and verbose logs (file paths of the track being played, among others)
# stay out of a release build's logcat. Warnings and errors are kept.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
}

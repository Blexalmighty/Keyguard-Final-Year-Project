plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "ng.keyguard.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Was `com.example.keyguard`. Changed before Firebase exists, on purpose:
        // a Firebase Android app is registered against one package name, and
        // changing it afterwards means re-registering and downloading a fresh
        // google-services.json. `com.example.` is also rejected by the Play Store,
        // so it could never have shipped as-is.
        applicationId = "ng.keyguard.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Debug keys, deliberately. A release build signed with the debug
            // keystore installs and runs on any phone by sideloading, which is
            // what hardware testing needs — it only blocks a Play Store upload.
            //
            // For that, generate a keystore and add android/key.properties. Until
            // then, note that every machine has a *different* debug keystore, so
            // an APK built here cannot be installed over one built elsewhere
            // without uninstalling first.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

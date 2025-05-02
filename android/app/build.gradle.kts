import java.util.Properties
import java.io.FileInputStream
import org.gradle.api.GradleException // Also import GradleException

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Read properties from key.properties file if it exists
val keyPropertiesFile = rootProject.file("key.properties") // Look for key.properties in android/ directory
val keyProperties = Properties() // Use imported Properties
if (keyPropertiesFile.exists()) {
    try {
        keyProperties.load(FileInputStream(keyPropertiesFile)) // Use imported FileInputStream
    } catch (e: java.io.IOException) {
        throw GradleException("Could not read key.properties file", e) // Use imported GradleException
    }
}

android {
    namespace = "com.caffeinatedfirefly.radcxp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.caffeinatedfirefly.radcxp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keyProperties["keyAlias"] as String? ?: System.getenv("KEY_ALIAS")
            keyPassword = keyProperties["keyPassword"] as String? ?: System.getenv("KEY_PASSWORD")
            storeFile = rootProject.file(keyProperties["storeFile"] as String? ?: System.getenv("STORE_FILE") ?: "key.jks") // Default to key.jks if not specified
            storePassword = keyProperties["storePassword"] as String? ?: System.getenv("KEYSTORE_PASSWORD")
        }
    }

    buildTypes {
        release {
            // Use the release signing config
            signingConfig = signingConfigs.getByName("release")
            // Other release settings like ProGuard/R8 can be added here
            // minifyEnabled = true
            // shrinkResources = true
            // proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}

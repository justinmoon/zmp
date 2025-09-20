plugins {
  id("com.android.application")
  id("org.jetbrains.kotlin.android")
}

val zmpNative = (project.findProperty("zmpNative") as String?)?.toBoolean() ?: false

android {
  namespace = "com.example.demo"
  compileSdk = 34
  defaultConfig {
    applicationId = "com.example.demo"
    minSdk = 24
    targetSdk = 34
    versionCode = 1
    versionName = "1.0"
    buildConfigField("int", "DEV_SERVER_PORT", "8085")
    buildConfigField("boolean", "DEV_NATIVE", zmpNative.toString())
  }
  buildFeatures {
    buildConfig = true
  }
  buildTypes {
    getByName("release") { isMinifyEnabled = false }
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  kotlinOptions { jvmTarget = "17" }
}

dependencies {
  implementation("androidx.appcompat:appcompat:1.7.0")
  implementation("androidx.webkit:webkit:1.11.0")
  implementation("androidx.activity:activity-ktx:1.9.2")
}

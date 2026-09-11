buildscript {
    repositories { mavenCentral() }
    dependencies {
        // Official AGP built-in Kotlin version override; LiteRT-LM uses Kotlin 2.4.
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.20")
    }
}
plugins {
    id("com.android.application") version "9.4.0" apply false
}

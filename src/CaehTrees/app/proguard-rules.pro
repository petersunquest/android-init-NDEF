# R8 / ProGuard — release（WebView + Compose + Kotlin）

-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# WebView ↔ JS：CashTreesAndroid 桥接类不可混淆/裁剪
-keepattributes JavascriptInterface
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-keep class com.beamio.caehtrees.MainActivity$CashTreesJsBridge {
    *;
}

# Kotlin 元数据（反射/协程等由依赖自带 consumer rules；此处兜底）
-dontwarn kotlin.**
-dontwarn kotlinx.**

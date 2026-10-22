# kotlinx.serialization: keep generated serializers for the wire types.
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class dev.dpatel.passthrough.core.** {
    *** Companion;
}
-keepclasseswithmembers class dev.dpatel.passthrough.core.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# iroh (uniffi bindings over JNA): JNA binds native functions, callbacks and
# Structure fields by their Java names, and calls back into JNA classes from
# native code, so neither package may be renamed or stripped.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class computer.iroh.** { *; }
-dontwarn java.awt.**

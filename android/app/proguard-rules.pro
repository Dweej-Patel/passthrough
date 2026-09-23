# kotlinx.serialization: keep generated serializers for the wire types.
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class dev.dpatel.passthrough.core.** {
    *** Companion;
}
-keepclasseswithmembers class dev.dpatel.passthrough.core.** {
    kotlinx.serialization.KSerializer serializer(...);
}

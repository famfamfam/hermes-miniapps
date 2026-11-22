# Room creates generated database implementations through reflection.
-keepclassmembers class * extends androidx.room.RoomDatabase {
    <init>();
}

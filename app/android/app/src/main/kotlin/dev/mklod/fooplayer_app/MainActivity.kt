package dev.mklod.fooplayer_app

import com.ryanheise.audioservice.AudioServiceActivity

// AudioServiceActivity, not FlutterActivity: audio_service runs playback in a
// foreground service with its own Flutter engine, and the activity has to
// hand its engine over rather than starting a second one. With a plain
// FlutterActivity the notification appears but its buttons talk to an engine
// that isn't the one making sound.
class MainActivity : AudioServiceActivity()

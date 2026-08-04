package dev.mklod.fooplayer_app

// SyncForegroundService: keeps LAN sync alive when the app is backgrounded.
//
// Reported live: a sync started, the user backgrounded the app (normal phone
// use), and Android cut the process's network mid-transfer -- "connection
// closed midstream" -- with nothing anywhere telling the user a sync was
// even running in the first place. A plain `dataSync` foreground service
// fixes both halves at once: Android keeps a foreground process's network
// alive, and the mandatory notification that comes with `startForeground`
// doubles as the "here is what's happening" indicator the phone never had
// (see ../../sync/sync_foreground.dart for the Dart side that drives this).
//
// Talked to exclusively through SmbBridge.kt's three `syncFg*` MethodChannel
// handlers, which call the static start/update/stop helpers below -- Dart
// never constructs an Intent itself and never binds to this service.
// `onBind` returns null accordingly: there is no client to bind, only
// fire-and-forget commands carried as Intent extras.
//
// Last modified: 2026-08-04--0131

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log

class SyncForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            when (intent?.getStringExtra(EXTRA_ACTION)) {
                ACTION_START -> {
                    ensureChannel()
                    startForeground(NOTIFICATION_ID, buildNotification(intent))
                }
                ACTION_UPDATE -> {
                    ensureChannel()
                    val manager =
                        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    manager.notify(NOTIFICATION_ID, buildNotification(intent))
                }
                ACTION_STOP -> {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
                else -> {
                    // Missing/unknown action -- e.g. the system relaunching
                    // this service with a null Intent after the process was
                    // killed. There is no label/progress to show and no
                    // in-flight sync to keep alive in that case, so there is
                    // nothing useful to do.
                    Log.w(TAG, "onStartCommand: no action in intent, ignoring")
                }
            }
        } catch (e: Exception) {
            // A progress notification is a nicety; it must never take the
            // whole process down with it. (update()/stop() calls already
            // wrap their own Intent dispatch in try/catch for the "service
            // isn't running" case -- this is the belt for whatever slips
            // past that, e.g. a permission failure inside notify() itself.)
            Log.w(TAG, "onStartCommand failed", e)
        }
        // Never sticky: this service's whole lifetime is driven by explicit
        // start/update/stop calls mirroring Dart's ActivityModel state, not
        // by the system restarting it after a low-memory kill -- a
        // system-restarted instance has no label or progress to resume.
        return START_NOT_STICKY
    }

    private fun buildNotification(intent: Intent): Notification {
        val label = intent.getStringExtra(EXTRA_LABEL) ?: "Syncing"
        val done = intent.getIntExtra(EXTRA_DONE, -1)
        val total = intent.getIntExtra(EXTRA_TOTAL, -1)
        val indeterminate = total <= 0

        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(label)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setOngoing(true)
            // Progress updates fire every 256KB (see SmbBridge's
            // PROGRESS_STEP_BYTES) -- without this, each one would reissue
            // the heads-up/sound behavior a brand new notification gets.
            .setOnlyAlertOnce(true)
            .setProgress(if (indeterminate) 0 else total, if (indeterminate) 0 else done, indeterminate)
            .setContentIntent(contentIntent)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW)
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val TAG = "fooplayer.syncfg"
        private const val CHANNEL_ID = "sync"
        private const val CHANNEL_NAME = "Library sync"
        private const val NOTIFICATION_ID = 1001

        private const val EXTRA_ACTION = "action"
        private const val EXTRA_LABEL = "label"
        private const val EXTRA_DONE = "done"
        private const val EXTRA_TOTAL = "total"

        private const val ACTION_START = "start"
        private const val ACTION_UPDATE = "update"
        private const val ACTION_STOP = "stop"

        private fun intentFor(context: Context, action: String, label: String?, done: Int, total: Int) =
            Intent(context, SyncForegroundService::class.java).apply {
                putExtra(EXTRA_ACTION, action)
                if (label != null) putExtra(EXTRA_LABEL, label)
                putExtra(EXTRA_DONE, done)
                putExtra(EXTRA_TOTAL, total)
            }

        /** Starts (or restarts) the foreground notification with [label]. */
        fun start(context: Context, label: String) {
            val intent = intentFor(context, ACTION_START, label, -1, -1)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /**
         * Rebuilds the notification with fresh progress. Routed through the
         * plain (non-foreground) `startService` -- ACTION_UPDATE's handler
         * calls `NotificationManager.notify`, not `startForeground`, so
         * there is no "must call startForeground within N seconds" promise
         * to keep here the way there is for [start]. Wrapped in try/catch:
         * if the service was already stopped (or never started -- e.g. a
         * stray update racing a stop), `startService` from a backgrounded
         * app can throw on API 26+, and a progress notification missing one
         * update is not worth crashing over.
         */
        fun update(context: Context, label: String, done: Int, total: Int) {
            val intent = intentFor(context, ACTION_UPDATE, label, done, total)
            try {
                context.startService(intent)
            } catch (e: Exception) {
                Log.w(TAG, "update: service not running, dropping update", e)
            }
        }

        /** Tears the notification down. Same "may already be gone" story as
         * [update] -- harmless either way. */
        fun stop(context: Context) {
            val intent = intentFor(context, ACTION_STOP, null, -1, -1)
            try {
                context.startService(intent)
            } catch (e: Exception) {
                Log.w(TAG, "stop: service not running, ignoring", e)
            }
        }
    }
}

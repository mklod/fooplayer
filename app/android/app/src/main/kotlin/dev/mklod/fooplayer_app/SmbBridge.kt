package dev.mklod.fooplayer_app

// SmbBridge: the Android-only platform side of SmbTransport (Dart:
// app/lib/sync/smb_transport.dart). SMBJ is a blocking, synchronous client
// -- every SMB-session-touching method below runs on [executor], a single
// background thread, NEVER on the Flutter platform thread the MethodChannel
// call arrives on. `probe`/`cancel`/`close` run on [controlExecutor]
// instead -- see its doc for why. Results (and progress events) are always
// posted back via [handler] on the main looper, since MethodChannel.Result
// and EventChannel.EventSink are platform-thread-only APIs.
//
// PROCESS SINGLETON (review round 1, Critical C-1): construct via
// [SmbBridge.attach], never the constructor directly -- see its doc.
//
// CRITICAL SEMANTIC (carried from Task 9's review, pinned by
// SyncEngine's per-root exception containment -- see smb_transport.dart's
// class doc for the Dart side of this contract): every method here THROWS
// on a connection drop or any other genuine failure -- never a silently
// partial listing, an empty list standing in for "unreachable", or null
// standing in for "read failed". `readFile` returns null ONLY for
// NT_STATUS_OBJECT_NAME_NOT_FOUND / OBJECT_PATH_NOT_FOUND (the object
// genuinely doesn't exist); `listTree` returns an empty list ONLY when the
// TOP-LEVEL requested directory itself doesn't exist -- any failure
// discovered while walking its children (including losing the connection
// mid-walk) propagates as a thrown SMBApiException. `deleteRemote` maps
// those same not-found statuses to a silent no-op (idempotent delete). The
// ONE deliberate exception to "throw on failure" is [doProbe]: it catches
// everything, including malformed arguments, and always resolves to a
// plain boolean, bounded to ~5s regardless of how the network is failing.
//
// Last modified: 2026-08-04--0131
import android.content.Context
import android.os.Handler
import android.util.Log
import android.os.Looper
import android.os.StatFs
import com.hierynomus.mserref.NtStatus
import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.msfscc.fileinformation.FileStandardInformation
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.mssmb2.SMBApiException
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.SocketFactory

class SmbBridge private constructor(messenger: BinaryMessenger, context: Context) {
    // applicationContext, not the raw Activity context handed to [attach] --
    // this outlives any one Activity instance exactly like the rest of this
    // singleton does (see [attach]'s doc), and is only ever used to build
    // Intents for [SyncForegroundService], never to touch UI.
    private val appContext: Context = context.applicationContext

    // All real SMB-session work happens here, one call at a time. SMBJ has
    // no async API worth using for this app's traffic (small JSON files +
    // occasional large audio downloads), so a single background thread is
    // enough and keeps every remote session's calls naturally serialized.
    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "smb-bridge").apply { isDaemon = true }
    }

    // A separate pool for operations that must NEVER wait behind whatever
    // is currently running on the serialized [executor] (review I-1, I-2):
    // - probe's own hard `future.get(5, SECONDS)` bound needs a DIFFERENT
    //   thread to wait on than the one it's issued from, or it deadlocks
    //   against itself -- and probe's OUTER dispatch is routed here too
    //   (not [executor]), so a probe started while a sync is mid-download
    //   isn't stuck in that same FIFO queue behind it.
    // - cancel/close only touch concurrent structures (the `cancelled` set,
    //   the `sessions` map) -- queuing them on [executor] behind an
    //   in-flight blocking download made the per-chunk `cancelled` check
    //   dead code, since cancel() could never actually run until the
    //   download it was meant to interrupt had already finished on its own.
    private val controlExecutor = Executors.newCachedThreadPool { r ->
        Thread(r, "smb-control").apply { isDaemon = true }
    }

    private val handler = Handler(Looper.getMainLooper())

    // One shared client for real (non-probe) sessions -- 30s protocol-level
    // timeouts are generous enough for a slow home NAS mid-transfer without
    // hanging a whole sync indefinitely on a truly dead connection. The
    // initial TCP connect itself is bounded separately and much tighter --
    // see [BoundedConnectSocketFactory].
    private val client = SMBClient(
        SmbConfig.builder()
            .withTimeout(SESSION_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .withSoTimeout(SESSION_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .withSocketFactory(BoundedConnectSocketFactory(CONNECT_TIMEOUT_MS))
            .build()
    )

    private val sessions = ConcurrentHashMap<Int, SmbSession>()
    private val nextHandle = AtomicInteger(1)

    // taskIds a Dart-side cancel() has flagged -- checked once per
    // downloadToFile chunk, and removed once THAT download's own
    // doDownloadToFile call finishes (success, failure, or cancellation).
    // NOTE: cancel() for a taskId that never starts a download (already
    // finished, or never existed) leaks its entry here forever -- this is
    // a real, if low-volume, leak (one short string per stray cancel), not
    // fixed here since it only matters at a call volume this app never
    // produces (cancel is a single user tap, not a hot path).
    private val cancelled = ConcurrentHashMap.newKeySet<String>()

    @Volatile private var progressSink: EventChannel.EventSink? = null

    init {
        registerHandlers(messenger)
    }

    /**
     * (Re-)registers this bridge's channel handlers against [messenger].
     * Safe to call more than once: [SmbBridge.attach] calls this on every
     * `configureFlutterEngine` -- which fires on every Activity recreation,
     * even though `AudioServiceActivity.provideFlutterEngine` returns the
     * SAME cached engine each time (Back is `moveTaskToBack`, not a real
     * finish, precisely so the engine and its foreground-service playback
     * survive). Re-registering the handlers on the (same, in practice)
     * messenger against THIS SAME instance is a harmless no-op past the
     * first call; what it replaces is the old bug where MainActivity called
     * the constructor directly, building a BRAND NEW SmbBridge each time
     * (fresh executors, fresh SMBClient, an EMPTY sessions map) -- leaking
     * the old instance's open sockets/threads while orphaning Dart's cached
     * handle, which pointed at the OLD instance's sessions map and would
     * fail with "no SMB session for handle N" forever after.
     */
    private fun registerHandlers(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(::handleCall)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    progressSink = events
                }

                override fun onCancel(arguments: Any?) {
                    progressSink = null
                }
            }
        )
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "connect" -> dispatch(result) { doConnect(call) }
            "probe" -> dispatch(result, controlExecutor) { doProbe(call) }
            "listTree" -> dispatch(result) { doListTree(call) }
            "listDir" -> dispatch(result) { doListDir(call) }
            "readFile" -> dispatch(result) { doReadFile(call) }
            "writeFile" -> dispatch(result) { doWriteFile(call) }
            "downloadToFile" -> dispatch(result) { doDownloadToFile(call) }
            "deleteRemote" -> dispatch(result) { doDeleteRemote(call) }
            "cancel" -> dispatch(result, controlExecutor) { doCancel(call) }
            "close" -> dispatch(result, controlExecutor) { doClose(call) }
            "freeSpace" -> dispatch(result) { doFreeSpace(call) }
            // Task: sync-survives-backgrounding. These three drive
            // SyncForegroundService directly on THIS (main) thread --
            // deliberately not routed through [dispatch]/[executor]: they
            // only ever build and send a Service Intent, never touch an SMB
            // session, and queuing a progress notification behind whatever
            // [executor] is currently blocked on (a chunked download) would
            // defeat the whole point of a live progress indicator.
            "syncFgStart" -> handleSyncForeground(result) {
                val label = call.argument<String>("label") ?: "Syncing"
                SyncForegroundService.start(appContext, label)
            }
            "syncFgUpdate" -> handleSyncForeground(result) {
                val label = call.argument<String>("label") ?: "Syncing"
                val done = call.argument<Int>("done") ?: -1
                val total = call.argument<Int>("total") ?: -1
                SyncForegroundService.update(appContext, label, done, total)
            }
            "syncFgStop" -> handleSyncForeground(result) {
                SyncForegroundService.stop(appContext)
            }
            else -> result.notImplemented()
        }
    }

    /** Runs [block] synchronously (see the dispatch comment above for why),
     * then always resolves [result] -- to null on success, since Dart's
     * SyncForegroundNotifier ignores the return value either way, or to an
     * error if building/sending the Intent itself threw. A notification is
     * a nicety: this exists so a failure here comes back as a normal
     * PlatformException for Dart's own swallow-everything error handling,
     * rather than an uncaught exception on the platform thread. */
    private inline fun handleSyncForeground(result: MethodChannel.Result, block: () -> Unit) {
        try {
            block()
            result.success(null)
        } catch (e: Exception) {
            result.error("smb", e.message ?: e.toString(), null)
        }
    }

    /** Runs [block] on [executor] (or [onExecutor], for probe/cancel/close --
     * see [controlExecutor]'s doc), then posts success/error back on the
     * main looper. */
    private fun <T> dispatch(
        result: MethodChannel.Result,
        onExecutor: ExecutorService = executor,
        block: () -> T,
    ) {
        onExecutor.execute {
            runCatching(block).fold(
                onSuccess = { value -> post { result.success(value) } },
                onFailure = { e -> post { result.error("smb", e.message ?: e.toString(), null) } },
            )
        }
    }

    private fun post(action: () -> Unit) {
        handler.post(action)
    }

    // --- connect / probe -----------------------------------------------

    private fun doConnect(call: MethodCall): Int {
        Log.i(TAG, "doConnect: entered")
        val host = call.argument<String>("host")
            ?: throw IllegalArgumentException("connect: host required")
        val shareName = call.argument<String>("share")
            ?: throw IllegalArgumentException("connect: share required")
        val basePath = call.argument<String>("basePath") ?: ""

        var connection: Connection? = null
        var session: Session? = null
        try {
            connection = client.connect(host)
            session = connection.authenticate(AuthenticationContext.guest())
            val share = session.connectShare(shareName) as DiskShare
            val handleId = nextHandle.getAndIncrement()
            sessions[handleId] = SmbSession(connection, session, share, basePath)
            return handleId
        } catch (e: Exception) {
            closeQuietly(session)
            closeQuietly(connection)
            throw e
        }
    }

    /**
     * Never throws -- any failure (bad args, unreachable host, auth
     * rejected, the base dir missing, a hang past [PROBE_TIMEOUT_SECONDS])
     * resolves to `false`. This whole method (not just [probeOnce]) runs on
     * [controlExecutor] (see [handleCall]'s dispatch), and additionally
     * submits [probeOnce] to that SAME pool under a hard `Future.get`
     * bound -- since [controlExecutor] is a cached (not single-thread)
     * pool, this nested submit-and-wait doesn't deadlock, and a host that
     * silently drops packets (rather than refusing the connection) can't
     * hang this past ~5s regardless of what SMBJ's own internal timeouts do
     * with it.
     */
    private fun doProbe(call: MethodCall): Boolean {
        Log.i(TAG, "doProbe: entered, args=${call.arguments}")
        return try {
            val host = call.argument<String>("host") ?: return false
            val shareName = call.argument<String>("share") ?: return false
            val basePath = call.argument<String>("basePath") ?: ""
            val future = controlExecutor.submit(Callable { probeOnce(host, shareName, basePath) })
            try {
                future.get(PROBE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            } catch (e: java.util.concurrent.TimeoutException) {
                Log.w(TAG, "doProbe: outer probe bound expired")
                future.cancel(true)
                false
            } catch (e: InterruptedException) {
                // This thread was asked to interrupt -- swallowing the
                // exception without restoring the flag would hide that
                // request from anything else checking Thread.interrupted()
                // later (e.g. the executor's own shutdown machinery).
                Thread.currentThread().interrupt()
                future.cancel(true)
                false
            } catch (e: Exception) {
                future.cancel(true)
                false
            }
        } catch (e: Exception) {
            false
        }
    }

    private fun probeOnce(host: String, shareName: String, basePath: String): Boolean {
        val probeConfig = SmbConfig.builder()
            .withTimeout(PROBE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .withSoTimeout(PROBE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .withSocketFactory(BoundedConnectSocketFactory(CONNECT_TIMEOUT_MS))
            .build()
        Log.i(TAG, "probeOnce: host=$host share=$shareName base='$basePath'")
        // Cleanup failures must NEVER veto the answer: on a live Samba the
        // explicit session close races the connection close's own logoff,
        // and the second logoff comes back STATUS_USER_SESSION_DELETED --
        // thrown from close(), AFTER folderExists already succeeded. With
        // the closes inside the try (the old .use{} chains), that harmless
        // teardown race read as "NAS unreachable" -- release builds hit it
        // deterministically on real hardware (R8-fast teardown), debug and
        // the emulator's NAT latency happened to dodge it. Compute the
        // answer first; close everything quietly afterwards.
        var client: SMBClient? = null
        var connection: com.hierynomus.smbj.connection.Connection? = null
        var session: com.hierynomus.smbj.session.Session? = null
        var share: DiskShare? = null
        return try {
            client = SMBClient(probeConfig)
            connection = client.connect(host)
            session = connection.authenticate(AuthenticationContext.guest())
            share = session.connectShare(shareName) as DiskShare
            val exists = share.folderExists(toSmbPath(basePath))
            Log.i(TAG, "probeOnce: folderExists = " + exists)
            exists
        } catch (e: Exception) {
            Log.w(TAG, "probeOnce failed: ${e.javaClass.simpleName}: ${e.message}", e)
            false
        } finally {
            closeQuietly(share)
            closeQuietly(session)
            try { connection?.close() } catch (_: Exception) {}
            try { client?.close() } catch (_: Exception) {}
        }
    }

    // --- listTree ---------------------------------------------------------

    private fun doListTree(call: MethodCall): List<Map<String, Any>> {
        Log.i(TAG, "doListTree: entered")
        val handleId = call.argument<Int>("handle")
            ?: throw IllegalArgumentException("listTree: handle required")
        val relDir = call.argument<String>("relDir") ?: ""
        val s = sessionFor(handleId)
        val startPath = joinBase(s.basePath, relDir)
        // Only the TOP-LEVEL requested dir missing is "empty, not an
        // error" -- matches LocalDirTransport and every other SyncTransport
        // implementation. Anything that goes wrong walking its children
        // (including the connection dropping mid-walk) is left to throw
        // out of walkDir below, uncaught.
        if (!s.share.folderExists(startPath)) return emptyList()
        val out = mutableListOf<Map<String, Any>>()
        walkDir(s.share, startPath, s.basePath, out)
        return out
    }

    /// Immediate child DIRECTORY names of [relDir] -- one SMB query, no
    /// recursion. Root discovery uses this instead of walking the whole
    /// share (a ~15k-file walk over Wi-Fi took minutes; five folder names
    /// need one round trip). Missing dir -> empty, same as listTree.
    private fun doListDir(call: MethodCall): List<String> {
        val handleId = call.argument<Int>("handle")
            ?: throw IllegalArgumentException("listDir: handle required")
        val relDir = call.argument<String>("relDir") ?: ""
        val s = sessionFor(handleId)
        val startPath = joinBase(s.basePath, relDir)
        if (!s.share.folderExists(startPath)) return emptyList()
        val out = mutableListOf<String>()
        for (info in s.share.list(startPath)) {
            val name = info.fileName
            if (name == "." || name == "..") continue
            val isDir = (info.fileAttributes and FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value) != 0L
            if (isDir) out.add(name)
        }
        return out.sorted()
    }

    private fun walkDir(
        share: DiskShare,
        path: String,
        basePath: String,
        out: MutableList<Map<String, Any>>,
    ) {
        for (info in share.list(path)) {
            val name = info.fileName
            if (name == "." || name == "..") continue
            val childPath = if (path.isEmpty()) name else "$path\\$name"
            val isDir = (info.fileAttributes and FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value) != 0L
            if (isDir) {
                walkDir(share, childPath, basePath, out)
            } else {
                out.add(
                    mapOf(
                        "relPath" to relativeToBase(basePath, childPath),
                        "size" to info.endOfFile,
                        "mtimeMs" to info.lastWriteTime.toEpochMillis(),
                    )
                )
            }
        }
    }

    // --- readFile / writeFile / deleteRemote -------------------------------

    private fun doReadFile(call: MethodCall): ByteArray? {
        val handleId = call.argument<Int>("handle")
            ?: throw IllegalArgumentException("readFile: handle required")
        val relPath = call.argument<String>("relPath")
            ?: throw IllegalArgumentException("readFile: relPath required")
        val s = sessionFor(handleId)
        val path = joinBase(s.basePath, relPath)
        return try {
            s.share.openFile(
                path,
                setOf(AccessMask.GENERIC_READ),
                null,
                SMB2ShareAccess.ALL,
                SMB2CreateDisposition.FILE_OPEN,
                null,
            ).use { file -> file.inputStream.use { it.readBytes() } }
        } catch (e: SMBApiException) {
            if (isNotFound(e)) null else throw e
        }
    }

    private fun doWriteFile(call: MethodCall): Any? {
        val handleId = call.argument<Int>("handle")
            ?: throw IllegalArgumentException("writeFile: handle required")
        val relPath = call.argument<String>("relPath")
            ?: throw IllegalArgumentException("writeFile: relPath required")
        val bytes = call.argument<ByteArray>("bytes")
            ?: throw IllegalArgumentException("writeFile: bytes required")
        val s = sessionFor(handleId)
        val target = joinBase(s.basePath, relPath)
        val tmp = "$target.tmp"
        val parent = parentOf(target)
        if (parent.isNotEmpty()) ensureDirsExist(s.share, parent)

        // Write the scratch file, then rename over the real target on the
        // SAME handle -- replaceIfExists=true requires the handle to have
        // been opened with DELETE access (MS-FSCC 2.4.35); FILE_WRITE_DATA
        // (via GENERIC_WRITE) covers the write itself.
        s.share.openFile(
            tmp,
            setOf(AccessMask.GENERIC_WRITE, AccessMask.DELETE, AccessMask.FILE_WRITE_ATTRIBUTES),
            null,
            SMB2ShareAccess.ALL,
            SMB2CreateDisposition.FILE_OVERWRITE_IF,
            null,
        ).use { file ->
            if (bytes.isNotEmpty()) file.write(bytes, 0)
            file.rename(target, true)
        }
        return null
    }

    private fun doDeleteRemote(call: MethodCall): Any? {
        val handleId = call.argument<Int>("handle")
            ?: throw IllegalArgumentException("deleteRemote: handle required")
        val relPath = call.argument<String>("relPath")
            ?: throw IllegalArgumentException("deleteRemote: relPath required")
        val s = sessionFor(handleId)
        val path = joinBase(s.basePath, relPath)
        try {
            s.share.rm(path)
        } catch (e: SMBApiException) {
            if (!isNotFound(e)) throw e // already gone -- idempotent no-op
        }
        return null
    }

    // --- downloadToFile -----------------------------------------------------

    private fun doDownloadToFile(call: MethodCall): Boolean {
        val handleId = call.argument<Int>("handle")
            ?: throw IllegalArgumentException("downloadToFile: handle required")
        val relPath = call.argument<String>("relPath")
            ?: throw IllegalArgumentException("downloadToFile: relPath required")
        val localPath = call.argument<String>("localPath")
            ?: throw IllegalArgumentException("downloadToFile: localPath required")
        val taskId = call.argument<String>("taskId")
            ?: throw IllegalArgumentException("downloadToFile: taskId required")
        val s = sessionFor(handleId)
        val remotePath = joinBase(s.basePath, relPath)

        val localFile = File(localPath)
        localFile.parentFile?.mkdirs()
        val partFile = File("$localPath.part")

        try {
            s.share.openFile(
                remotePath,
                setOf(AccessMask.GENERIC_READ),
                null,
                SMB2ShareAccess.ALL,
                SMB2CreateDisposition.FILE_OPEN,
                null,
            ).use { remoteFile ->
                // File.getLength() doesn't exist in 0.13.0 (it's a later
                // addition) -- go through FileStandardInformation instead.
                val total = remoteFile
                    .getFileInformation(FileStandardInformation::class.java)
                    .endOfFile
                remoteFile.inputStream.use { input ->
                    FileOutputStream(partFile).use { output ->
                        val buffer = ByteArray(DOWNLOAD_BUFFER_SIZE)
                        var got = 0L
                        var sinceProgress = 0L
                        while (true) {
                            if (cancelled.contains(taskId)) {
                                throw IOException("download cancelled: $taskId")
                            }
                            val n = input.read(buffer)
                            if (n < 0) break
                            output.write(buffer, 0, n)
                            got += n
                            sinceProgress += n
                            if (sinceProgress >= PROGRESS_STEP_BYTES) {
                                postProgress(taskId, got, total)
                                sinceProgress = 0
                            }
                        }
                        output.flush()
                        // Final call is ALWAYS (total, total) -- UNCONDITIONALLY,
                        // not the actual `got` count. If the remote file shrinks
                        // mid-read, `got` could end up permanently short of
                        // `total`, which would never satisfy the Dart side's
                        // self-cleanup check (got >= total) -- reporting the
                        // nominal total here keeps the "final call is always
                        // got == total" contract exact regardless.
                        postProgress(taskId, total, total)
                    }
                }
            }
        } catch (e: Exception) {
            runCatching { if (partFile.exists()) partFile.delete() }
            throw e
        } finally {
            cancelled.remove(taskId)
        }

        if (localFile.exists()) localFile.delete()
        if (!partFile.renameTo(localFile)) {
            runCatching { partFile.delete() }
            throw IOException("failed to move downloaded file into place: $localPath")
        }
        return true
    }

    private fun postProgress(taskId: String, got: Long, total: Long) {
        val sink = progressSink ?: return
        val event = mapOf("taskId" to taskId, "got" to got, "total" to total)
        handler.post { sink.success(event) }
    }

    // --- cancel / close / freeSpace -----------------------------------------

    private fun doCancel(call: MethodCall): Any? {
        val taskId = call.argument<String>("taskId") ?: return null
        cancelled.add(taskId)
        return null
    }

    private fun doClose(call: MethodCall): Any? {
        val handleId = call.argument<Int>("handle") ?: return null
        sessions.remove(handleId)?.close()
        return null
    }

    /**
     * [localPath] often doesn't exist yet (first sync into a brand-new
     * root directory) -- StatFs needs a path that's actually there, so walk
     * up to the nearest existing parent before asking.
     */
    private fun doFreeSpace(call: MethodCall): Long {
        val localPath = call.argument<String>("localPath")
            ?: throw IllegalArgumentException("freeSpace: localPath required")
        var f = File(localPath)
        while (!f.exists()) {
            f = f.parentFile ?: break
        }
        return StatFs(f.path).availableBytes
    }

    // --- helpers -------------------------------------------------------

    private fun sessionFor(handleId: Int): SmbSession =
        sessions[handleId] ?: throw IllegalStateException("no SMB session for handle $handleId")

    private fun isNotFound(e: SMBApiException): Boolean {
        val status = e.status
        return status == NtStatus.STATUS_OBJECT_NAME_NOT_FOUND ||
            status == NtStatus.STATUS_OBJECT_PATH_NOT_FOUND
    }

    private fun closeQuietly(c: AutoCloseable?) {
        if (c == null) return
        runCatching { c.close() }
    }

    /** Every SMBJ call in this file uses backslash paths -- SmbPath (used
     * internally by open/list/mkdir/exists) normalizes '/' to '\' for us,
     * but FileRenameInformation's target name does NOT go through SmbPath
     * (see DiskEntry.rename), so converting up front, once, keeps every
     * call site consistent regardless of which SMBJ codepath it hits. */
    private fun toSmbPath(path: String): String = path.replace('/', '\\').trim('\\')

    private fun joinBase(basePath: String, rest: String): String {
        val b = toSmbPath(basePath)
        val r = toSmbPath(rest)
        return when {
            b.isEmpty() -> r
            r.isEmpty() -> b
            else -> "$b\\$r"
        }
    }

    private fun parentOf(path: String): String {
        val idx = path.lastIndexOf('\\')
        return if (idx < 0) "" else path.substring(0, idx)
    }

    /** Inverse of [joinBase]: strips [basePath] off a full share-relative
     * path and converts back to forward slashes -- the wire format
     * SyncTransport.listTree promises Dart. */
    private fun relativeToBase(basePath: String, fullPath: String): String {
        val b = toSmbPath(basePath)
        val rel = if (b.isEmpty()) fullPath else fullPath.removePrefix("$b\\")
        return rel.replace('\\', '/')
    }

    /** Creates every path segment of [dirPath] that doesn't already exist.
     * Not a single recursive mkdir -- SMBJ's mkdir() only creates one
     * level, and FILE_CREATE on an existing directory throws, so each
     * level is existence-checked first (with a check-again-on-race fallback
     * for the case another writer created it between the check and the
     * mkdir call). */
    private fun ensureDirsExist(share: DiskShare, dirPath: String) {
        if (dirPath.isEmpty()) return
        var current = ""
        for (seg in dirPath.split("\\")) {
            if (seg.isEmpty()) continue
            current = if (current.isEmpty()) seg else "$current\\$seg"
            if (!share.folderExists(current)) {
                try {
                    share.mkdir(current)
                } catch (e: SMBApiException) {
                    if (!share.folderExists(current)) throw e
                }
            }
        }
    }

    /** One connected share, keyed by the Dart-visible `handle` int. */
    private class SmbSession(
        val connection: Connection,
        val session: Session,
        val share: DiskShare,
        val basePath: String,
    ) {
        fun close() {
            runCatching { share.close() }
            runCatching { session.close() }
            runCatching { connection.close() }
        }
    }

    /**
     * SMBJ's `DirectTcpTransport.connect()` calls
     * `SocketFactory.createSocket(host, port)` -- the plain, UNBOUNDED
     * overload (verified against the actual resolved 0.13.0 jar's
     * bytecode, not just the newer `master` source: SMBJ's own default
     * `SmbConfig.builder()` chain already installs its `ProxySocketFactory`,
     * which happens to bound this same call to 5s internally -- so this
     * class doesn't close a live gap so much as make that bound explicit
     * and OWNED by this file, rather than resting on an unstated library
     * default that a future SMBJ version could change).
     * `Socket(host, port)` has no timeout parameter at all; the only way to
     * bound a TCP connect in java.net is the unconnected-socket-then-
     * `connect(SocketAddress, timeoutMs)` two-step this class does.
     */
    private class BoundedConnectSocketFactory(private val timeoutMs: Int) : SocketFactory() {
        override fun createSocket(): Socket = Socket()

        override fun createSocket(host: String, port: Int): Socket =
            Socket().apply { connect(InetSocketAddress(host, port), timeoutMs) }

        override fun createSocket(
            host: String,
            port: Int,
            localAddress: InetAddress,
            localPort: Int,
        ): Socket = Socket().apply {
            bind(InetSocketAddress(localAddress, localPort))
            connect(InetSocketAddress(host, port), timeoutMs)
        }

        override fun createSocket(address: InetAddress, port: Int): Socket =
            Socket().apply { connect(InetSocketAddress(address, port), timeoutMs) }

        override fun createSocket(
            address: InetAddress,
            port: Int,
            localAddress: InetAddress,
            localPort: Int,
        ): Socket = Socket().apply {
            bind(InetSocketAddress(localAddress, localPort))
            connect(InetSocketAddress(address, port), timeoutMs)
        }
    }

    companion object {
        @Volatile private var instance: SmbBridge? = null

        /**
         * The one SmbBridge for this process (review round 1, Critical
         * C-1). MainActivity calls this -- never the private constructor --
         * from `configureFlutterEngine`, which fires on every Activity
         * recreation even though the underlying engine (and its messenger)
         * is cached and reused across them. The first call constructs the
         * real instance; every call after that just re-points the SAME
         * instance's channel handlers at [messenger] (see
         * [registerHandlers]'s doc), so sessions/executors/the SMBClient
         * all survive recreation exactly like the engine itself already
         * does, instead of a fresh (and instantly orphaned) SmbBridge being
         * built each time.
         *
         * [context] (added for SyncForegroundService, task
         * sync-survives-backgrounding) is only ever read for its
         * `applicationContext` at construction time -- re-passing it on a
         * later, idempotent call is harmless (same process, same
         * application context) and simply isn't used past the first call.
         */
        @Synchronized
        fun attach(messenger: BinaryMessenger, context: Context): SmbBridge {
            val existing = instance
            if (existing != null) {
                existing.registerHandlers(messenger)
                return existing
            }
            val created = SmbBridge(messenger, context)
            instance = created
            return created
        }

        private const val METHOD_CHANNEL = "dev.mklod.fooplayer/smb"
        private const val EVENT_CHANNEL = "dev.mklod.fooplayer/smb-progress"
        private const val TAG = "fooplayer.smb"
        private const val PROBE_TIMEOUT_SECONDS = 5L
        private const val SESSION_TIMEOUT_SECONDS = 30L
        private const val CONNECT_TIMEOUT_MS = 5000
        private const val DOWNLOAD_BUFFER_SIZE = 65536
        private const val PROGRESS_STEP_BYTES = 256L * 1024L
    }
}

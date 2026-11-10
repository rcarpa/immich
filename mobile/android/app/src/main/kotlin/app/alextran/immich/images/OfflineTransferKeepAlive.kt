package app.alextran.immich.images

import android.Manifest
import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import app.alextran.immich.R

/**
 * immich-sync fork: keeps the process running while the offline store downloads, so leaving the app does not stop
 * them. What Android offers for exactly this:
 *
 * - Android 14 and later: a user-initiated data transfer job ([OfflineTransferJobService]). The system runs it for as
 *   long as the transfer needs, shows it in the task manager, and lets the user stop it there;
 * - earlier: a `dataSync` foreground service ([OfflineTransferService]).
 *
 * Both can only be started while the app is on screen, so the work is announced early: Dart renews a lease while its
 * queue has files, and the process is kept while the lease holds or a native transfer runs. A Dart side that dies
 * lets the lease lapse after [LEASE_MS], so nothing is held for ever.
 */
object OfflineTransferKeepAlive {
  private const val TAG = "OfflineKeepAlive"
  private const val LEASE_MS = 90_000L
  /**
   * "MIRR". WorkManager, which shares the app's JobScheduler ids, numbers its jobs upwards from 0, so it does not
   * reach this.
   */
  private const val JOB_ID = 0x4D495252
  const val NOTIFICATION_ID = 0x4D495252
  private const val CHANNEL_ID = "mirrich_offline_transfers"

  private val main by lazy { Handler(Looper.getMainLooper()) }
  private val lock = Any()

  private var context: Context? = null
  private var leaseUntil = 0L
  private var pendingHint = 0
  private var wifiOnly = false

  /** The user stopped the transfer from the task manager. Honoured until the app is on screen again. */
  private var stoppedByUser = false

  /** Started, or scheduled to start, and not yet stopped. */
  private var active = false
  private var shownCount = -1

  @Volatile
  internal var job: OfflineTransferJobService? = null

  @Volatile
  internal var jobParams: JobParameters? = null

  private val recheck = Runnable { evaluate() }

  fun prepare(context: Context) {
    synchronized(lock) {
      if (this.context != null) return
      this.context = context.applicationContext
    }
    createChannel(context.applicationContext)
  }

  /** Dart's queue has [pending] files. Returns whether the process is kept running in the background. */
  fun renew(pending: Int, wifiOnly: Boolean): Boolean {
    synchronized(lock) {
      if (isAppVisible()) stoppedByUser = false
      this.wifiOnly = wifiOnly
      pendingHint = pending
      leaseUntil = if (pending > 0) SystemClock.elapsedRealtime() + LEASE_MS else 0L
    }
    return evaluate()
  }

  /**
   * Starts or stops keeping the process, as the lease and the running transfers say. From any thread; the decision and
   * the start or stop it leads to run together on the main thread, so a stop decided earlier can never land after a
   * later start and cancel it.
   */
  fun evaluate(): Boolean {
    if (Looper.myLooper() != Looper.getMainLooper()) {
      main.post { evaluateOnMain() }
      return synchronized(lock) { active }
    }
    return evaluateOnMain()
  }

  private fun evaluateOnMain(): Boolean {
    val context = synchronized(lock) { context } ?: return false
    val now = SystemClock.elapsedRealtime()
    val transfers = OfflineDownloader.activeCount()
    val (wanted, start, stop, count) = synchronized(lock) {
      val leased = now < leaseUntil && pendingHint > 0
      val wanted = !stoppedByUser && (transfers > 0 || leased)
      val start = wanted && !active
      val stop = !wanted && active
      if (start) active = true
      if (stop) active = false
      Quad(wanted, start, stop, maxOf(transfers, if (leased) pendingHint else 0))
    }

    main.removeCallbacks(recheck)
    if (wanted) main.postDelayed(recheck, LEASE_MS)

    if (start) {
      val started = try {
        start(context)
      } catch (e: Exception) {
        // Typically: the app is no longer on screen, which both mechanisms require.
        Log.w(TAG, "Could not keep downloads running in the background: $e")
        false
      }
      if (!started) synchronized(lock) { active = false }
      return started
    }
    if (stop) {
      stop(context)
      return false
    }
    if (wanted) updateNotification(context, count)
    return synchronized(lock) { active }
  }

  private data class Quad(val wanted: Boolean, val start: Boolean, val stop: Boolean, val count: Int)

  private fun start(context: Context): Boolean {
    shownCount = -1
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      scheduleJob(context)
    } else {
      ContextCompat.startForegroundService(context, Intent(context, OfflineTransferService::class.java))
      true
    }
  }

  @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
  private fun scheduleJob(context: Context): Boolean {
    val scheduler = context.getSystemService(JobScheduler::class.java) ?: return false
    if (!scheduler.canRunUserInitiatedJobs()) return false
    val info = JobInfo.Builder(JOB_ID, ComponentName(context, OfflineTransferJobService::class.java))
      .setUserInitiated(true)
      // Wi-Fi only maps to unmetered, the closest the scheduler has. The downloader checks for Wi-Fi itself.
      .setRequiredNetworkType(
        if (synchronized(lock) { wifiOnly }) JobInfo.NETWORK_TYPE_UNMETERED else JobInfo.NETWORK_TYPE_ANY
      )
      .build()
    return scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS
  }

  private fun stop(context: Context) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      val service = job
      val params = jobParams
      if (service != null && params != null) {
        jobParams = null
        job = null
        service.jobFinished(params, false)
      } else {
        context.getSystemService(JobScheduler::class.java)?.cancel(JOB_ID)
      }
    } else {
      context.stopService(Intent(context, OfflineTransferService::class.java))
    }
  }

  /** The job started. It may no longer be wanted, if the work finished while it waited for a network. */
  internal fun onJobStarted(service: OfflineTransferJobService, params: JobParameters) {
    job = service
    jobParams = params
    // Running, whatever was thought; evaluating then finishes it if nothing is left to do. Not scheduled again, which
    // would replace the running job.
    synchronized(lock) { active = true }
    evaluate()
  }

  /** The system stopped the job or service. A user's stop also stops the downloads; anything else leaves them be. */
  internal fun onStopped(byUser: Boolean) {
    job = null
    jobParams = null
    synchronized(lock) {
      active = false
      if (byUser) stoppedByUser = true
    }
    if (byUser) {
      Log.i(TAG, "Stopped by the user")
      OfflineDownloader.cancelAll()
    }
  }

  private fun isAppVisible(): Boolean {
    val state = ActivityManager.RunningAppProcessInfo()
    ActivityManager.getMyMemoryState(state)
    // Strictly on screen: a process holding a foreground service ranks just below this.
    return state.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
  }

  // Notification.

  private fun createChannel(context: Context) {
    val manager = context.getSystemService(NotificationManager::class.java) ?: return
    if (manager.getNotificationChannel(CHANNEL_ID) != null) return
    val channel = NotificationChannel(CHANNEL_ID, "Offline copies", NotificationManager.IMPORTANCE_LOW).apply {
      description = "Shown while offline copies download in the background"
      setShowBadge(false)
    }
    manager.createNotificationChannel(channel)
  }

  internal fun notification(context: Context, count: Int = currentCount()): Notification {
    val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
    val content = launch?.let {
      PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }
    return NotificationCompat.Builder(context, CHANNEL_ID)
      .setSmallIcon(R.drawable.notification_icon)
      .setContentTitle("Saving offline copies")
      .setContentText(if (count > 0) "$count file${if (count == 1) "" else "s"} to go" else "Finishing")
      .setProgress(0, 0, true)
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .setSilent(true)
      .setCategory(NotificationCompat.CATEGORY_PROGRESS)
      .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
      .setContentIntent(content)
      .build()
  }

  private fun currentCount(): Int {
    val transfers = OfflineDownloader.activeCount()
    val leased = synchronized(lock) { if (SystemClock.elapsedRealtime() < leaseUntil) pendingHint else 0 }
    return maxOf(transfers, leased)
  }

  @SuppressLint("MissingPermission")
  private fun updateNotification(context: Context, count: Int) {
    // Only on a change in tens, or a running count would post an update per file.
    val bucket = if (count < 10) count else count / 10 * 10
    if (bucket == shownCount) return
    if (job == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
      ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
      PackageManager.PERMISSION_GRANTED
    ) return
    shownCount = bucket
    context.getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, notification(context, count))
  }
}

/**
 * immich-sync fork: the Android 14+ half of [OfflineTransferKeepAlive]. The downloads run in [OfflineDownloader]. Only
 * ever scheduled on Android 14+, where user-initiated jobs exist.
 */
@SuppressLint("SpecifyJobSchedulerIdRange")
class OfflineTransferJobService : JobService() {
  override fun onStartJob(params: JobParameters): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false
    // Required within seconds of starting, or the system stops the job.
    setNotification(
      params,
      OfflineTransferKeepAlive.NOTIFICATION_ID,
      OfflineTransferKeepAlive.notification(this),
      JOB_END_NOTIFICATION_POLICY_REMOVE,
    )
    OfflineTransferKeepAlive.onJobStarted(this, params)
    return true
  }

  override fun onStopJob(params: JobParameters): Boolean {
    val byUser = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
      params.stopReason == JobParameters.STOP_REASON_USER
    OfflineTransferKeepAlive.onStopped(byUser = byUser)
    // Not rescheduled: Dart starts it again when there is work and the app is on screen.
    return false
  }
}

/** immich-sync fork: the pre-Android 14 half of [OfflineTransferKeepAlive]. */
class OfflineTransferService : Service() {
  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    try {
      ServiceCompat.startForeground(
        this,
        OfflineTransferKeepAlive.NOTIFICATION_ID,
        OfflineTransferKeepAlive.notification(this),
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
      )
    } catch (e: Exception) {
      Log.w("OfflineKeepAlive", "Could not start the foreground service: $e")
      OfflineTransferKeepAlive.onStopped(byUser = false)
      stopSelf()
    }
    // Not restarted after the process dies: the Dart queue starts it again when it has work.
    return START_NOT_STICKY
  }
}

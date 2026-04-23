package com.bluetomis.fieldreport

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import dji.sdk.keyvalue.key.BatteryKey
import dji.sdk.keyvalue.key.FlightControllerKey
import dji.sdk.keyvalue.key.ProductKey
import dji.v5.manager.SDKManager
import dji.v5.manager.interfaces.SDKManagerCallback
import dji.v5.common.error.IDJIError
import dji.v5.common.register.DJISDKInitEvent
import dji.v5.manager.KeyManager
import kotlinx.coroutines.*
import org.eclipse.paho.client.mqttv3.*
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence
import org.json.JSONObject
import java.util.UUID
import kotlin.math.sqrt

class TelemetryService : Service() {

    companion object {
        private const val NOTIF_ID    = 1001
        private const val MQTT_BROKER = "ssl://fieldreport-mqtt.fly.dev:8883"
        private const val TOPIC_ROOT  = "thing/product"
        const val ACTION_STOP = "com.bluetomis.fieldreport.STOP"
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // Live telemetry state — written by DJI key listeners
    @Volatile private var lat: Double  = 0.0
    @Volatile private var lon: Double  = 0.0
    @Volatile private var alt: Double  = 0.0
    @Volatile private var speedH: Double = 0.0
    @Volatile private var speedV: Double = 0.0
    @Volatile private var motorsOn: Boolean = false
    @Volatile private var inSky: Boolean = false
    @Volatile private var pitch: Double = 0.0
    @Volatile private var roll: Double  = 0.0
    @Volatile private var heading: Double = 0.0
    @Volatile private var battery: Int  = 0
    @Volatile private var droneSn: String = "UNKNOWN"

    private var mqtt: MqttClient? = null
    private var frameCount = 0L

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { stopSelf(); return START_NOT_STICKY }
        startForeground(NOTIF_ID, buildNotification("Initialising DJI SDK…"))
        initDJI()
        return START_STICKY   // OS will restart service if killed
    }

    override fun onDestroy() {
        scope.cancel()
        runCatching { KeyManager.getInstance()?.cancelListenByOwner(this) }
        runCatching { mqtt?.disconnect() }
        super.onDestroy()
    }

    // ── DJI SDK ───────────────────────────────────────────────────────────────

    private fun initDJI() {
        SDKManager.getInstance().init(applicationContext, object : SDKManagerCallback {
            override fun onRegisterSuccess() {
                updateNotif("DJI SDK registered — waiting for aircraft")
                subscribeKeys()
                scope.launch { connectMqtt() }
            }
            override fun onRegisterFailure(error: IDJIError?) {
                updateNotif("SDK error: ${error?.description() ?: "unknown"} — retrying in 10 s")
                scope.launch {
                    delay(10_000)
                    initDJI()
                }
            }
            override fun onProductConnect(product: dji.v5.common.model.BaseProduct?) {
                droneSn = runCatching {
                    KeyManager.getInstance()
                        ?.getValue(ProductKey.KeySerialNumber) as? String ?: "UNKNOWN"
                }.getOrDefault("UNKNOWN")
                updateNotif("Aircraft connected: $droneSn")
            }
            override fun onProductDisconnect(product: dji.v5.common.model.BaseProduct?) {
                updateNotif("Aircraft disconnected — waiting…")
            }
            override fun onProductChanged(product: dji.v5.common.model.BaseProduct?) {}
            override fun onInitProcess(event: DJISDKInitEvent?, totalProcess: Int) {}
            override fun onDatabaseDownloadProgress(current: Long, total: Long) {}
        })
    }

    private fun subscribeKeys() {
        val km = KeyManager.getInstance() ?: return

        // Location — primary publish trigger
        km.listen(FlightControllerKey.KeyAircraftLocation3D, this) { _, v ->
            v ?: return@listen
            lat = v.latitude; lon = v.longitude; alt = v.altitude
            publishOSD()
        }

        km.listen(FlightControllerKey.KeyAreMotorsOn, this)   { _, v -> motorsOn = v ?: false }
        km.listen(FlightControllerKey.KeyIsFlying, this)      { _, v -> inSky    = v ?: false }

        km.listen(FlightControllerKey.KeyAircraftAttitude, this) { _, v ->
            v ?: return@listen
            pitch = v.pitch; roll = v.roll; heading = v.yaw
        }

        km.listen(FlightControllerKey.KeyAircraftVelocity, this) { _, v ->
            v ?: return@listen
            speedH = sqrt(v.x * v.x + v.y * v.y)
            speedV = -v.z  // DJI z is positive-down; convert to positive-up
        }

        km.listen(BatteryKey.KeyChargeRemainingInPercent, this) { _, v ->
            battery = v ?: 0
        }
    }

    // ── MQTT ──────────────────────────────────────────────────────────────────

    private suspend fun connectMqtt() {
        while (isActive) {
            try {
                val clientId = "fr-agent-${UUID.randomUUID()}"
                val client = MqttClient(MQTT_BROKER, clientId, MemoryPersistence())
                val opts = MqttConnectOptions().apply {
                    isCleanSession     = true
                    connectionTimeout  = 30
                    keepAliveInterval  = 60
                    isAutomaticReconnect = true
                }
                withContext(Dispatchers.IO) { client.connect(opts) }
                mqtt = client
                updateNotif("MQTT connected — publishing to $MQTT_BROKER")
                return  // connected; auto-reconnect handles future drops
            } catch (e: Exception) {
                updateNotif("MQTT error: ${e.message} — retry in 5 s")
                delay(5_000)
            }
        }
    }

    private fun publishOSD() {
        val client = mqtt ?: return
        if (!client.isConnected) return

        val data = JSONObject().apply {
            put("latitude",       lat)
            put("longitude",      lon)
            put("height",         alt)
            put("horizontal_speed", speedH)
            put("vertical_speed", speedV)
            put("attitude_pitch", pitch)
            put("attitude_roll",  roll)
            put("attitude_head",  heading)
            put("motors_on",      motorsOn)
            put("in_the_sky",     inSky)
            put("battery", JSONObject().apply {
                put("capacity_percent", battery)
            })
        }
        val envelope = JSONObject().apply {
            put("tid",       UUID.randomUUID().toString().replace("-","").take(8))
            put("bid",       UUID.randomUUID().toString().replace("-","").take(8))
            put("timestamp", System.currentTimeMillis())
            put("data",      data)
        }

        runCatching {
            val topic = "$TOPIC_ROOT/$droneSn/osd"
            client.publish(topic, MqttMessage(envelope.toString().toByteArray()).apply { qos = 0 })
            frameCount++
            if (frameCount % 10 == 0L) updateNotif("Live · $droneSn · $frameCount frames")
        }
    }

    // ── Notification ──────────────────────────────────────────────────────────

    private fun buildNotification(text: String): Notification {
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, TelemetryService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val openIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, App.CHANNEL_ID)
            .setContentTitle("FieldReport Agent")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setOngoing(true)
            .setContentIntent(openIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopIntent)
            .build()
    }

    private fun updateNotif(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIF_ID, buildNotification(text))
    }
}

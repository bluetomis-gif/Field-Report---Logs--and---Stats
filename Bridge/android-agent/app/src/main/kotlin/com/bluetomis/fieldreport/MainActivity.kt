package com.bluetomis.fieldreport

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Simple programmatic layout — no XML needed
        val root = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(48, 80, 48, 48)
        }

        val title = TextView(this).apply {
            text = "FieldReport Agent"
            textSize = 24f
            setTypeface(null, android.graphics.Typeface.BOLD)
            setPadding(0, 0, 0, 8)
        }

        val subtitle = TextView(this).apply {
            text = "Publishes DJI drone telemetry to your MQTT broker.\n" +
                   "Runs as a background service — auto-starts on boot."
            textSize = 14f
            setPadding(0, 0, 0, 32)
        }

        val broker = TextView(this).apply {
            text = "Broker: fieldreport-mqtt.fly.dev:8883\nTopic:  thing/product/{SN}/osd"
            textSize = 12f
            setTypeface(null, android.graphics.Typeface.MONOSPACE)
            setPadding(0, 0, 0, 32)
        }

        val startBtn = Button(this).apply {
            text = "Start Service"
            setOnClickListener { startTelemetryService() }
        }

        val stopBtn = Button(this).apply {
            text = "Stop Service"
            setOnClickListener {
                startService(
                    Intent(context, TelemetryService::class.java)
                        .apply { action = TelemetryService.ACTION_STOP }
                )
            }
        }

        root.addView(title)
        root.addView(subtitle)
        root.addView(broker)
        root.addView(startBtn)
        root.addView(stopBtn)
        setContentView(root)

        // Auto-start on first open
        startTelemetryService()
    }

    private fun startTelemetryService() {
        val intent = Intent(this, TelemetryService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}

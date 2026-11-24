package com.agile.app.jao

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

class PdfInvoiceOverlayActivity : FlutterActivity() {
    companion object {
        private const val OVERLAY_CHANNEL = "com.agile.app.jao/invoice_overlay"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val requestCounter = AtomicLong(0L)
    private var storageHandler: PdfStorageChannelHandler? = null
    private var overlayChannel: MethodChannel? = null
    private var extractedPayload: String? = null
    private var extractionError: String? = null
    private var extractionComplete = false
    private var pendingPayloadResult: MethodChannel.Result? = null
    private var dartReady = false

    override fun getDartEntrypointFunctionName(): String = "invoiceOverlayMain"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode {
        return FlutterActivityLaunchConfigs.BackgroundMode.transparent
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        processIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        processIncomingIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        storageHandler = PdfStorageChannelHandler(this).also { it.register(flutterEngine) }

        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OVERLAY_CHANNEL)
        overlayChannel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingPayload" -> {
                    dartReady = true
                    if (extractionComplete) {
                        result.success(
                            mapOf(
                                "payload" to extractedPayload,
                                "error" to extractionError,
                            ),
                        )
                    } else {
                        pendingPayloadResult = result
                    }
                }
                "closeOverlay" -> {
                    finish()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        overlayChannel?.setMethodCallHandler(null)
        overlayChannel = null
        storageHandler?.dispose()
        storageHandler = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        pendingPayloadResult = null
        storageHandler?.dispose()
        storageHandler = null
        executor.shutdownNow()
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (storageHandler?.handleActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun extractUriFromIntent(incoming: Intent?): Uri? {
        if (incoming == null) return null
        if (incoming.action == Intent.ACTION_VIEW) {
            return incoming.data
        }
        if (incoming.action == Intent.ACTION_SEND) {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                incoming.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                incoming.getParcelableExtra(Intent.EXTRA_STREAM)
            }
        }
        return null
    }

    private fun isUnsafeInternalUri(uri: Uri): Boolean {
        val scheme = uri.scheme?.lowercase() ?: return true
        if (scheme == "file") return true
        if (scheme == "content" && uri.authority == "$packageName.fileprovider") {
            return true
        }
        return false
    }

    private fun processIncomingIntent(incoming: Intent?) {
        val uri = extractUriFromIntent(incoming)
        if (uri == null) {
            extractionComplete = true
            extractionError = "No PDF URI provided."
            deliverResultToDart()
            return
        }

        if (isUnsafeInternalUri(uri)) {
            extractionComplete = true
            extractionError = "Unsupported or unsafe PDF URI."
            deliverResultToDart()
            return
        }

        val reqId = requestCounter.incrementAndGet()
        extractionComplete = false
        extractedPayload = null
        extractionError = null

        executor.execute {
            try {
                val result = PdfInvoiceExtractor.extractFromUri(applicationContext, uri)
                if (isFinishing || isDestroyed || reqId != requestCounter.get()) return@execute
                runOnUiThread {
                    if (isFinishing || isDestroyed || reqId != requestCounter.get()) return@runOnUiThread
                    if (!result.isSfaInvoice) {
                        val forwarded = try {
                            MediaStorePdfSaver.openUriExcludingSelf(this, uri)
                        } catch (_: Exception) {
                            false
                        }
                        if (forwarded) {
                            finish()
                            return@runOnUiThread
                        }
                        extractionComplete = true
                        extractionError = "This PDF is not an SFA Proforma Invoice, and no other PDF viewer was found."
                        deliverResultToDart()
                        return@runOnUiThread
                    }

                    extractionComplete = true
                    extractedPayload = result.text
                    deliverResultToDart()
                }
            } catch (e: Exception) {
                if (isFinishing || isDestroyed || reqId != requestCounter.get()) return@execute
                runOnUiThread {
                    if (isFinishing || isDestroyed || reqId != requestCounter.get()) return@runOnUiThread
                    extractionComplete = true
                    extractionError = e.message ?: "Failed to read PDF file."
                    deliverResultToDart()
                }
            }
        }
    }

    private fun deliverResultToDart() {
        val payloadMap = mapOf(
            "payload" to extractedPayload,
            "error" to extractionError,
        )
        val cb = pendingPayloadResult
        if (cb != null) {
            pendingPayloadResult = null
            cb.success(payloadMap)
        } else if (dartReady) {
            overlayChannel?.invokeMethod("onNewPayload", payloadMap)
        }
    }
}

package com.agile.app.jao

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class PdfStorageChannelHandler(private val activity: Activity) {
    companion object {
        const val CHANNEL = "com.agile.app.jao/pdf_storage"
        const val REQUEST_PICK_PDF = 9042
    }

    private val executor = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null
    private var pendingPickResult: MethodChannel.Result? = null
    @Volatile
    private var disposed = false

    fun register(flutterEngine: FlutterEngine) {
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "savePdfToMediaStore" -> {
                    val relativeSubDir = call.argument<String>("relativeSubDir") ?: "Agile App/Invoices"
                    val fileName = call.argument<String>("fileName") ?: "Transacted Invoices.pdf"
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        val ok = try {
                            MediaStorePdfSaver.savePdfToDocuments(
                                activity.applicationContext,
                                relativeSubDir,
                                fileName,
                                bytes,
                            )
                        } catch (e: Exception) {
                            Log.e("PdfStorageChannel", "savePdfToMediaStore failed: ${e.message}", e)
                            false
                        }
                        if (!disposed && !activity.isFinishing && !activity.isDestroyed) {
                            activity.runOnUiThread {
                                if (!disposed && !activity.isFinishing && !activity.isDestroyed) {
                                    result.success(ok)
                                }
                            }
                        }
                    }
                }

                "openPdfExcludingSelf" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath.isNullOrEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val ok = try {
                        MediaStorePdfSaver.openFileExcludingSelf(activity, filePath)
                    } catch (_: Exception) {
                        false
                    }
                    result.success(ok)
                }

                "isDefaultPdfHandler" -> {
                    val isDefault = try {
                        MediaStorePdfSaver.isSelfDefaultPdfHandler(activity)
                    } catch (_: Exception) {
                        false
                    }
                    result.success(isDefault)
                }

                "openDefaultAppsSettings" -> {
                    try {
                        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
                        } else {
                            Intent(Settings.ACTION_SETTINGS)
                        }
                        activity.startActivity(intent)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }

                "pickAndExtractPdf" -> {
                    if (pendingPickResult != null) {
                        result.error("BUSY", "A file picker is already active.", null)
                        return@setMethodCallHandler
                    }
                    pendingPickResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/pdf"
                    }
                    try {
                        activity.startActivityForResult(intent, REQUEST_PICK_PDF)
                    } catch (e: Exception) {
                        pendingPickResult = null
                        result.error("NO_PICKER", e.message ?: "Unable to open PDF picker.", null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_PDF) return false
        val callback = pendingPickResult
        pendingPickResult = null
        if (callback == null) return true

        val uri: Uri? = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            callback.success(null)
            return true
        }

        executor.execute {
            val payload = try {
                val extracted = PdfInvoiceExtractor.extractFromUri(activity.applicationContext, uri)
                mapOf(
                    "isSfaInvoice" to extracted.isSfaInvoice,
                    "text" to extracted.text,
                )
            } catch (e: Exception) {
                mapOf(
                    "isSfaInvoice" to false,
                    "error" to (e.message ?: "Failed to read PDF"),
                )
            }
            if (!disposed && !activity.isFinishing && !activity.isDestroyed) {
                activity.runOnUiThread {
                    if (!disposed && !activity.isFinishing && !activity.isDestroyed) {
                        callback.success(payload)
                    }
                }
            }
        }
        return true
    }

    fun dispose() {
        disposed = true
        pendingPickResult = null
        channel?.setMethodCallHandler(null)
        channel = null
        executor.shutdownNow()
    }
}

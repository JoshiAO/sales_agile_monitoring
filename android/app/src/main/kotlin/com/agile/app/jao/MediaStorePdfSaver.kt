package com.agile.app.jao

import android.content.ComponentName
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File

object MediaStorePdfSaver {
    private const val TAG = "MediaStorePdfSaver"

    private fun isSafeFileName(fileName: String): Boolean {
        if (fileName.isBlank() || fileName.contains("..") || fileName.contains('\u0000')) {
            return false
        }
        return !fileName.contains('/') && !fileName.contains('\\')
    }

    private fun isSafeRelativeSubDir(subDir: String): Boolean {
        if (subDir.contains("..") || subDir.contains('\u0000') || subDir.contains('\\')) {
            return false
        }
        return true
    }

    fun savePdfToDocuments(
        context: Context,
        relativeSubDir: String,
        fileName: String,
        bytes: ByteArray,
    ): Boolean {
        if (!isSafeFileName(fileName) || !isSafeRelativeSubDir(relativeSubDir)) {
            Log.e(TAG, "Rejected unsafe path/fileName: $relativeSubDir / $fileName")
            return false
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val cleanSubDir = relativeSubDir.trim().trim('/')
            val relativePath = "${Environment.DIRECTORY_DOCUMENTS}/$cleanSubDir/"
            val relativePathNoSlash = "${Environment.DIRECTORY_DOCUMENTS}/$cleanSubDir"
            val resolver = context.contentResolver
            val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

            // Collect existing app-owned rows BEFORE inserting, but only delete them
            // AFTER the new file is written & finalized so a failed write never destroys data.
            val existingUris = mutableListOf<Uri>()
            val projection = arrayOf(MediaStore.MediaColumns._ID)
            val selection =
                "(${MediaStore.MediaColumns.RELATIVE_PATH} = ? OR ${MediaStore.MediaColumns.RELATIVE_PATH} = ?) " +
                    "AND ${MediaStore.MediaColumns.DISPLAY_NAME} = ?"
            val selectionArgs = arrayOf(relativePath, relativePathNoSlash, fileName)

            try {
                resolver.query(collection, projection, selection, selectionArgs, null)?.use { cursor ->
                    while (cursor.moveToNext()) {
                        val id = cursor.getLong(0)
                        existingUris.add(ContentUris.withAppendedId(collection, id))
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Querying existing daily PDF failed (continuing with insert): ${e.message}")
            }

            // Use a temporary staging name if an existing row exists so MediaStore doesn't auto-suffix " (1)"
            val stagedName = if (existingUris.isNotEmpty()) ".tmp_${System.currentTimeMillis()}_$fileName" else fileName

            val insertValues = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, stagedName)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/pdf")
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }

            val targetUri = resolver.insert(collection, insertValues)
            if (targetUri == null) {
                Log.e(TAG, "MediaStore.insert returned null for $relativePath$fileName")
                return false
            }

            return try {
                resolver.openOutputStream(targetUri, "w")?.use { out ->
                    out.write(bytes)
                    out.flush()
                } ?: run {
                    Log.e(TAG, "openOutputStream returned null for $targetUri")
                    resolver.delete(targetUri, null, null)
                    return false
                }

                // Write succeeded: now remove old rows and atomically finalize & rename the new row.
                for (oldUri in existingUris) {
                    try {
                        resolver.delete(oldUri, null, null)
                    } catch (e: Exception) {
                        Log.w(TAG, "Unable to delete previous PDF row $oldUri: ${e.message}")
                    }
                }

                val finalizeValues = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                    if (stagedName != fileName) {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                    }
                }
                resolver.update(targetUri, finalizeValues, null, null)
                Log.i(TAG, "Saved progressive daily PDF (${bytes.size} bytes) to $relativePath$fileName")
                true
            } catch (e: Exception) {
                Log.e(TAG, "Failed writing daily PDF to $targetUri: ${e.message}", e)
                try {
                    resolver.delete(targetUri, null, null)
                } catch (_: Exception) {
                }
                false
            }
        } else {
            @Suppress("DEPRECATION")
            val docsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
            val targetDir = File(docsDir, relativeSubDir)
            if (!targetDir.canonicalPath.startsWith(docsDir.canonicalPath + File.separator)) {
                Log.e(TAG, "Path traversal blocked for $relativeSubDir")
                return false
            }
            if (!targetDir.exists()) {
                targetDir.mkdirs()
            }
            val outFile = File(targetDir, fileName)
            if (!outFile.canonicalPath.startsWith(targetDir.canonicalPath + File.separator)) {
                Log.e(TAG, "File traversal blocked for $fileName")
                return false
            }
            outFile.writeBytes(bytes)
            return true
        }
    }

    fun openFileExcludingSelf(context: Context, filePath: String): Boolean {
        val file = File(filePath)
        if (!file.exists() || !file.name.endsWith(".pdf", ignoreCase = true)) return false
        val allowedRoot = File(context.filesDir, "Agile App/Invoices").canonicalPath
        if (!file.canonicalPath.startsWith(allowedRoot + File.separator)) {
            Log.e(TAG, "Blocked FileProvider access outside invoices directory: $filePath")
            return false
        }
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file,
        )
        return openUriExcludingSelf(context, uri)
    }

    fun openUriExcludingSelf(context: Context, uri: Uri): Boolean {
        val baseIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/pdf")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        val resolved = context.packageManager.queryIntentActivities(
            baseIntent,
            PackageManager.MATCH_DEFAULT_ONLY,
        )
        val externalTargets = resolved.filter {
            it.activityInfo.packageName != context.packageName
        }

        if (externalTargets.isEmpty()) {
            return false
        }

        val targetIntents = externalTargets.map { info ->
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/pdf")
                component = ComponentName(info.activityInfo.packageName, info.activityInfo.name)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }

        val chosen = if (targetIntents.size == 1) {
            targetIntents.first()
        } else {
            Intent.createChooser(targetIntents.first(), "Open PDF with").apply {
                putExtra(Intent.EXTRA_INITIAL_INTENTS, targetIntents.drop(1).toTypedArray())
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        context.startActivity(chosen)
        return true
    }

    fun isSelfDefaultPdfHandler(context: Context): Boolean {
        val probe = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(Uri.parse("content://com.example.probe/sample.pdf"), "application/pdf")
        }
        val resolved = context.packageManager.resolveActivity(probe, PackageManager.MATCH_DEFAULT_ONLY)
        return resolved?.activityInfo?.packageName == context.packageName
    }
}

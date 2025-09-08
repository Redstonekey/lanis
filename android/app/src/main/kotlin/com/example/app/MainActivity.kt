package com.example.app

import android.content.Intent
import android.os.Environment
import android.util.Log
import android.graphics.Bitmap
import android.net.Uri
import com.zynksoftware.documentscanner.ui.DocumentScanner
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.File


class MainActivity: FlutterActivity() {
    private val createFileCode = 1404
    private val scanDocumentCode = 4200
    private var filePath = ""
    private var scanDocumentCallback: ((Uri?) -> Unit)? = null
    // Holds the pending result for an ongoing saveFile call so we can complete
    // the Dart Future after the user picked a destination and the copy finished.
    private var pendingSaveResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFile" -> {
                    // Prevent overlapping saveFile calls
                    if (pendingSaveResult != null) {
                        result.error("SAVE_IN_PROGRESS", "Another saveFile operation is in progress", null)
                        return@setMethodCallHandler
                    }

                    val incomingPath = call.argument<String>("filePath")
                    val incomingName = call.argument<String>("fileName")
                    val incomingMime = call.argument<String>("mimeType")

                    if (incomingPath == null || incomingName == null || incomingMime == null) {
                        result.error("INVALID_ARGS", "filePath, fileName or mimeType missing", null)
                        return@setMethodCallHandler
                    }

                    filePath = incomingPath
                    // Store the result so we can complete it later in onActivityResult
                    pendingSaveResult = result
                    createFile(incomingName, incomingMime)
                }
                "scanDocument" -> {
                    scanDocument { uri ->
                        if (uri != null) {
                            result.success(uri.path)
                        } else {
                            result.success(null)
                        }
                    }
                }
                "openFolder" -> {
                    val folderPath = call.argument<String>("path") ?: ""
                    try {
                        val dir = File(folderPath)
                        if (!dir.exists() || !dir.isDirectory) {
                            result.error("OPEN_FOLDER_FAILED", "Path is not a directory", null)
                        } else {
                            // Create a small marker file inside the folder so we can share a file:// -> content:// URI
                            val marker = File(dir, ".lanis_open_marker.txt")
                            if (!marker.exists()) {
                                try {
                                    marker.writeText("Open folder: ${'$'}{dir.name}")
                                } catch (e: Exception) {
                                    // ignore write failures, we'll still try to share existing files
                                }
                            }

                            // Use the Gradle applicationId (BuildConfig.APPLICATION_ID) which matches
                            // the AndroidManifest provider authority declared as ${applicationId}.fileprovider
                            val authority = applicationContext.packageName + ".fileprovider"
                            Log.d("MainActivity", "Resolved FileProvider authority: $authority")
                            val uri = androidx.core.content.FileProvider.getUriForFile(this, authority, marker)

                            val intent = Intent(Intent.ACTION_VIEW)
                            intent.setDataAndType(uri, "text/plain")
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

                            val chooser = Intent.createChooser(intent, "Open folder")

                            // Grant temporary read permission to all apps that can handle the chooser
                            val resInfoList = packageManager.queryIntentActivities(chooser, 0)
                            for (ri in resInfoList) {
                                val packageName = ri.activityInfo.packageName
                                grantUriPermission(packageName, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }

                            startActivity(chooser)
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                        result.error("OPEN_FOLDER_FAILED", e.message, null)
                    }
                }
                "getDownloadsPath" -> {
                    try {
                        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath
                        result.success(downloads)
                    } catch (e: Exception) {
                        result.error("GET_DOWNLOADS_FAILED", e.message, null)
                    }
                }
                "getDownloadsPath" -> {
                    try {
                        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                        result.success(downloads.absolutePath)
                    } catch (e: Exception) {
                        result.error("GET_DOWNLOADS_FAILED", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            createFileCode -> {
                if (resultCode == RESULT_OK && data?.data != null) {
                    val uri = data.data!!
                    try {
                        contentResolver.openFileDescriptor(uri, "w")?.use {
                            FileInputStream(filePath).use { inputStream ->
                                FileOutputStream(it.fileDescriptor).use { outputStream ->
                                    inputStream.copyTo(outputStream)
                                }
                            }
                        }
                        // Inform Dart side that saving succeeded and pass the uri path
                        pendingSaveResult?.success(uri.toString())
                        pendingSaveResult = null
                    } catch (e: FileNotFoundException) {
                        e.printStackTrace()
                        pendingSaveResult?.error("SAVE_FAILED", e.message, null)
                        pendingSaveResult = null
                    } catch (e: IOException) {
                        e.printStackTrace()
                        pendingSaveResult?.error("SAVE_FAILED", e.message, null)
                        pendingSaveResult = null
                    }
                } else {
                    // User cancelled or no URI returned
                    pendingSaveResult?.error("CANCELLED", "User cancelled file save", null)
                    pendingSaveResult = null
                }
            }

            scanDocumentCode -> {
                data?.data?.let { uri ->
                    scanDocumentCallback?.let { callback ->
                        callback(uri)
                        scanDocumentCallback = null
                    }
                }
            }
        }
    }

    private fun createFile(fileName: String, mimeType: String) {
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        startActivityForResult(intent, createFileCode)
    }

    /**
     * Returns the file path
     */
    private fun scanDocument(callback: (Uri?) -> Unit) {
        val configuration = DocumentScanner.Configuration()
        configuration.imageQuality = 100
        configuration.imageType = Bitmap.CompressFormat.PNG
        configuration.galleryButtonEnabled = false // Is buggy with permissions
        DocumentScanner.init(this, configuration)

        val intent = Intent(this, AppScanActivity::class.java)
        startActivityForResult(intent, scanDocumentCode)

        scanDocumentCallback = callback
    }

    companion object {
        private const val STORAGE_CHANNEL = "io.github.lanis-mobile/storage"
    }
}

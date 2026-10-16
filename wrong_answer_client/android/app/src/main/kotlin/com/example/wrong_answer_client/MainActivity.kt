package com.example.wrong_answer_client

import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    // 与 Dart 端 PlatformOpenFile 约定的通道名
    private val openFileChannel = "wqm/open_file"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, openFileChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "open") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val mime = call.argument<String>("mime")
                if (path.isNullOrEmpty()) {
                    result.error("BAD_ARGS", "缺少文件路径", null)
                    return@setMethodCallHandler
                }
                val file = File(path)
                if (!file.exists()) {
                    result.error("NO_FILE", "文件不存在", null)
                    return@setMethodCallHandler
                }
                // authority 与 AndroidManifest 中 provider 的 ${applicationId}.fileprovider 对齐
                val uri = FileProvider.getUriForFile(
                    this, "$packageName.fileprovider", file)
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mime ?: "*/*")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                             Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                if (intent.resolveActivity(packageManager) == null) {
                    result.error("NO_APP", "手机上没有可打开该文件的应用", null)
                } else {
                    startActivity(intent)
                    result.success(null)
                }
            }
    }
}

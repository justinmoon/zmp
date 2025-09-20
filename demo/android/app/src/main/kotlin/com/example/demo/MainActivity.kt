package com.example.demo

import android.os.Bundle
import android.view.Gravity
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val number = Native.getNumber()
    val textView = TextView(this).apply {
      text = "Zig says: $number"
      textSize = 24f
      gravity = Gravity.CENTER
      setPadding(32, 32, 32, 32)
    }
    setContentView(textView)
    // launchWebView(BuildConfig.DEV_SERVER_PORT)
  }

  @Suppress("unused")
  private fun launchWebView(port: Int) {
    if (BuildConfig.DEBUG) {
      WebView.setWebContentsDebuggingEnabled(true)
    }
    val webView = WebView(this)
    val settings = webView.settings
    settings.javaScriptEnabled = true
    settings.domStorageEnabled = true
    webView.webViewClient = WebViewClient()
    setContentView(webView)
    webView.loadUrl("http://127.0.0.1:$port/")
  }
}

package com.example.demo

import android.os.Bundle
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    if (BuildConfig.DEV_NATIVE) {
      Native.startServer(BuildConfig.DEV_SERVER_PORT)
    }
    val webView = WebView(this)
    if (BuildConfig.DEBUG) {
      WebView.setWebContentsDebuggingEnabled(true)
    }
    val s = webView.settings
    s.javaScriptEnabled = true
    s.domStorageEnabled = true
    webView.webViewClient = WebViewClient()
    setContentView(webView)
    webView.loadUrl("http://127.0.0.1:${BuildConfig.DEV_SERVER_PORT}/")
  }
}

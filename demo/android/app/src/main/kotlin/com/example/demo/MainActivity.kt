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
    launchWebView(BuildConfig.DEV_SERVER_PORT)
  }

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
    val host = "127.0.0.1"
    webView.loadUrl("http://" + host + ":" + port + "/")
  }
}

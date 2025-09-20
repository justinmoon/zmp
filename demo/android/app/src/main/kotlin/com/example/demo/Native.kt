package com.example.demo

object Native {
  init {
    System.loadLibrary("zmpserver")
  }
  @JvmStatic external fun startServer(port: Int)
}

package com.example.demo

object Native {
  init {
    System.loadLibrary("zmpserver")
  }
  external fun startServer(port: Int)
}


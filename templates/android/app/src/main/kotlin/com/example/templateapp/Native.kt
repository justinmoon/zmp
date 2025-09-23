package __APP_ID__

import kotlin.concurrent.thread

object Native {
  init {
    if (BuildConfig.DEV_NATIVE) {
      System.loadLibrary("zmpserver")
    }
  }

  private val lock = Any()
  private var serverThread: Thread? = null

  @JvmStatic
  fun startServer(port: Int) {
    if (!BuildConfig.DEV_NATIVE) return
    synchronized(lock) {
      if (serverThread != null) return
      serverThread = thread(name = "zmp-native-server") {
        try {
          startServerNative(port)
        } finally {
          synchronized(lock) {
            serverThread = null
          }
        }
      }
    }
  }

  @JvmStatic
  fun getNumber(): Int {
    if (!BuildConfig.DEV_NATIVE) return 0
    return getNumberNative()
  }

  @JvmStatic private external fun getNumberNative(): Int
  @JvmStatic private external fun startServerNative(port: Int)
}

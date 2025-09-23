package __APP_ID__

import android.os.Bundle
import android.view.Gravity
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val textView = TextView(this).apply {
      text = "Zig says: " + Native.getNumber()
      textSize = 24f
      gravity = Gravity.CENTER
      setPadding(32, 32, 32, 32)
    }
    setContentView(textView)
  }
}

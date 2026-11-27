package cl.miscamaras.mis_camaras

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Actividad principal de la app.
 * Agrega un canal "mis_camaras/red" para activar el "MulticastLock":
 * sin él, Android descarta los paquetes de búsqueda que responden las cámaras
 * (SADP de Hikvision, búsqueda de Dahua y ONVIF).
 */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mis_camaras/red")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "multicastLock" -> {
                        try {
                            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            val lock = multicastLock ?: wifi.createMulticastLock("mis_camaras_busqueda").also {
                                it.setReferenceCounted(false)
                                multicastLock = it
                            }
                            if (!lock.isHeld) lock.acquire()
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "multicastUnlock" -> {
                        multicastLock?.let { if (it.isHeld) it.release() }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        multicastLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }
}

package cl.miscamaras.mis_camaras

import android.Manifest
import android.annotation.TargetApi
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

/**
 * Actividad principal de la app. Canal "mis_camaras/red":
 * - multicastLock / multicastUnlock: sin el "MulticastLock", Android descarta
 *   los paquetes de búsqueda que responden las cámaras (SADP, Dahua, ONVIF).
 * - wifiInfo: nombre del WiFi, IP y puerta de enlace, para separar los equipos
 *   por red. Android solo entrega el nombre del WiFi con el permiso de
 *   ubicación (la app no usa la ubicación para nada más).
 * - hasLocation / requestLocation: revisar y pedir ese permiso.
 */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var permissionResult: MethodChannel.Result? = null
    private val permissionCode = 7301

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
                    "wifiInfo" -> wifiInfo(result)
                    "hasLocation" -> result.success(hasLocation())
                    "requestLocation" -> requestLocation(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasLocation(): Boolean =
        Build.VERSION.SDK_INT < 23 ||
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun requestLocation(result: MethodChannel.Result) {
        if (hasLocation() || Build.VERSION.SDK_INT < 23) {
            result.success(hasLocation())
            return
        }
        permissionResult?.success(false)
        permissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
            permissionCode,
        )
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == permissionCode) {
            permissionResult?.success(hasLocation())
            permissionResult = null
        }
    }

    private fun locationOn(): Boolean {
        return try {
            val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            if (Build.VERSION.SDK_INT >= 28) {
                lm.isLocationEnabled
            } else {
                lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            }
        } catch (e: Exception) {
            true
        }
    }

    private fun cleanSsid(raw: String?): String? {
        val s = raw?.trim()?.removePrefix("\"")?.removeSuffix("\"")?.trim() ?: return null
        if (s.isEmpty() || s == "<unknown ssid>" || s == "0x") return null
        return s
    }

    private fun intToIp(v: Int): String =
        "${v and 0xff}.${(v shr 8) and 0xff}.${(v shr 16) and 0xff}.${(v shr 24) and 0xff}"

    @Suppress("DEPRECATION")
    private fun wifiInfo(result: MethodChannel.Result) {
        val info = HashMap<String, Any?>()
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        var onWifi = false
        try {
            val active = cm.activeNetwork
            val caps = if (active != null) cm.getNetworkCapabilities(active) else null
            onWifi = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true ||
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true
            val lp = if (active != null) cm.getLinkProperties(active) else null
            lp?.linkAddresses?.firstOrNull { it.address is Inet4Address }?.address?.hostAddress?.let {
                info["ip"] = it
            }
            lp?.routes?.firstOrNull { it.isDefaultRoute && it.gateway is Inet4Address }?.gateway?.hostAddress?.let {
                info["gateway"] = it
            }
        } catch (e: Exception) {
        }
        try {
            val dhcp = wm.dhcpInfo
            if (info["gateway"] == null && dhcp != null && dhcp.gateway != 0) info["gateway"] = intToIp(dhcp.gateway)
            if (info["ip"] == null && dhcp != null && dhcp.ipAddress != 0) info["ip"] = intToIp(dhcp.ipAddress)
        } catch (e: Exception) {
        }
        info["wifi"] = onWifi
        info["locationOn"] = locationOn()
        if (!onWifi) {
            result.success(info)
            return
        }
        var ssid: String? = null
        try {
            ssid = cleanSsid(wm.connectionInfo?.ssid)
        } catch (e: Exception) {
        }
        if (ssid != null || Build.VERSION.SDK_INT < 31 || !hasLocation()) {
            info["ssid"] = ssid
            result.success(info)
            return
        }
        ssidAndroid12(cm) { name ->
            info["ssid"] = name
            result.success(info)
        }
    }

    /** Android 12 o más nuevo: el nombre del WiFi llega por un "callback" con ubicación. */
    @TargetApi(31)
    private fun ssidAndroid12(cm: ConnectivityManager, done: (String?) -> Unit) {
        val handler = Handler(Looper.getMainLooper())
        var finished = false
        var callback: ConnectivityManager.NetworkCallback? = null
        fun finish(name: String?) {
            if (finished) return
            finished = true
            try {
                callback?.let { cm.unregisterNetworkCallback(it) }
            } catch (e: Exception) {
            }
            done(name)
        }
        val cb = object : ConnectivityManager.NetworkCallback(
            ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO,
        ) {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                val wifi = caps.transportInfo as? WifiInfo
                val name = cleanSsid(wifi?.ssid)
                handler.post { finish(name) }
            }
        }
        callback = cb
        try {
            val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()
            cm.registerNetworkCallback(request, cb)
        } catch (e: Exception) {
            finish(null)
            return
        }
        handler.postDelayed({ finish(null) }, 1500)
    }

    override fun onDestroy() {
        multicastLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }
}

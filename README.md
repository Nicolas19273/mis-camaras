# Mis Cámaras

Una app propia para ver cámaras **Hikvision** y **Dahua** con la misma interfaz.
Está hecha en Flutter (Android y iPhone con el mismo código).

## Instalar en Android (sin computador)

GitHub compila la app solo cada vez que se actualiza el código.

**La primera vez:**
1. En el teléfono, abre este repositorio en Chrome y entra a **Releases**.
2. Abre la versión más reciente y toca el archivo **MisCamaras-v0.X.X.apk**.
3. Ábrelo cuando termine la descarga. Android pedirá permiso para instalar apps
   desde Chrome: acéptalo.

**Después:** la app avisa sola cuando hay una versión nueva (aviso en *En vivo*
y en *Ajustes*). Toca **Actualizar ahora**:
- La descarga **sigue en segundo plano** aunque apagues la pantalla o salgas de la
  app, con una notificación que muestra el avance.
- Al terminar, toca la notificación **"Actualización descargada"** o vuelve a la app:
  se abre el instalador solo. Confirma y listo, sin borrar tus equipos.
- Si ya estaba descargada, el botón dice **Instalar ahora** y no vuelve a descargar.
- La primera vez Android pedirá permiso para mostrar notificaciones y para que
  *Mis Cámaras* instale actualizaciones.
- Si cierras la app a la fuerza desde "Recientes", Android puede detener la descarga:
  al abrir la app, toca **Continuar descarga**.

> Para que la app pueda revisar las actualizaciones, este repositorio tiene que ser
> **público**. El código no contiene contraseñas ni datos de tus cámaras: esos se
> guardan solo en tu teléfono.

---

## Qué hace la versión 0.4

- **En vivo:** mosaico estilo NVR con vistas de **1, 4, 9 o 16** cámaras, estado
  de cada cámara (en vivo, conectando, sin conexión) y botón para **reconectar todas**.
- **Mosaico a pantalla completa** en horizontal, con páginas si tienes muchas cámaras.
- **Pantalla completa** por cámara: desliza para pasar a la siguiente, zoom con los
  dedos, HD/SD, sonido, reloj y etiqueta *EN VIVO*.
- **Equipos:** agregar, editar, eliminar y **ordenar** (mantén presionado y arrastra).
- **Buscar en mi red:** encuentra solos los equipos Hikvision y Dahua del WiFi
  (SADP, búsqueda Dahua, ONVIF y rastreo HTTP). Eliges cuáles, escribes la contraseña
  una vez y la app detecta modelo y cantidad de cámaras de cada NVR.
- **Ajustes:** actualizaciones, color principal a elección, nombres sobre las cámaras
  y calidad del mosaico.
- **Cámaras PTZ:** si una cámara se puede mover, en pantalla completa aparece un
  **joystick** (y botones de zoom si tiene zoom óptico). Al soltarlo, la cámara se detiene.
  Usa el *puerto HTTP* del equipo (normalmente 80).
- Contraseñas en el almacenamiento seguro del teléfono.
- Reconexión automática si se corta el video. Si la contraseña está mal, **no**
  reintenta solo, para que la cámara no bloquee tu usuario.
- El video se pausa cuando sales de la app.

Por ahora funciona **dentro de la red de tu casa** (mismo WiFi que las cámaras).

## Primer uso

1. Toca **Agregar equipo**.
2. Elige la marca y escribe el nombre, la IP (ej. `192.168.1.64`), el usuario y la contraseña.
3. En **Canales** pon `1` si es una cámara sola, o la cantidad de cámaras si es un NVR.
4. Toca **Probar**. Si ves imagen, toca **Guardar**.

## Si una cámara no se ve

- El teléfono tiene que estar **en el mismo WiFi** que las cámaras.
- Prueba en **VLC** la dirección RTSP que muestra el formulario. Si VLC tampoco
  la abre, el problema está en la cámara o en los datos.
- Algunos equipos traen **RTSP desactivado**: actívalo en la página web de la cámara.
- Si usas un usuario que no es `admin`, revisa que tenga permiso de **vista en vivo**.
- Tras varias contraseñas erradas, la cámara **bloquea el usuario** unos 30 minutos.
- Imagen negra o trabada en teléfonos antiguos: cambia el flujo secundario a **H.264**.
- **No aparece el joystick en una PTZ:** revisa el *puerto HTTP* del equipo en la app
  y que el usuario tenga permiso de control PTZ. En NVR Dahua, si se mueve la cámara
  equivocada, avísame: algunos modelos numeran los canales distinto.

---

## Cómo está organizado el código

```
lib/
├── main.dart                 Arranque de la app
├── app.dart                  Configuración general
├── config.dart               Versión y repositorio (los pone GitHub al compilar)
├── theme.dart                ← COLORES Y ESTILO (cámbialos a tu gusto aquí)
├── models/device.dart        Qué datos tiene un equipo
├── brands/
│   ├── brand_adapter.dart    Lo común a todas las marcas
│   ├── hikvision.dart        Todo lo propio de Hikvision
│   ├── dahua.dart            Todo lo propio de Dahua
│   └── brands.dart           Elige el adaptador según la marca
├── services/
│   ├── app_store.dart        Guarda equipos y preferencias en el teléfono
│   ├── discovery.dart        Busca equipos en el WiFi (SADP, Dahua, ONVIF, HTTP)
│   ├── auto_setup.dart       Registra equipos encontrados (modelo y canales)
│   ├── camera_http.dart      Conexión con la API de cada equipo (Digest)
│   ├── update_service.dart   Busca, descarga e instala actualizaciones
│   └── camera_status.dart    Cuenta cámaras en vivo / sin conexión
├── screens/                  En vivo, mosaico, pantalla completa, equipos, ajustes
└── widgets/                  Reproductor RTSP, cuadros del mosaico, reloj, etc.

test/                         Pruebas (direcciones RTSP y actualizaciones)
branding/                     Ícono y actividad Android (permiso de búsqueda)
.github/workflows/            Compilación automática del APK
```

La interfaz nunca habla directo con una marca: siempre pasa por `lib/brands/`.
Ahí se va a sumar la configuración (imagen, detección, etc.) para cada marca.

## Compilar en un computador (opcional)

Si algún día quieres compilarla tú mismo, con Flutter instalado:

```
flutter create --org cl.miscamaras --project-name mis_camaras --platforms android,ios app
rm -rf app/lib app/test && cp -r lib test app/
cd app
flutter pub add media_kit media_kit_video media_kit_libs_video shared_preferences flutter_secure_storage http open_filex crypto background_downloader
flutter run
```

En Android hay que agregar `<uses-permission android:name="android.permission.INTERNET"/>`
en `android/app/src/main/AndroidManifest.xml` para la versión final. En iPhone hay que
agregar `NSLocalNetworkUsageDescription` en `ios/Runner/Info.plist`.

## Próximas versiones

1. Ver las cámaras **desde fuera de casa** con Tailscale o WireGuard, sin abrir puertos.
2. **Información del equipo** (modelo, firmware, estado) vía ISAPI y la API de Dahua.
3. **Configuración**: imagen, video, detección de movimiento, nombre y hora.
4. **Grabaciones** del NVR y **alertas**.
5. Ajustes a tu gusto: ordenar cámaras, grupos, nombres por canal, favoritas.

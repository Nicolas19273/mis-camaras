# Mis Cámaras

Una app propia para ver cámaras **Hikvision** y **Dahua** con la misma interfaz.
Está hecha en Flutter (Android y iPhone con el mismo código).

## Instalar en Android (sin computador)

GitHub compila la app solo cada vez que se actualiza el código.

1. En el teléfono, abre este repositorio en el navegador y entra a **Releases**
   (en la página principal, a la derecha o abajo).
2. Abre la versión más reciente y toca el archivo **MisCamaras-v0.1.X.apk**.
3. Cuando termine la descarga, ábrelo. Android te pedirá permiso para
   **instalar apps de fuentes desconocidas** desde el navegador: acéptalo.
4. Listo. Para actualizar, repite los mismos pasos con la versión nueva.

> Si al actualizar Android dice *"La app no se instaló"*, desinstala la versión
> anterior y vuelve a instalar (vas a tener que agregar los equipos de nuevo).

Para ver si una compilación está en curso o falló, revisa la pestaña **Actions**.

---

## Qué hace esta versión (0.1)

- Agregar, editar y eliminar equipos: cámaras sueltas o NVR/DVR con varios canales.
- **Cuadrícula en vivo** con todas las cámaras, de 1, 2 o 3 columnas.
- **Pantalla completa** al tocar una cámara: zoom con los dedos, HD/SD y sonido.
- Botón **Probar** para revisar la conexión antes de guardar.
- Las contraseñas se guardan en el almacenamiento seguro del teléfono.
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

---

## Cómo está organizado el código

```
lib/
├── main.dart                 Arranque de la app
├── app.dart                  Configuración general
├── theme.dart                ← COLORES Y ESTILO (cámbialos a tu gusto aquí)
├── models/device.dart        Qué datos tiene un equipo
├── brands/
│   ├── brand_adapter.dart    Lo común a todas las marcas
│   ├── hikvision.dart        Todo lo propio de Hikvision
│   ├── dahua.dart            Todo lo propio de Dahua
│   └── brands.dart           Elige el adaptador según la marca
├── services/app_store.dart   Guarda los equipos en el teléfono
├── screens/                  Pantallas (cuadrícula, pantalla completa, equipos, formulario)
└── widgets/                  Piezas reutilizables (reproductor RTSP, cuadros, insignias)

test/                         Pruebas de las direcciones RTSP
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
flutter pub add media_kit media_kit_video media_kit_libs_video shared_preferences flutter_secure_storage
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

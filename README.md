# Timbre Escolar · Virtus College

Sistema de timbre para el PC con Windows conectado a la megafonía del colegio.
Toca el timbre automáticamente al final de cada clase y se gestiona desde un panel
web con la imagen de Virtus College, accesible desde cualquier ordenador o móvil de la red.

**Está pensado para funcionar solo:** si el PC se apaga o se reinicia, Windows inicia
sesión automáticamente, el timbre arranca solo y la hora se mantiene sincronizada.

---

## Instalación (una sola vez, unos 5 minutos)

1. Copia el ZIP al PC del timbre y **descomprímelo** (clic derecho → *Extraer todo*).
   No lo ejecutes desde dentro del ZIP.
2. Doble clic en **`INSTALAR.bat`** y acepta el aviso de permisos de administrador.
3. Responde a las preguntas:
   - **Usuario de Windows** del timbre (por defecto, el actual). Se recomienda una cuenta local dedicada, p. ej. `timbre`.
   - **Contraseña** de ese usuario, para el inicio de sesión automático. Se guarda **cifrada** por Windows (secreto LSA), igual que hace la herramienta Autologon de Microsoft.
   - **Puerto** del panel (8080) y **contraseña del panel** (opcional, usuario `admin`).
   - Si quieres que la **pantalla se bloquee** sola tras entrar. El timbre sigue sonando con la pantalla bloqueada.
4. Al final sonará un **timbre de prueba** por los altavoces y se abrirá el panel.
5. Acepta **reiniciar** para comprobar que el PC entra solo y que el timbre arranca solo.

El instalador lo deja todo en **`C:\TimbreEscolar`** y hace lo siguiente:

| Qué | Cómo |
|---|---|
| Python | Descarga **Python portátil** dentro de `C:\TimbreEscolar\python`. No instala nada en Windows |
| Inicio de sesión automático | Al encender o reiniciar, Windows entra solo en el usuario del timbre |
| Arranque del timbre | Tarea programada «Timbre Escolar»: arranca al iniciar sesión, sin ventana. **Se vigila cada 5 min** y **se relanza al minuto** si se cierra o falla |
| Hora | Servicio de hora de Windows en automático; servidores **hora.roa.es** (hora oficial de España), es.pool.ntp.org y time.windows.com. Sincroniza **al arrancar y cada hora**, aunque el reloj esté muy desviado. Si el PC está en un dominio, usa el servidor del colegio |
| Energía | El PC **no se suspende** nunca (la pantalla sí se puede apagar) |
| Windows Update | No reinicia entre las 7:00 y las 20:00. Si reinicia fuera de ese horario, el PC entra solo y el timbre vuelve |
| Cortafuegos | Permite abrir el panel desde la red local del colegio |
| Escritorio | Acceso directo **«Timbre Escolar»** al panel |
| Marca | Descarga el logo y el favicon oficiales de Virtus para el panel |

## Acceso desde fuera del colegio: timbre.virtuscollege.com

El timbre **sigue funcionando en el PC del colegio** (es el que está conectado a la megafonía).
`timbre.virtuscollege.com` es una entrada segura a ese PC a través de **Cloudflare Tunnel**:
el PC abre una conexión **saliente** hacia Cloudflare, así que **no hay que abrir puertos** en el router del colegio.

### 1. Crear el túnel (Cloudflare, una vez)
1. https://one.dash.cloudflare.com → **Networks → Tunnels → Create a tunnel** → tipo **Cloudflared** → nombre `timbre-colegio`.
2. En «Install and run a connector» elige **Windows** y **copia el token** (el texto largo que empieza por `eyJ…`).
3. En **Public hostname** (o *Published application routes*):
   - Subdomain: `timbre` · Domain: `virtuscollege.com`
   - Service: **HTTP** · URL: `localhost:8080`
   Cloudflare crea solo el registro DNS de `timbre.virtuscollege.com`.

### 2. Proteger el acceso (imprescindible)
Sin protección, cualquiera en Internet podría hacer sonar el timbre del colegio.
1. Zero Trust → **Access → Applications → Add an application → Self-hosted**.
2. Application domain: `timbre.virtuscollege.com`.
3. Policy **Allow** → Include → **Emails ending in** `@virtuscollege.com` (o solo los correos concretos del personal autorizado).
4. Método de acceso: **One-time PIN** (llega un código al correo) o el inicio de sesión de Google/Microsoft del colegio.

Recomendado además: poner una **contraseña del panel** al ejecutar el instalador (segunda capa de seguridad).

### 3. Conectar el PC del colegio

> Si el túnel falla o hay que cambiar el token, haz doble clic en **`CONECTAR_CLOUDFLARE.bat`**:
> limpia lo anterior, descarga cloudflared nuevo y lo conecta (solo pide pegar el comando de Cloudflare).
> No pegues el token en la ventana negra de Windows ni lo compartas en fotos o chats.

Ejecuta `INSTALAR.bat` (o vuelve a ejecutarlo) y **pega el token** cuando lo pida.
El instalador descarga `cloudflared` (programa oficial de Cloudflare) y lo deja como **servicio de Windows**:
arranca solo con el PC, incluso antes de iniciar sesión. En Cloudflare → Tunnels el túnel debe aparecer **HEALTHY**.

> Si el PC está apagado o sin Internet, `timbre.virtuscollege.com` mostrará un error de Cloudflare (502/1033),
> pero el timbre del colegio no depende de Internet para sonar.

## ⚠ Cortes de luz: ajuste de la BIOS (imprescindible)

Si el PC se apaga por un **corte de corriente**, Windows no puede encenderlo de nuevo.
Hay que activarlo una vez en la BIOS/UEFI del PC:

1. Enciende el PC y pulsa **F2**, **Supr** o **F10** (según la marca) para entrar en la BIOS.
2. Busca **«Restore on AC Power Loss»**, «AC Power Recovery», «After Power Failure» o «AC Back», normalmente en *Power* o *Advanced*.
3. Ponlo en **«Power On»** o «Last State», guarda y sal (**F10**).

Así, cuando vuelve la luz: el PC se enciende → Windows entra solo → el timbre arranca → la hora se sincroniza.

## La hora

- El timbre sigue **siempre la hora local del ordenador** y la comprueba dos veces por segundo.
- Cada 30 minutos el timbre **compara el reloj del PC con la hora oficial**. En **Inicio → Estado** verás:
  - «Hora correcta», con el desfase en segundos.
  - «Reloj desajustado»: el timbre pide a Windows que sincronice al momento y lo anota en el Registro.
  - «No se pudo comprobar la hora»: el PC no tiene Internet.
- Los ajustes de pocos segundos de Windows **no hacen que un toque se pierda ni suene dos veces**.
- Si el PC estuvo apagado o suspendido, **no suenan de golpe** los toques atrasados.
- El cambio de horario de verano o invierno lo hace Windows solo. Revisa que la **zona horaria** sea la correcta: *Configuración → Hora e idioma*. El panel la muestra en *Estado*.

## Conexión al sistema de sonido

```
 PC (salida de auriculares / tarjeta USB) ──cable minijack 3,5 mm → 2×RCA──► entrada LINE/AUX del amplificador
```

- Usa la entrada **LINE/AUX** del amplificador, no la de micrófono.
- Si se oye un zumbido, intercala un **aislador de masa** («ground loop isolator», unos 10 €).
- Con la sesión del usuario del timbre abierta, comprueba en Windows (icono del altavoz) que el **dispositivo de salida predeterminado** es el que va al amplificador, y deja el volumen fijo (p. ej. 80 %). El nivel se regula en el amplificador.

## Que por la megafonía solo suene el timbre

Todo el sonido del PC sale por la megafonía. El instalador silencia Windows para el usuario del timbre
(sonido de inicio, sonidos del sistema, notificaciones de Outlook/Teams/Edge…). Si vuelve a sonar algo,
haz doble clic en **`SILENCIAR_WINDOWS.bat`** con la sesión del usuario del timbre abierta.
No uses ese PC para otras tareas: cualquier vídeo o aviso de otro programa también sonaría en todo el colegio.

## Uso del panel

Ábrelo con el acceso directo del escritorio o, desde otro equipo, con `http://NOMBRE-DEL-PC:8080`.

- **Inicio:** próximo toque y cuenta atrás, botón **Tocar timbre** y **Parar**, interruptor general, horario en uso, estado de la hora y toques de hoy.
- **Horarios:** toques con hora, nombre, días, sonido y repeticiones. Puedes tener varios horarios (normal, jornada reducida…) y cambiar entre ellos con un clic.
- **Días sin timbre:** festivos y vacaciones.
- **Sonidos:** incluye timbre eléctrico, campana y tres tonos. Puedes subir los tuyos (MP3, WAV, OGG, M4A…), varios a la vez.
  **Al subirlos se convierten automáticamente a WAV**, se les quita el silencio del principio para que suenen justo a la hora
  y se igualan de volumen con los demás. Los MP3 que ya estuvieran subidos tienen un botón **Convertir a WAV**,
  que también actualiza los toques que los usaban.
- **Megafonía:** pulsa en **Nubi** (o en el botón «Megafonía» de Inicio), graba el aviso con el micrófono,
  escúchalo y pulsa **Enviar a los altavoces**: suena el tono de aviso y después tu mensaje (1, 2 o 3 veces).
  El micrófono solo funciona entrando por **https://timbre.virtuscollege.com** o desde el propio PC (`localhost`);
  en el registro queda quién envió cada aviso. Se guardan los 30 últimos en `datos\megafonia\`.
- **Idioma y tema:** arriba a la derecha, **EN/ES** cambia el panel entre español e inglés y el botón
  ☾/☀ alterna tema automático (según el dispositivo), claro u oscuro. Se recuerda en cada dispositivo.
  Los nombres de toques y horarios que escribas no se traducen.
- **Registro:** historial de toques y avisos; copia de seguridad (exportar e importar).
- **Nubi**, la mascota: flota en una esquina y se puede arrastrar a cualquier sitio (recuerda dónde la dejas). Púlsala para ver el próximo toque; cuando suena el timbre se pone a saltar. Se oculta desde su bocadillo y se recupera con «Mostrar a Nubi» en el pie de página.

> **El horario y las vacaciones que vienen son de ejemplo.** Cámbialos por los del colegio y pulsa **Guardar cambios**.

## Actualizaciones (sin ir al colegio)

Los cambios se publican en GitHub (`yaseenAlKoja/timbreVirtus`, rama `main`) y el PC del colegio los instala solo:

- **Desde el panel:** pestaña **Registro → Versión y actualizaciones → Buscar actualizaciones → Actualizar ahora**.
  Funciona también desde fuera, por `timbre.virtuscollege.com`.
- **Automáticamente cada noche a las 3:00**, si está activado el interruptor de esa tarjeta (activado por defecto)
  y no hay ningún toque en la media hora siguiente.

Cómo se protege el timbre durante la actualización (`actualizar.py`):
1. Descarga la versión de GitHub y la **prueba aparte** (si tiene errores, no toca nada).
2. Hace **copia de seguridad** de la versión actual en `respaldo\`.
3. Cierra el timbre, copia la versión nueva y lo vuelve a arrancar (unos 2 segundos).
4. Si la versión nueva **no responde en 40 segundos, vuelve sola a la anterior**.

Nunca se tocan `datos\` (horarios, festivos, registro), los sonidos subidos, `python\` ni `cloudflared\`.
El repositorio debe ser **público** para que el PC pueda descargarlo sin contraseñas (no contiene secretos).

## Archivos y mantenimiento

```
C:\TimbreEscolar\
├── INSTALAR.bat / DESINSTALAR.bat
├── timbre.py                 programa
├── web\                      panel (y web\marca\ con el logo de Virtus)
├── sonidos\                  sonidos
├── datos\config.json         horarios y festivos   ← guarda una copia
├── datos\registro.log        historial de toques
├── datos\consola.log         mensajes técnicos
├── actualizar.py             actualizador (botón del panel y comprobación nocturna)
├── respaldo\                 copia de la versión anterior (la crea el actualizador)
├── python\                   Python portátil
├── cloudflared\              túnel de Cloudflare (si se activa el acceso remoto)
└── herramientas\             instalador y diagnóstico
```

- **Actualizar:** descomprime la nueva versión y vuelve a ejecutar `INSTALAR.bat`. Los horarios se conservan.
- **Desinstalar:** `DESINSTALAR.bat`. Quita también el túnel de Cloudflare de este PC y te pregunta si quieres quitar el inicio de sesión automático.
- **Diagnóstico:** `herramientas\diagnostico_con_ventana.bat` arranca el timbre mostrando los mensajes. Si el timbre ya está en marcha, avisa de ello y se cierra: nunca hay dos timbres a la vez.

## Añadir timbres de Pixabay

1. En el navegador, abre por ejemplo https://pixabay.com/sound-effects/search/school-bell/ y pulsa **Descargar** en los que te gusten.
2. En el panel: **Sonidos → Subir sonido** y elige los MP3 descargados (puedes elegir varios a la vez). Se guardan ya convertidos a WAV.
3. Pulsa **Probar en altavoces** y asígnalos a los toques en **Horarios**.

La licencia de Pixabay permite usarlos gratis y sin citar al autor.

## Problemas frecuentes

| Síntoma | Solución |
|---|---|
| Tras un corte de luz el PC sigue apagado | Ajuste de la BIOS (ver arriba) |
| El PC se queda en la pantalla de inicio de sesión | Contraseña cambiada: ejecuta de nuevo `INSTALAR.bat`. Si es una cuenta Microsoft, usa una cuenta local |
| No suena nada | Mira **Registro**. Comprueba el dispositivo de salida y que Windows no esté en silencio |
| Suena por el PC y no por la megafonía | Cambia el dispositivo de salida predeterminado (ver «Conexión») |
| «Reloj desajustado» | Comprueba que el PC tiene Internet; en una ventana de administrador: `w32tm /resync /force` |
| No se abre el panel desde otro PC | Usa la IP del PC (`ipconfig`) y comprueba que está en la misma red |
| Las fuentes no se ven como en la web | Sin Internet el panel usa Arial. Con Internet usa Poppins, o Euclid Circular A si está instalada |

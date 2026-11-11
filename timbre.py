#!/usr/bin/env python3
"""
Timbre Escolar — sistema local de toques de timbre.

Se ejecuta en el ordenador conectado al sistema de sonido del colegio.
Hace sonar el timbre a las horas programadas y ofrece un panel web
(http://<ip-del-equipo>:8080) para gestionar horarios, festivos y sonidos.

Solo usa la biblioteca estándar de Python 3.8+ (no hay que instalar nada).

Uso:
    python3 timbre.py                     # puerto 8080, accesible desde la red local
    python3 timbre.py --puerto 9000
    python3 timbre.py --clave MiClave     # protege el panel con usuario "admin" y esa clave
    python3 timbre.py --solo-local        # el panel solo se abre desde este mismo equipo
"""

import argparse
import array
import base64
import json
import math
import mimetypes
import os
import platform
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
import wave
from collections import deque
from datetime import date, datetime, timedelta
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

BASE = Path(__file__).resolve().parent
DATOS = BASE / "datos"
SONIDOS = BASE / "sonidos"
WEB = BASE / "web"
CONFIG_PATH = DATOS / "config.json"
REGISTRO_PATH = DATOS / "registro.log"
REPO_GITHUB = "yaseenAlKoja/timbreVirtus"

# Identidad Virtus College: se usan los archivos de web/marca/ (los descarga el
# instalador); si no están, el navegador los pide a la web oficial.
MARCA = {
    "logo-positivo.svg": "https://virtuscollege.com/wp-content/uploads/2025/07/Logo-Virtus-College-2025-positivo.svg",
    "logo-negativo.png": "https://virtuscollege.com/wp-content/uploads/2025/06/"
                         "%E2%80%A2Logo-Virtus-College-2025-ok-01-1024x417.png",
    "favicon.png": "https://virtuscollege.com/wp-content/uploads/2025/12/cropped-favicon_virtus_college_of_madrid.png",
}

EXTENSIONES = {".wav", ".mp3", ".ogg", ".flac", ".m4a"}
MAX_SUBIDA = 30 * 1024 * 1024  # 30 MB
HORA_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
FECHA_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
NOMBRE_RE = re.compile(r"^[\w\-. ()áéíóúÁÉÍÓÚñÑüÜ]+$")
DIAS = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]


def log(msg):
    if sys.stdout is None:
        return
    try:
        print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}", flush=True)
    except Exception:  # noqa: BLE001  (consola cerrada, codificación…)
        pass


def redirigir_salida_si_no_hay_consola():
    """Con pythonw.exe (sin ventana) no hay consola: se escribe en datos/consola.log."""
    if sys.stdout is not None and sys.stderr is not None:
        return
    DATOS.mkdir(parents=True, exist_ok=True)
    ruta = DATOS / "consola.log"
    try:
        if ruta.exists() and ruta.stat().st_size > 2 * 1024 * 1024:
            os.replace(ruta, ruta.with_suffix(".log.1"))
    except OSError:
        pass
    f = open(ruta, "a", encoding="utf-8", buffering=1)
    sys.stdout = sys.stderr = f


_cerrojo = None


def una_sola_instancia():
    """Impide que haya dos timbres en marcha a la vez (sonaría todo dos veces)."""
    global _cerrojo
    DATOS.mkdir(parents=True, exist_ok=True)
    _cerrojo = open(DATOS / "timbre.lock", "a+")
    try:
        if platform.system() == "Windows":
            import msvcrt
            _cerrojo.seek(0)
            msvcrt.locking(_cerrojo.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(_cerrojo.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


class Servidor(ThreadingHTTPServer):
    daemon_threads = True
    # En Windows SO_REUSEADDR permitiría a dos programas usar el mismo puerto.
    allow_reuse_address = platform.system() != "Windows"


# --------------------------------------------------------------------------
# Generación de sonidos por defecto (para que funcione sin descargar nada)
# --------------------------------------------------------------------------

RATE = 44100


def _guardar_wav(path, muestras):
    pico = max(1e-9, max(abs(m) for m in muestras))
    escala = 0.89 * 32767 / pico
    datos = array.array("h", (int(m * escala) for m in muestras))
    if sys.byteorder == "big":
        datos.byteswap()
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(datos.tobytes())


def _fundidos(muestras, entrada=0.005, salida=0.05):
    n_in, n_out = int(RATE * entrada), int(RATE * salida)
    total = len(muestras)
    for i in range(min(n_in, total)):
        muestras[i] *= i / n_in
    for i in range(min(n_out, total)):
        muestras[total - 1 - i] *= i / n_out
    return muestras


def _sonido_campana():
    """Campana de bronce: tres golpes con parciales inarmónicos."""
    dur, f0 = 4.5, 660.0
    parciales = [(0.5, 0.35, 2.8), (1.0, 1.0, 2.2), (1.19, 0.55, 1.6), (1.5, 0.4, 1.3),
                 (2.0, 0.45, 1.0), (2.51, 0.25, 0.7), (2.66, 0.2, 0.6), (3.01, 0.15, 0.5)]
    golpes = [0.0, 1.0, 2.0]
    n = int(RATE * dur)
    out = [0.0] * n
    for g in golpes:
        ini = int(g * RATE)
        for ratio, amp, tau in parciales:
            w = 2 * math.pi * f0 * ratio / RATE
            k = -1.0 / (tau * RATE)
            for i in range(n - ini):
                out[ini + i] += amp * math.exp(k * i) * math.sin(w * i)
    return _fundidos(out)


def _sonido_timbre_electrico():
    """Timbre eléctrico clásico de colegio (martillo golpeando una campana)."""
    dur = 3.5
    n = int(RATE * dur)
    golpes_seg = 24.0
    parciales = [(1.0, 1.0), (2.32, 0.45), (4.25, 0.25), (6.8, 0.12)]
    f0 = 1180.0
    out = [0.0] * n
    periodo = RATE / golpes_seg
    for i in range(n):
        t = i / RATE
        fase = (i % periodo) / periodo
        golpe = 0.55 + 0.45 * math.exp(-fase * 6.0)
        s = 0.0
        for ratio, amp in parciales:
            s += amp * math.sin(2 * math.pi * f0 * ratio * t)
        out[i] = s * golpe
    # cola de resonancia al soltar
    cola = int(RATE * 0.6)
    for i in range(cola):
        out[n - cola + i] *= math.exp(-i / (RATE * 0.12))
    return _fundidos(out, 0.003, 0.02)


def _sonido_tres_tonos():
    """Aviso de tres tonos ascendentes (tipo megafonía)."""
    notas = [(523.25, 0.0), (659.25, 0.55), (783.99, 1.1)]
    dur = 3.4
    n = int(RATE * dur)
    out = [0.0] * n
    for f, ini_s in notas:
        ini = int(ini_s * RATE)
        for i in range(n - ini):
            t = i / RATE
            env = math.exp(-t / 0.9) * min(1.0, t / 0.008)
            out[ini + i] += env * (math.sin(2 * math.pi * f * t)
                                   + 0.3 * math.sin(2 * math.pi * 2 * f * t)
                                   + 0.08 * math.sin(2 * math.pi * 3 * f * t))
    return _fundidos(out)


SONIDOS_POR_DEFECTO = {
    "timbre_electrico.wav": _sonido_timbre_electrico,
    "campana.wav": _sonido_campana,
    "tres_tonos.wav": _sonido_tres_tonos,
}


def crear_sonidos_por_defecto():
    SONIDOS.mkdir(parents=True, exist_ok=True)
    for nombre, generador in SONIDOS_POR_DEFECTO.items():
        destino = SONIDOS / nombre
        if not destino.exists():
            log(f"Generando sonido por defecto: {nombre}")
            _guardar_wav(destino, generador())


def duracion_wav(path):
    try:
        with wave.open(str(path), "rb") as w:
            return w.getnframes() / float(w.getframerate())
    except Exception:
        return None


# --------------------------------------------------------------------------
# Reproducción de audio (multiplataforma, sin dependencias)
# --------------------------------------------------------------------------

class Reproductor:
    def __init__(self, al_error):
        self.sistema = platform.system()
        self.al_error = al_error
        self._parar = threading.Event()
        self._hilo = None
        self._lock = threading.Lock()
        self.sonando = None

    def _comandos(self, path):
        """Lista de comandos candidatos, en orden de preferencia."""
        ext = path.suffix.lower()
        p = str(path)
        ffplay = ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", p]
        if self.sistema == "Darwin":
            candidatos = [["afplay", p], ffplay]
        elif self.sistema == "Windows":
            ruta = p.replace("'", "''")
            script = (
                "Add-Type -AssemblyName presentationCore;"
                "$p=New-Object System.Windows.Media.MediaPlayer;"
                f"$p.Open([uri]'{ruta}');$p.Play();"
                "$i=0;while(-not $p.NaturalDuration.HasTimeSpan -and $i -lt 50){Start-Sleep -Milliseconds 100;$i++};"
                "if($p.NaturalDuration.HasTimeSpan){Start-Sleep -Milliseconds ([int]$p.NaturalDuration.TimeSpan.TotalMilliseconds)};"
                "$p.Close()"
            )
            candidatos = [ffplay, ["powershell", "-NoProfile", "-NonInteractive", "-Command", script]]
        else:  # Linux / Raspberry Pi
            candidatos = []
            if ext == ".wav":
                candidatos += [["paplay", p], ["pw-play", p], ["aplay", "-q", p]]
            candidatos += [ffplay, ["mpv", "--no-video", "--really-quiet", p],
                           ["cvlc", "--play-and-exit", "--quiet", p]]
            if ext == ".mp3":
                candidatos.append(["mpg123", "-q", p])
            if ext in (".ogg", ".flac"):
                candidatos.append(["paplay", p])
        return [c for c in candidatos if shutil.which(c[0])]

    def descripcion(self):
        if self.sistema == "Windows":
            return "Windows (WAV nativo" + (", resto con ffplay)" if shutil.which("ffplay") else ", MP3 vía Windows Media)")
        if self.sistema == "Darwin":
            return "macOS (afplay)"
        wav = [c[0] for c in self._comandos(Path("x.wav"))]
        mp3 = [c[0] for c in self._comandos(Path("x.mp3"))]
        if not wav:
            return "Linux — ⚠ no se encontró reproductor (instala alsa-utils o ffmpeg)"
        return f"Linux (WAV: {'/'.join(wav)}; MP3: {'/'.join(mp3) or 'no disponible'})"

    def tocar(self, path, repeticiones=1, etiqueta=""):
        self.parar()
        evento = threading.Event()
        with self._lock:
            self._parar = evento
            self._hilo = threading.Thread(target=self._ejecutar, args=(path, repeticiones, evento, etiqueta),
                                          daemon=True)
            self._hilo.start()

    def parar(self):
        with self._lock:
            self._parar.set()
            hilo = self._hilo
        if hilo and hilo.is_alive() and hilo is not threading.current_thread():
            hilo.join(timeout=3)

    def _ejecutar(self, path, repeticiones, evento, etiqueta):
        self.sonando = etiqueta or path.name
        try:
            for i in range(repeticiones):
                if evento.is_set():
                    break
                self._una_vez(path, evento)
                if i < repeticiones - 1:
                    evento.wait(0.5)
        except Exception as e:  # noqa: BLE001
            self.al_error(f"Error al reproducir {path.name}: {e}")
        finally:
            if self._parar is evento:
                self.sonando = None

    def _una_vez(self, path, evento):
        if self.sistema == "Windows" and path.suffix.lower() == ".wav":
            import winsound  # solo existe en Windows
            winsound.PlaySound(str(path), winsound.SND_FILENAME | winsound.SND_ASYNC)
            if evento.wait((duracion_wav(path) or 5) + 0.1):
                winsound.PlaySound(None, 0)
            return
        comandos = self._comandos(path)
        if not comandos:
            raise RuntimeError("no hay ningún reproductor de audio disponible en este equipo")
        flags = {}
        if self.sistema == "Windows":
            flags["creationflags"] = 0x08000000  # CREATE_NO_WINDOW
        errores = []
        for cmd in comandos:  # si un reproductor falla, se prueba el siguiente
            try:
                proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **flags)
            except OSError as e:
                errores.append(f"{cmd[0]}: {e}")
                continue
            while proc.poll() is None:
                if evento.wait(0.1):
                    proc.terminate()
                    try:
                        proc.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                    return
            if proc.returncode == 0:
                return
            errores.append(f"{cmd[0]} (código {proc.returncode})")
        raise RuntimeError("ningún reproductor funcionó: " + ", ".join(errores))


# --------------------------------------------------------------------------
# Hora del sistema
# --------------------------------------------------------------------------

SERVIDORES_HORA = ["hora.roa.es", "es.pool.ntp.org", "time.windows.com", "pool.ntp.org"]
MAX_DESFASE = 5  # segundos


def consultar_ntp(servidor, espera=3.0):
    """Devuelve cuántos segundos hay que sumar al reloj del PC para estar en hora (SNTP)."""
    import socket
    import struct
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(espera)
        t1 = time.time()
        s.sendto(b"\x1b" + 47 * b"\0", (servidor, 123))
        datos, _ = s.recvfrom(512)
        t4 = time.time()
    if len(datos) < 48 or datos[1] == 0:
        raise ValueError("respuesta NTP no válida")

    def marca(off):
        seg, frac = struct.unpack("!II", datos[off:off + 8])
        return seg - 2208988800 + frac / 2 ** 32

    t2, t3 = marca(32), marca(40)
    return ((t2 - t1) + (t3 - t4)) / 2


def resincronizar_reloj():
    """Pide a Windows que sincronice ya la hora (funciona si el instalador dio permiso)."""
    if platform.system() != "Windows":
        return
    for cmd in (["schtasks", "/Run", "/TN", "Timbre Escolar - Sincronizar hora"],
                ["w32tm", "/resync", "/nowait"]):
        try:
            r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=20, creationflags=0x08000000)
            if r.returncode == 0:
                return
        except Exception:  # noqa: BLE001
            pass


def zona_horaria():
    ahora = datetime.now().astimezone()
    off = ahora.utcoffset() or timedelta(0)
    minutos = int(off.total_seconds() // 60)
    signo = "+" if minutos >= 0 else "-"
    return f"{ahora.tzname()} (UTC{signo}{abs(minutos) // 60:02d}:{abs(minutos) % 60:02d})"


# --------------------------------------------------------------------------
# Configuración
# --------------------------------------------------------------------------

def _id():
    return uuid.uuid4().hex[:10]


def config_por_defecto():
    lv = [0, 1, 2, 3, 4]
    def ev(hora, nombre, sonido="timbre_electrico.wav", rep=1):
        return {"id": _id(), "hora": hora, "nombre": nombre, "dias": lv,
                "sonido": sonido, "repeticiones": rep, "activo": True}
    normal = [
        ev("08:30", "Entrada", "campana.wav"),
        ev("09:25", "Fin 1ª hora"),
        ev("10:20", "Fin 2ª hora"),
        ev("11:15", "Inicio recreo", "tres_tonos.wav"),
        ev("11:45", "Fin recreo", "campana.wav"),
        ev("12:40", "Fin 4ª hora"),
        ev("13:35", "Fin 5ª hora"),
        ev("14:30", "Salida", "timbre_electrico.wav", 2),
    ]
    reducida = [
        ev("09:00", "Entrada", "campana.wav"),
        ev("09:50", "Fin 1ª hora"),
        ev("10:40", "Fin 2ª hora"),
        ev("11:30", "Inicio recreo", "tres_tonos.wav"),
        ev("12:00", "Fin recreo", "campana.wav"),
        ev("12:50", "Fin 4ª hora"),
        ev("13:40", "Salida", "timbre_electrico.wav", 2),
    ]
    return {
        "version": 1,
        "activo": True,
        "horario_activo": "normal",
        "horarios": {
            "normal": {"nombre": "Horario normal", "toques": normal},
            "reducido": {"nombre": "Jornada reducida (junio/septiembre)", "toques": reducida},
        },
        "dias_sin_timbre": [
            {"id": _id(), "desde": "2026-12-23", "hasta": "2027-01-07",
             "motivo": "Vacaciones de Navidad (ejemplo, revisa las fechas)"},
        ],
    }


class ErrorValidacion(ValueError):
    pass


def validar_config(c):
    if not isinstance(c, dict):
        raise ErrorValidacion("Configuración no válida")
    horarios = c.get("horarios")
    if not isinstance(horarios, dict) or not horarios:
        raise ErrorValidacion("Debe existir al menos un horario")
    limpio = {"version": 1, "activo": bool(c.get("activo", True)), "horarios": {}, "dias_sin_timbre": [],
              "actualizar_automaticamente": bool(c.get("actualizar_automaticamente", True))}
    for hid, h in horarios.items():
        if not re.match(r"^[\w\-]{1,40}$", str(hid)):
            raise ErrorValidacion(f"Identificador de horario no válido: {hid}")
        nombre = str(h.get("nombre", "")).strip()[:80] or hid
        toques = []
        for t in h.get("toques", []):
            hora = str(t.get("hora", ""))
            if not HORA_RE.match(hora):
                raise ErrorValidacion(f"Hora no válida «{hora}» en «{nombre}» (formato HH:MM)")
            dias = sorted({int(d) for d in t.get("dias", []) if str(d).isdigit() and 0 <= int(d) <= 6})
            sonido = Path(str(t.get("sonido", ""))).name
            try:
                rep = max(1, min(10, int(t.get("repeticiones", 1))))
            except (TypeError, ValueError):
                rep = 1
            toques.append({
                "id": str(t.get("id") or _id())[:20],
                "hora": hora,
                "nombre": str(t.get("nombre", "")).strip()[:80],
                "dias": dias,
                "sonido": sonido,
                "repeticiones": rep,
                "activo": bool(t.get("activo", True)),
            })
        toques.sort(key=lambda x: x["hora"])
        limpio["horarios"][hid] = {"nombre": nombre, "toques": toques}
    activo = c.get("horario_activo")
    limpio["horario_activo"] = activo if activo in limpio["horarios"] else next(iter(limpio["horarios"]))
    for d in c.get("dias_sin_timbre", []):
        desde, hasta = str(d.get("desde", "")), str(d.get("hasta", "") or d.get("desde", ""))
        if not (FECHA_RE.match(desde) and FECHA_RE.match(hasta)):
            raise ErrorValidacion("Fecha no válida en días sin timbre (formato AAAA-MM-DD)")
        try:
            date.fromisoformat(desde), date.fromisoformat(hasta)
        except ValueError:
            raise ErrorValidacion(f"Fecha inexistente: {desde} / {hasta}") from None
        if hasta < desde:
            desde, hasta = hasta, desde
        limpio["dias_sin_timbre"].append({"id": str(d.get("id") or _id())[:20], "desde": desde,
                                          "hasta": hasta, "motivo": str(d.get("motivo", "")).strip()[:120]})
    limpio["dias_sin_timbre"].sort(key=lambda x: x["desde"])
    return limpio


# --------------------------------------------------------------------------
# Núcleo de la aplicación
# --------------------------------------------------------------------------

class Timbre:
    def __init__(self):
        DATOS.mkdir(parents=True, exist_ok=True)
        crear_sonidos_por_defecto()
        self.lock = threading.RLock()
        self.registro = deque(maxlen=100)
        self.reproductor = Reproductor(self._error)
        self.config = self._cargar()
        self.inicio = datetime.now()
        self.hora = None

    # ----- persistencia
    def _cargar(self):
        if CONFIG_PATH.exists():
            try:
                return validar_config(json.loads(CONFIG_PATH.read_text(encoding="utf-8")))
            except Exception as e:  # noqa: BLE001
                copia = CONFIG_PATH.with_suffix(f".corrupto-{int(time.time())}.json")
                shutil.copy2(CONFIG_PATH, copia)
                log(f"⚠ config.json no válido ({e}); copia guardada en {copia.name}. Se usa la configuración por defecto.")
        cfg = config_por_defecto()
        self._escribir(cfg)
        return cfg

    def _escribir(self, cfg):
        tmp = CONFIG_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, CONFIG_PATH)

    def guardar_config(self, nueva):
        cfg = validar_config(nueva)
        with self.lock:
            self._escribir(cfg)
            self.config = cfg
        self._anotar("config", "Configuración guardada")
        return cfg

    # ----- registro
    def _anotar(self, tipo, texto):
        entrada = {"fecha": datetime.now().isoformat(timespec="seconds"), "tipo": tipo, "texto": texto}
        with self.lock:
            self.registro.appendleft(entrada)
        log(texto)
        try:
            with REGISTRO_PATH.open("a", encoding="utf-8") as f:
                f.write(f"{entrada['fecha']}\t{tipo}\t{texto}\n")
        except OSError:
            pass

    def _error(self, texto):
        self._anotar("error", texto)

    # ----- calendario
    def motivo_sin_timbre(self, dia, cfg=None):
        cfg = cfg or self.config
        iso = dia.isoformat()
        for d in cfg["dias_sin_timbre"]:
            if d["desde"] <= iso <= d["hasta"]:
                return d["motivo"] or "Día sin timbre"
        return None

    def toques_del_dia(self, dia, cfg=None):
        cfg = cfg or self.config
        horario = cfg["horarios"][cfg["horario_activo"]]
        return [t for t in horario["toques"] if t["activo"] and dia.weekday() in t["dias"]]

    def toques_pendientes(self, desde, hasta):
        """Toques cuya hora cae en el intervalo (desde, hasta]."""
        with self.lock:
            cfg = self.config
        if not cfg["activo"]:
            return []
        resultado = []
        dia = desde.date()
        while dia <= hasta.date():
            if not self.motivo_sin_timbre(dia, cfg):
                for t in self.toques_del_dia(dia, cfg):
                    h, m = map(int, t["hora"].split(":"))
                    momento = datetime(dia.year, dia.month, dia.day, h, m)
                    if desde < momento <= hasta:
                        resultado.append((momento, t))
            dia += timedelta(days=1)
        return resultado

    def proximos(self, n=3):
        ahora = datetime.now()
        with self.lock:
            cfg = self.config
        if not cfg["activo"]:
            return []
        res = []
        for delta in range(0, 60):
            dia = ahora.date() + timedelta(days=delta)
            if self.motivo_sin_timbre(dia, cfg):
                continue
            for t in self.toques_del_dia(dia, cfg):
                h, m = map(int, t["hora"].split(":"))
                momento = datetime(dia.year, dia.month, dia.day, h, m)
                if momento > ahora:
                    res.append({**t, "momento": momento.isoformat(timespec="seconds")})
                    if len(res) >= n:
                        return res
        return res

    # ----- sonar
    def sonar(self, sonido, repeticiones=1, etiqueta="", origen="manual"):
        nombre = Path(sonido).name
        path = SONIDOS / nombre
        if not path.is_file():
            self._error(f"No se encuentra el sonido «{nombre}» ({etiqueta or origen})")
            return False
        texto = f"🔔 {etiqueta or 'Toque'} — {nombre}" + (f" ×{repeticiones}" if repeticiones > 1 else "")
        self._anotar(origen, texto + ("" if origen == "programado" else f" ({origen})"))
        self.reproductor.tocar(path, repeticiones, etiqueta or nombre)
        return True

    def parar(self):
        self.reproductor.parar()
        self._anotar("manual", "⏹ Reproducción detenida")

    # ----- planificador
    def bucle_planificador(self):
        """Comprueba el reloj del sistema dos veces por segundo.

        Sigue siempre la hora local del ordenador. Si Windows corrige la hora
        unos segundos (sincronización NTP) no se pierde ni se repite ningún toque;
        si el reloj salta mucho (equipo suspendido, cambio manual, cambio de
        horario verano/invierno) no se tocan en cadena los toques atrasados.
        """
        anterior = datetime.now()
        disparados = {}  # "fecha hora|id" -> momento, para no tocar dos veces el mismo toque
        while True:
            time.sleep(0.5)
            if (DATOS / "salir.flag").exists():
                self._anotar("sistema", "Cerrando para instalar una actualización")
                self.reproductor.parar()
                os._exit(0)
            try:
                ahora = datetime.now()
                salto = (ahora - anterior).total_seconds()
                if salto > 120 or salto < -2:
                    self._anotar("aviso", f"Cambio de hora del sistema detectado ({salto:+.0f} s); "
                                          "no se tocan los toques intermedios")
                    anterior = ahora
                    continue
                if salto <= 0:
                    anterior = min(anterior, ahora)
                    continue
                for momento, t in self.toques_pendientes(anterior, ahora):
                    clave = f"{momento:%Y-%m-%d %H:%M}|{t['id']}"
                    if clave in disparados:
                        continue
                    disparados[clave] = momento
                    self.sonar(t["sonido"], t["repeticiones"], t["nombre"] or t["hora"], "programado")
                if len(disparados) > 300:
                    limite = ahora - timedelta(days=1)
                    disparados = {k: v for k, v in disparados.items() if v > limite}
                anterior = ahora
            except Exception as e:  # noqa: BLE001  el planificador nunca debe morir
                self._error(f"Error en el planificador: {e!r}")
                anterior = datetime.now()

    # ----- comprobación de la hora
    def bucle_hora(self):
        """Compara el reloj del PC con servidores de hora oficiales cada 30 min."""
        time.sleep(20)
        while True:
            self.comprobar_hora()
            time.sleep(30 * 60)

    def comprobar_hora(self):
        resultado = {"comprobado": datetime.now().isoformat(timespec="seconds"), "ok": None,
                     "desfase": None, "servidor": None}
        for servidor in SERVIDORES_HORA:
            try:
                resultado["desfase"] = round(consultar_ntp(servidor), 3)
                resultado["servidor"] = servidor
                break
            except Exception:  # noqa: BLE001
                continue
        anterior = self.hora
        if resultado["desfase"] is None:
            resultado["ok"] = None  # sin conexión: no se puede comprobar
        else:
            resultado["ok"] = abs(resultado["desfase"]) <= MAX_DESFASE
            if not resultado["ok"]:
                self._anotar("aviso", f"⚠ El reloj del PC va {abs(resultado['desfase']):.0f} s "
                                      f"{'atrasado' if resultado['desfase'] > 0 else 'adelantado'} "
                                      f"respecto a {resultado['servidor']}. Intentando resincronizar…")
                resincronizar_reloj()
            elif anterior and anterior.get("ok") is False:
                self._anotar("sistema", "✓ El reloj del PC vuelve a estar en hora")
        self.hora = resultado
        return resultado

    # ----- versiones y actualizaciones
    @staticmethod
    def version_instalada():
        try:
            return json.loads((DATOS / "version.json").read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            return {"sha": "", "mensaje": "", "fecha_commit": "", "instalada": ""}

    @staticmethod
    def ultima_actualizacion():
        try:
            return json.loads((DATOS / "actualizacion.json").read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            return None

    def version_disponible(self, forzar=False):
        """Última versión publicada en GitHub (se consulta como mucho cada 5 minutos)."""
        import urllib.request
        cache = getattr(self, "_cache_github", None)
        if cache and not forzar and time.time() - cache[0] < 300:
            return cache[1]
        req = urllib.request.Request(f"https://api.github.com/repos/{REPO_GITHUB}/commits/main",
                                     headers={"User-Agent": "TimbreEscolar", "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=15) as r:
            d = json.loads(r.read())
        info = {"sha": d["sha"], "mensaje": d["commit"]["message"].splitlines()[0][:150],
                "fecha_commit": d["commit"]["committer"]["date"]}
        self._cache_github = (time.time(), info)
        return info

    def comprobar_actualizacion(self, forzar=False):
        instalada = self.version_instalada()
        try:
            disponible = self.version_disponible(forzar)
        except Exception as e:  # noqa: BLE001
            return {"instalada": instalada, "disponible": None, "hay_nueva": False,
                    "error": f"No se pudo consultar GitHub: {e}"}
        return {"instalada": instalada, "disponible": disponible, "error": None,
                "hay_nueva": disponible["sha"] != instalada.get("sha")}

    def iniciar_actualizacion(self, info):
        act = self.ultima_actualizacion()
        if act and act.get("estado") == "en_curso":
            try:
                if (datetime.now() - datetime.fromisoformat(act["fecha"])).total_seconds() < 300:
                    raise ErrorValidacion("Ya hay una actualización en curso")
            except (KeyError, ValueError):
                pass
        exe = sys.executable
        if platform.system() == "Windows" and exe.lower().endswith("python.exe"):
            w = Path(exe).with_name("pythonw.exe")
            exe = str(w) if w.exists() else exe
        cmd = [exe, str(BASE / "actualizar.py"), "--sha", info["sha"], "--mensaje", info.get("mensaje", ""),
               "--fecha-commit", info.get("fecha_commit", ""), "--", *sys.argv[1:]]
        opciones = {"cwd": str(BASE), "stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL,
                    "stderr": subprocess.DEVNULL}
        if platform.system() == "Windows":
            opciones["creationflags"] = 0x00000008 | 0x00000200 | 0x08000000
        else:
            opciones["start_new_session"] = True
        subprocess.Popen(cmd, **opciones)
        self._anotar("sistema", f"Buscando e instalando la versión {info['sha'][:7]}…")

    def bucle_actualizacion(self):
        """Cada noche, a las 3:00, instala la última versión si hay una nueva y está activado."""
        ultima_noche = None
        while True:
            time.sleep(600)
            try:
                ahora = datetime.now()
                if not (self.config.get("actualizar_automaticamente", True) and ahora.hour == 3):
                    continue
                if ultima_noche == ahora.date():
                    continue
                ultima_noche = ahora.date()
                if self.toques_pendientes(ahora, ahora + timedelta(minutes=30)):
                    continue  # nunca justo antes de un toque
                r = self.comprobar_actualizacion(forzar=True)
                if r["hay_nueva"]:
                    self._anotar("sistema", "Actualización automática nocturna")
                    self.iniciar_actualizacion(r["disponible"])
            except Exception as e:  # noqa: BLE001
                self._error(f"Comprobación de actualizaciones: {e}")

    # ----- estado para el panel
    def estado(self):
        with self.lock:
            cfg = json.loads(json.dumps(self.config))
            registro = list(self.registro)
        hoy = date.today()
        sonidos = []
        for p in sorted(SONIDOS.iterdir(), key=lambda x: x.name.lower()):
            if p.is_file() and p.suffix.lower() in EXTENSIONES:
                sonidos.append({"nombre": p.name, "tamano": p.stat().st_size,
                                "duracion": duracion_wav(p) if p.suffix.lower() == ".wav" else None,
                                "por_defecto": p.name in SONIDOS_POR_DEFECTO})
        return {
            "ahora": datetime.now().isoformat(timespec="milliseconds"),
            "config": cfg,
            "hoy": {"fecha": hoy.isoformat(), "dia_semana": hoy.weekday(),
                    "sin_timbre": self.motivo_sin_timbre(hoy, cfg),
                    "toques": self.toques_del_dia(hoy, cfg)},
            "proximos": self.proximos(3),
            "sonando": self.reproductor.sonando,
            "sonidos": sonidos,
            "registro": registro[:50],
            "hora": self.hora,
            "version": self.version_instalada(),
            "actualizacion": self.ultima_actualizacion(),
            "zona_horaria": zona_horaria(),
            "sistema": {"audio": self.reproductor.descripcion(), "equipo": platform.node(),
                        "so": f"{platform.system()} {platform.release()}",
                        "inicio": self.inicio.isoformat(timespec="seconds")},
        }


# --------------------------------------------------------------------------
# Servidor web
# --------------------------------------------------------------------------

def crear_manejador(app, clave):
    token = base64.b64encode(f"admin:{clave}".encode()).decode() if clave else None

    class Manejador(BaseHTTPRequestHandler):
        server_version = "TimbreEscolar/1.0"

        def log_message(self, *args):
            pass

        def _autorizado(self):
            if not token:
                return True
            if self.headers.get("Authorization", "") == f"Basic {token}":
                return True
            self.send_response(HTTPStatus.UNAUTHORIZED)
            self.send_header("WWW-Authenticate", 'Basic realm="Timbre Escolar"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False

        def _json(self, datos, codigo=200):
            cuerpo = json.dumps(datos, ensure_ascii=False).encode("utf-8")
            self.send_response(codigo)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(cuerpo)))
            self.end_headers()
            self.wfile.write(cuerpo)

        def _archivo(self, path, tipo=None):
            if not path.is_file():
                return self._json({"error": "No encontrado"}, 404)
            datos = path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", tipo or mimetypes.guess_type(path.name)[0] or "application/octet-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(datos)))
            self.end_headers()
            self.wfile.write(datos)

        def _cuerpo(self, limite=1024 * 1024):
            n = int(self.headers.get("Content-Length") or 0)
            if n > limite:
                raise ErrorValidacion("Archivo demasiado grande")
            return self.rfile.read(n) if n else b""

        def _cuerpo_json(self):
            try:
                return json.loads(self._cuerpo() or b"{}")
            except json.JSONDecodeError:
                raise ErrorValidacion("JSON no válido") from None

        def _nombre_sonido(self, crudo):
            nombre = Path(unquote(crudo)).name.strip()
            if not nombre or not NOMBRE_RE.match(nombre) or Path(nombre).suffix.lower() not in EXTENSIONES:
                raise ErrorValidacion("Nombre de archivo no válido (formatos: " + ", ".join(sorted(EXTENSIONES)) + ")")
            return nombre

        def _despachar(self, metodo):
            if not self._autorizado():
                return
            ruta = urlparse(self.path).path
            try:
                if metodo == "GET":
                    if ruta in ("/", "/index.html"):
                        return self._archivo(WEB / "index.html", "text/html; charset=utf-8")
                    if ruta == "/api/estado":
                        return self._json(app.estado())
                    if ruta == "/api/version":
                        return self._json(app.version_instalada())
                    if ruta == "/api/actualizacion":
                        return self._json(app.comprobar_actualizacion(forzar=True))
                    if ruta == "/api/exportar":
                        cuerpo = json.dumps(app.config, ensure_ascii=False, indent=2).encode("utf-8")
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json; charset=utf-8")
                        self.send_header("Content-Disposition",
                                         f'attachment; filename="timbre-config-{date.today()}.json"')
                        self.send_header("Content-Length", str(len(cuerpo)))
                        self.end_headers()
                        return self.wfile.write(cuerpo)
                    if ruta.startswith("/marca/"):
                        nombre = Path(unquote(ruta[len("/marca/"):])).name
                        if nombre not in MARCA:
                            return self._json({"error": "No encontrado"}, 404)
                        local = WEB / "marca" / nombre
                        if local.is_file():
                            return self._archivo(local)
                        self.send_response(302)
                        self.send_header("Location", MARCA[nombre])
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    if ruta.startswith("/sonidos/"):
                        return self._archivo(SONIDOS / self._nombre_sonido(ruta[len("/sonidos/"):]))
                elif metodo == "PUT" and ruta == "/api/config":
                    cfg = app.guardar_config(self._cuerpo_json())
                    return self._json({"ok": True, "config": cfg})
                elif metodo == "POST":
                    if ruta == "/api/tocar":
                        d = self._cuerpo_json()
                        rep = max(1, min(10, int(d.get("repeticiones", 1))))
                        ok = app.sonar(str(d.get("sonido", "")), rep, str(d.get("etiqueta", ""))[:80] or "Toque manual",
                                       "manual")
                        return self._json({"ok": ok}, 200 if ok else 404)
                    if ruta == "/api/actualizar":
                        r = app.comprobar_actualizacion(forzar=True)
                        if r["error"]:
                            raise ErrorValidacion(r["error"])
                        if not r["hay_nueva"]:
                            return self._json({"ok": False, "mensaje": "Ya tienes la última versión"})
                        app.iniciar_actualizacion(r["disponible"])
                        return self._json({"ok": True, "sha": r["disponible"]["sha"]})
                    if ruta == "/api/parar":
                        app.parar()
                        return self._json({"ok": True})
                    if ruta.startswith("/api/sonidos/"):
                        nombre = self._nombre_sonido(ruta[len("/api/sonidos/"):])
                        datos = self._cuerpo(MAX_SUBIDA)
                        if len(datos) < 100:
                            raise ErrorValidacion("El archivo está vacío")
                        destino = SONIDOS / nombre
                        tmp = destino.with_suffix(destino.suffix + ".subiendo")
                        tmp.write_bytes(datos)
                        os.replace(tmp, destino)
                        app._anotar("config", f"Sonido subido: {nombre}")
                        return self._json({"ok": True, "nombre": nombre})
                elif metodo == "DELETE" and ruta.startswith("/api/sonidos/"):
                    nombre = self._nombre_sonido(ruta[len("/api/sonidos/"):])
                    en_uso = [f"{h['nombre']} {t['hora']}" for h in app.config["horarios"].values()
                              for t in h["toques"] if t["sonido"] == nombre]
                    if en_uso:
                        raise ErrorValidacion("El sonido está en uso: " + ", ".join(en_uso[:5]))
                    (SONIDOS / nombre).unlink(missing_ok=True)
                    app._anotar("config", f"Sonido eliminado: {nombre}")
                    return self._json({"ok": True})
                return self._json({"error": "No encontrado"}, 404)
            except ErrorValidacion as e:
                return self._json({"error": str(e)}, 400)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as e:  # noqa: BLE001
                log(f"Error en {metodo} {ruta}: {e!r}")
                return self._json({"error": f"Error interno: {e}"}, 500)

        def do_GET(self):
            self._despachar("GET")

        def do_POST(self):
            self._despachar("POST")

        def do_PUT(self):
            self._despachar("PUT")

        def do_DELETE(self):
            self._despachar("DELETE")

    return Manejador


def ips_locales():
    ips = set()
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ips.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    return sorted(ips)


def main():
    ap = argparse.ArgumentParser(description="Timbre escolar local con panel web")
    ap.add_argument("--puerto", type=int, default=int(os.environ.get("TIMBRE_PUERTO", 8080)))
    ap.add_argument("--clave", default=os.environ.get("TIMBRE_CLAVE", ""),
                    help='protege el panel (usuario "admin")')
    ap.add_argument("--solo-local", action="store_true", help="panel accesible solo desde este equipo")
    ap.add_argument("--probar", metavar="SONIDO", help="reproduce un sonido y sale (prueba de altavoces)")
    args = ap.parse_args()

    redirigir_salida_si_no_hay_consola()
    app = Timbre()

    if args.probar:
        app.sonar(args.probar, 1, "Prueba", "prueba")
        time.sleep(0.3)
        hilo = app.reproductor._hilo
        if hilo:
            hilo.join()
        return

    if not una_sola_instancia():
        log("El timbre ya está en marcha en este equipo (no se inicia otra copia).")
        sys.exit(0)

    host = "127.0.0.1" if args.solo_local else "0.0.0.0"
    servidor = None
    for intento in range(30):  # al arrancar Windows la red puede tardar un poco
        try:
            servidor = Servidor((host, args.puerto), crear_manejador(app, args.clave))
            break
        except OSError as e:
            log(f"No se puede abrir el puerto {args.puerto} ({e}); reintentando…")
            time.sleep(2)
    (DATOS / "salir.flag").unlink(missing_ok=True)  # aviso de cierre antiguo, si quedó alguno
    threading.Thread(target=app.bucle_planificador, daemon=True, name="planificador").start()
    threading.Thread(target=app.bucle_hora, daemon=True, name="hora").start()
    threading.Thread(target=app.bucle_actualizacion, daemon=True, name="actualizacion").start()
    if servidor is None:
        app._error(f"No se pudo abrir el panel web en el puerto {args.puerto}; el timbre sigue funcionando")
        while True:
            time.sleep(3600)
    cfg = app.config
    log("=" * 60)
    log("Timbre Escolar en marcha")
    log(f"Horario activo: {cfg['horarios'][cfg['horario_activo']]['nombre']}")
    log(f"Audio: {app.reproductor.descripcion()}")
    log(f"Hora del sistema: {datetime.now():%d/%m/%Y %H:%M:%S}, zona {zona_horaria()}")
    log(f"Panel: http://localhost:{args.puerto}")
    if not args.solo_local:
        for ip in ips_locales():
            log(f"       http://{ip}:{args.puerto}  (desde otros equipos de la red)")
    if args.clave:
        log('Panel protegido: usuario "admin"')
    prox = app.proximos(1)
    if prox:
        log(f"Próximo toque: {prox[0]['momento'].replace('T', ' ')} — {prox[0]['nombre']}")
    log("Pulsa Ctrl+C para detener")
    log("=" * 60)
    app._anotar("sistema", "Servicio iniciado")
    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        log("Deteniendo…")
        app.reproductor.parar()


if __name__ == "__main__":
    main()

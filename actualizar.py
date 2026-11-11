#!/usr/bin/env python3
"""
Actualizador del Timbre Escolar.

Lo lanza timbre.py (botón «Actualizar» del panel o comprobación nocturna). Pasos:
  1. Descarga de GitHub la versión indicada (ZIP público, sin tokens).
  2. La prueba en una carpeta aparte: compila el código e importa el programa.
  3. Hace copia de seguridad de la versión actual en respaldo/.
  4. Pide al timbre en marcha que se cierre, copia la versión nueva y lo vuelve a arrancar.
  5. Si el timbre nuevo no responde en 40 s, restaura la copia y arranca la versión anterior.

Nunca toca datos/ (horarios, festivos, registro), python/, cloudflared/ ni los sonidos subidos.
Solo usa la biblioteca estándar de Python.

Uso (lo hace timbre.py):  pythonw actualizar.py --sha <commit> -- <argumentos con los que corre el timbre>
Pruebas:                  python actualizar.py --zip archivo.zip --sha prueba -- --puerto 8090
"""

import argparse
import base64
import io
import json
import os
import platform
import py_compile
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from datetime import datetime
from pathlib import Path

BASE = Path(__file__).resolve().parent
DATOS = BASE / "datos"
RESPALDO = BASE / "respaldo"
REPO = "yaseenAlKoja/timbreVirtus"
# Lo que se actualiza. Todo lo demás (datos, python, cloudflared, sonidos subidos, logo) se conserva.
ACTUALIZABLE = ["timbre.py", "actualizar.py", "web/index.html", "README.md", "INSTALAR.bat", "DESINSTALAR.bat",
                "CONECTAR_CLOUDFLARE.bat", "COMPROBAR_ESTADO.bat", "SILENCIAR_WINDOWS.bat", "herramientas", "sonidos/campana.wav",
                "sonidos/timbre_electrico.wav", "sonidos/tres_tonos.wav"]
ES_WINDOWS = platform.system() == "Windows"


def anotar(texto, tipo="sistema"):
    linea = f"{datetime.now().isoformat(timespec='seconds')}\t{tipo}\t{texto}\n"
    try:
        DATOS.mkdir(parents=True, exist_ok=True)
        with (DATOS / "registro.log").open("a", encoding="utf-8") as f:
            f.write(linea)
        with (DATOS / "actualizacion.log").open("a", encoding="utf-8") as f:
            f.write(linea)
    except OSError:
        pass
    if sys.stdout:
        try:
            print(linea, end="", flush=True)
        except Exception:  # noqa: BLE001
            pass


def guardar_estado(**datos):
    datos["fecha"] = datetime.now().isoformat(timespec="seconds")
    try:
        (DATOS / "actualizacion.json").write_text(json.dumps(datos, ensure_ascii=False, indent=2), encoding="utf-8")
    except OSError:
        pass


def descargar_zip(sha):
    url = f"https://codeload.github.com/{REPO}/zip/{sha}"
    req = urllib.request.Request(url, headers={"User-Agent": "TimbreEscolar-actualizador"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def extraer(datos_zip, destino):
    with zipfile.ZipFile(io.BytesIO(datos_zip)) as z:
        z.extractall(destino)
    # GitHub mete todo dentro de una carpeta "repo-sha/"
    hijos = [p for p in Path(destino).iterdir() if p.is_dir()]
    raiz = hijos[0] if len(hijos) == 1 and not (Path(destino) / "timbre.py").exists() else Path(destino)
    if not (raiz / "timbre.py").is_file() or not (raiz / "web" / "index.html").is_file():
        raise RuntimeError("el paquete descargado no contiene timbre.py y web/index.html")
    return raiz


def probar_version(raiz):
    """Comprueba la versión nueva sin tocar la instalada."""
    for f in ("timbre.py", "actualizar.py"):
        if (raiz / f).exists():
            py_compile.compile(str(raiz / f), doraise=True)
    html = (raiz / "web" / "index.html").read_text(encoding="utf-8", errors="replace")
    if "</html>" not in html.lower() or "/api/estado" not in html:
        raise RuntimeError("web/index.html parece incompleto")
    # Importar el programa nuevo en un proceso aparte (detecta errores al cargar)
    r = subprocess.run([sys.executable.replace("pythonw.exe", "python.exe"), "-c",
                        "import sys; sys.path.insert(0, sys.argv[1]); import timbre; timbre.validar_config(timbre.config_por_defecto())",
                        str(raiz)], capture_output=True, text=True, timeout=60, **sin_ventana())
    if r.returncode != 0:
        raise RuntimeError("la versión nueva no arranca: " + (r.stderr.strip().splitlines() or ["?"])[-1])


def sin_ventana():
    return {"creationflags": 0x08000000} if ES_WINDOWS else {}


def copiar_elementos(origen, destino):
    for rel in ACTUALIZABLE:
        o, d = origen / rel, destino / rel
        if o.is_dir():
            shutil.copytree(o, d, dirs_exist_ok=True)
        elif o.is_file():
            d.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(o, d)


def pedir_cierre_y_esperar(espera=30):
    """El timbre en marcha mira datos/salir.flag cada medio segundo y se cierra solo."""
    (DATOS / "salir.flag").write_text("actualizar", encoding="utf-8")
    fin = time.time() + espera
    while time.time() < fin:
        if not timbre_en_marcha():
            break
        time.sleep(0.5)
    (DATOS / "salir.flag").unlink(missing_ok=True)
    return not timbre_en_marcha()


def timbre_en_marcha():
    """Comprueba el cerrojo de instancia única que mantiene timbre.py."""
    ruta = DATOS / "timbre.lock"
    if not ruta.exists():
        return False
    try:
        with open(ruta, "a+") as f:
            if ES_WINDOWS:
                import msvcrt
                f.seek(0)
                msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
                f.seek(0)
                msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
        return False
    except OSError:
        return True


def arrancar_timbre(args_timbre):
    exe = sys.executable
    if ES_WINDOWS and exe.lower().endswith("python.exe"):
        w = Path(exe).with_name("pythonw.exe")
        exe = str(w) if w.exists() else exe
    opciones = {"cwd": str(BASE), "stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL,
                "stderr": subprocess.DEVNULL}
    if ES_WINDOWS:
        opciones["creationflags"] = 0x00000008 | 0x00000200 | 0x08000000  # DETACHED | NEW_GROUP | NO_WINDOW
    else:
        opciones["start_new_session"] = True
    return subprocess.Popen([exe, str(BASE / "timbre.py"), *args_timbre], **opciones)


def responde(args_timbre, espera=40):
    puerto, clave = 8080, ""
    for i, a in enumerate(args_timbre):
        if a == "--puerto" and i + 1 < len(args_timbre):
            puerto = int(args_timbre[i + 1])
        if a == "--clave" and i + 1 < len(args_timbre):
            clave = args_timbre[i + 1]
    cabeceras = {"User-Agent": "TimbreEscolar-actualizador"}
    if clave:
        cabeceras["Authorization"] = "Basic " + base64.b64encode(f"admin:{clave}".encode()).decode()
    fin = time.time() + espera
    while time.time() < fin:
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{puerto}/api/version", headers=cabeceras)
            with urllib.request.urlopen(req, timeout=3) as r:
                if r.status == 200:
                    return True
        except Exception:  # noqa: BLE001
            pass
        time.sleep(1)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sha", required=True, help="commit de GitHub a instalar")
    ap.add_argument("--mensaje", default="")
    ap.add_argument("--fecha-commit", default="")
    ap.add_argument("--zip", help="(pruebas) usar un ZIP local en vez de descargar")
    ap.add_argument("resto", nargs=argparse.REMAINDER, help="-- argumentos con los que corre el timbre")
    a = ap.parse_args()
    args_timbre = [x for x in a.resto if x != "--"]
    DATOS.mkdir(parents=True, exist_ok=True)
    corto = a.sha[:7]
    guardar_estado(estado="en_curso", sha=a.sha)
    anotar(f"⬇ Actualización a la versión {corto} iniciada")

    temporal = Path(tempfile.mkdtemp(prefix="timbre-act-"))
    sustituida = False
    try:
        # 1-2. Descargar y probar
        datos_zip = Path(a.zip).read_bytes() if a.zip else descargar_zip(a.sha)
        raiz = extraer(datos_zip, temporal / "nueva")
        probar_version(raiz)
        anotar(f"Versión {corto} descargada y comprobada")

        # 3. Copia de seguridad de la versión actual
        if RESPALDO.exists():
            shutil.rmtree(RESPALDO, ignore_errors=True)
        RESPALDO.mkdir(parents=True)
        copiar_elementos(BASE, RESPALDO)
        if (DATOS / "version.json").exists():
            shutil.copy2(DATOS / "version.json", RESPALDO / "version.json")

        # 4. Sustituir y arrancar
        if not pedir_cierre_y_esperar():
            raise RuntimeError("el timbre en marcha no se ha cerrado; no se ha cambiado nada")
        sustituida = True
        copiar_elementos(raiz, BASE)
        (DATOS / "version.json").write_text(json.dumps(
            {"sha": a.sha, "mensaje": a.mensaje, "fecha_commit": a.fecha_commit,
             "instalada": datetime.now().isoformat(timespec="seconds")}, ensure_ascii=False, indent=2), encoding="utf-8")
        nuevo = arrancar_timbre(args_timbre)

        # 5. Comprobar que la versión nueva funciona; si no, volver atrás
        if responde(args_timbre):
            anotar(f"✓ Actualizado a la versión {corto}" + (f": {a.mensaje}" if a.mensaje else ""))
            guardar_estado(estado="ok", sha=a.sha, mensaje=a.mensaje)
            return 0
        anotar(f"La versión {corto} no responde: volviendo a la anterior", "error")
        try:
            nuevo.kill()
        except Exception:  # noqa: BLE001
            pass
        time.sleep(2)
        copiar_elementos(RESPALDO, BASE)
        if (RESPALDO / "version.json").exists():
            shutil.copy2(RESPALDO / "version.json", DATOS / "version.json")
        else:
            (DATOS / "version.json").unlink(missing_ok=True)
        arrancar_timbre(args_timbre)
        ok = responde(args_timbre)
        anotar("↩ Restaurada la versión anterior" + ("" if ok else " (no responde: revisa el PC)"), "aviso" if ok else "error")
        guardar_estado(estado="revertida", sha=a.sha, error="la versión nueva no respondía")
        return 1
    except Exception as e:  # noqa: BLE001
        anotar(f"No se pudo actualizar a {corto}: {e}", "error")
        guardar_estado(estado="error", sha=a.sha, error=str(e))
        # Si ya se habían empezado a copiar archivos, volver a la copia de seguridad
        if sustituida and RESPALDO.exists():
            try:
                copiar_elementos(RESPALDO, BASE)
                anotar("↩ Restaurada la versión anterior", "aviso")
            except Exception as e2:  # noqa: BLE001
                anotar(f"No se pudo restaurar la copia: {e2}", "error")
        # Si el timbre llegó a cerrarse, asegurarse de que vuelve a arrancar
        if not timbre_en_marcha():
            arrancar_timbre(args_timbre)
        return 1
    finally:
        shutil.rmtree(temporal, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

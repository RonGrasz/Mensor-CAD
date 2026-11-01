"""Contrato del acceso de desinstalación; ejecución real solo en Windows."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "Desinstalar.bat"


class AccesoDesinstalacion(unittest.TestCase):
    def test_delega_al_instalador_de_su_carpeta_sin_duplicar_el_motor(self):
        raw = LAUNCHER.read_bytes()
        raw.decode("ascii")
        self.assertNotIn(b"\n", raw.replace(b"\r\n", b""))
        lineas = [linea.strip() for linea in raw.decode("ascii").splitlines()
                  if linea.strip() and not linea.lower().startswith("rem ")]
        # Sin CALL: transfiere el control al BAT existente y conserva su salida.
        self.assertEqual(lineas, ["@echo off", '"%~dp0Instalar.bat" -Uninstall'])

    @unittest.skipUnless(os.name == "nt", "requiere cmd.exe de Windows")
    def test_doble_clic_equivalente_desde_otra_carpeta_conserva_argumento_y_resultado(self):
        with tempfile.TemporaryDirectory(prefix="mensorcad-uninstall-") as tmp:
            carpeta = Path(tmp) / "paquete con espacios & simbolos"
            carpeta.mkdir()
            acceso = carpeta / "Desinstalar.bat"
            acceso.write_bytes(LAUNCHER.read_bytes())
            for codigo in (0, 7):
                with self.subTest(codigo=codigo):
                    (carpeta / "Instalar.bat").write_bytes(
                        ('@echo off\r\necho argumentos=%*\r\n'
                         'echo diagnostico>&2\r\nexit /b {}\r\n'.format(codigo)).encode("ascii")
                    )
                    resultado = subprocess.run(
                        '"{}" /d /s /c ""{}""'.format(
                            os.environ.get("COMSPEC", "cmd.exe"), acceso,
                        ),
                        cwd=tmp, capture_output=True, text=True,
                    )
                    self.assertEqual(resultado.returncode, codigo)
                    self.assertEqual(resultado.stdout, "argumentos=-Uninstall\n")
                    self.assertEqual(resultado.stderr, "diagnostico\n")


if __name__ == "__main__":
    unittest.main()

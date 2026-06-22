# Mensor CAD

Plugins LISP para AutoCAD orientados a trabajos topográficos y catastrales. Tres comandos independientes con interfaz gráfica (DCL).

## Requisitos

- AutoCAD 64-bit (2010 o superior)
- Soporte ActiveX/VLA habilitado (carga automática con `vl-load-com`)

## Instalación

Cargar cada script manualmente con `APPLOAD`, o añadir la carpeta `lisp/` a las rutas de búsqueda de AutoCAD y colocar lo siguiente en tu `acaddoc.lsp`:

```lisp
(vl-load-com)
(load "MC-AREA.lsp"   "\nError al cargar MC-AREA")
(load "MC-TABLE.lsp"  "\nError al cargar MC-TABLE")
(load "MC-VECTOR.lsp" "\nError al cargar MC-VECTOR")
```

## Comandos

### MCAREA — Cálculo de Áreas Catastrales

```
MCAREA
```

Calcula el área de una polilínea cerrada e inserta el valor en el centroide del polígono. Soporta dos métodos de cálculo:

| Método | Descripción |
|--------|-------------|
| Estándar | Coordenadas originales sin modificar |
| MIMP / Mensuras RD | Redondeo de coordenadas a 2 decimales antes del cálculo (según normativa dominicana) |

Permite seleccionar la polilínea directamente o detectar el contorno con `-BOUNDARY` haciendo clic en un punto interior.

**Opciones de formato:** precisión decimal (0–4), altura de texto configurable, sufijo `m²` opcional.

### MCTABLE — Tablas de Coordenadas UTM, Rumbos y Distancias

```
MCTABLE
```

Genera dos tablas a partir de una polilínea cerrada:

1. **Tabla de coordenadas georreferenciadas** — ESTE (X) y NORTE (Y) por vértice, con posibilidad de invertir el orden de columnas.
2. **Cuadro de rumbos y distancias** — rumbo en formato `N DD° MM' SS" E` y distancia en metros por tramo.

Numera automáticamente los vértices en el dibujo y permite elegir el vértice de origen, la dirección de recorrido (horaria/antihoraria) y la precisión decimal.

### MCVECTOR — Anotador de Rumbos y Distancias

```
MCVECTOR
```

Anota el rumbo y la distancia de cada segmento de una polilínea directamente sobre el dibujo. El texto se coloca a ambos lados de cada segmento, rotado para mantener legibilidad.

Soporta dos modos:

| Modo | Funcionamiento |
|------|----------------|
| Polígono | Selecciona una polilínea y un vértice de inicio; anota todos los segmentos automáticamente |
| Manual | Indica pares de puntos uno a uno hasta cancelar con ESC |

Permite elegir sentido de recorrido (directo/inverso) y precisión decimal de la distancia (0–8).

## Estructura del repositorio

```
lisp/           # Scripts .lsp (el producto)
cuix/icons/     # Iconos para botones CUIX (pendiente)
```

## Licencia

MIT

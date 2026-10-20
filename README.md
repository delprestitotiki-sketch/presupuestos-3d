# Presupuestos 3D

Calculadora de presupuestos para impresión 3D. Elige impresora (Bambu Lab, Creality o Flashforge) y filamento con precios de Macrotec Uruguay, y genera el PDF para el cliente.

## Instalar

Abre la app en el navegador y:

- **Windows** (Edge o Chrome): toca **Instalar app** arriba, o el ícono de instalar en la barra de direcciones.
- **Android** (Chrome): toca **Instalar app**, o el menú ⋮ y luego **Instalar app**.
- **iPhone / iPad** (Safari): toca **Compartir** y luego **Agregar a pantalla de inicio**.

Funciona sin conexión. Tus clientes, presupuestos y datos del negocio se guardan solo en tu dispositivo.

## Precios

`catalog.json` tiene los filamentos, impresoras y la cotización del dólar BROU. Una tarea programada lo actualiza a diario desde [macrotec.com.uy](https://www.macrotec.com.uy). Los precios son de referencia y pueden cambiar.

## Archivos

- `index.html`: la app.
- `catalog.json`: catálogo de precios.
- `sw.js`: permite usarla sin conexión.
- `vendor/jspdf.umd.min.js`: [jsPDF](https://github.com/parallax/jsPDF) 2.5.1 (licencia MIT), genera el PDF.

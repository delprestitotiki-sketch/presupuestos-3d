# Presupuestos 3D

Calculadora de presupuestos para impresión 3D. Elige impresora (Bambu Lab, Creality o Flashforge) y filamento con precios de Macrotec Uruguay, y genera el PDF para el cliente.

## Instalar

Abre la app en el navegador y:

- **Windows** (Edge o Chrome): toca **Instalar app** arriba, o el ícono de instalar en la barra de direcciones.
- **Android** (Chrome): toca **Instalar app**, o el menú ⋮ y luego **Instalar app**.
- **iPhone / iPad** (Safari): toca **Compartir** y luego **Agregar a pantalla de inicio**.

Funciona sin conexión. Tus clientes, presupuestos y datos del negocio se guardan solo en tu dispositivo.

## Negocio compartido

En **Tu negocio → Negocio compartido** cada persona crea su cuenta con correo y contraseña. El dueño crea el negocio y pasa el código de invitación; quien entra con el código queda pendiente hasta que el dueño lo aprueba. Presupuestos en espera, trabajos, stock y datos del negocio se sincronizan entre socios y dispositivos (cada 20 segundos, al volver a la app y al guardar). Funciona sin conexión: los cambios se suben cuando vuelve internet.

El servidor es un proyecto de [Supabase](https://supabase.com). La estructura de la base de datos y sus reglas de seguridad están en la carpeta `supabase/`.

## Macrotec

La pestaña **Macrotec** muestra lo que vende [macrotec.com.uy](https://www.macrotec.com.uy): filamentos (por tipo, color y marca), pegamentos, repuestos de impresoras de filamento, pinturas y resinas. Se arma un pedido y se envía a Macrotec por WhatsApp o correo; al recibirlo, "Ya lo recibí" lo suma al stock de Tu negocio.

## Precios

Los filamentos, las impresoras y la cotización del dólar BROU los revisa a diario una tarea programada y los guarda en la tabla `catalog` de Supabase (`catalog.json` es la copia de respaldo). Pegamentos, repuestos, pinturas y resinas los revisa la propia base de datos todas las madrugadas (tabla `shop_items`, ver `supabase/supabase-tienda.sql`); `shop.json` es la copia de respaldo. Los precios son de referencia y pueden cambiar.

## Archivos

- `index.html`: la app.
- `catalog.json`: catálogo de precios.
- `shop.json`: pegamentos, repuestos, pinturas y resinas de Macrotec.
- `sw.js`: permite usarla sin conexión.
- `vendor/jspdf.umd.min.js`: [jsPDF](https://github.com/parallax/jsPDF) 2.5.1 (licencia MIT), genera el PDF.

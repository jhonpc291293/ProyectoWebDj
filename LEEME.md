# VIP PAITA MIX — pool de edits, remixes y mashups

Plataforma con catálogo, membresías y varios editores. Después de la instalación
**nadie toca código**: todo se administra desde `admin.html`.

## Archivos

| Archivo | Qué es |
|---|---|
| `index.html` | La web pública: catálogo, planes, crew, historia, cuenta del miembro |
| `admin.html` | El panel. Entra el administrador y también los DJs editores |
| `config.js` | Los dos datos de conexión a Supabase. Se llena una sola vez |
| `supabase-schema.sql` | Crea todas las tablas, la seguridad y los permisos |

---

## Cómo funciona el negocio

```
DJ visitante                  Miembro                        Administrador
─────────────                 ────────                       ─────────────
ve el catálogo completo  →    crea su cuenta gratis     →    ve el pago pendiente
escucha las muestras          elige un plan                  abre la captura
no puede descargar            yapea y sube la captura        aprueba con un clic
                              queda "pendiente"        ←     el acceso se activa
                              descarga todo el pool
                              (vence solo al terminar el plazo)
```

El cobro es manual (Yape / Plin) pero **queda registrado**: cada membresía guarda
plan, monto, comprobante, fecha de inicio y de vencimiento. Las membresías vencen
solas: no hay que acordarse de cortar accesos.

## Los tres roles

| Rol | Qué puede hacer |
|---|---|
| **admin** (Ronald) | Todo: catálogo completo, miembros, pagos, planes, crew, marca, roles |
| **editor** (los DJs) | Entra al panel y gestiona **solo sus propios tracks**, con sus estadísticas. También publica comunicados |
| **member** | No entra al panel. Descarga del catálogo si su membresía está vigente |

---

## Instalación

> **Importante:** la primera vez, este SQL reemplaza un esquema muy anterior (el
> de una tienda de mezclas: `products`, `gallery`, `orders`) y crea todo lo de
> VIP PAITA MIX desde cero. Después de esa primera vez, es seguro volver a
> pegarlo y correrlo cada vez que actualices el archivo (por ejemplo, cuando
> agreguemos una función nueva): **nunca borra tus tracks, tu marca, tus
> miembros, pagos, comunicados ni ningún otro contenido que ya hayas guardado**.

### 1. Ejecutar el esquema

Supabase → **SQL Editor** → *New query* → pega **todo** `supabase-schema.sql` → **Run**.
Debe terminar sin errores rojos. Puedes repetir este paso cada vez que el archivo
cambie — es seguro incluso si ya tienes tracks reales y tu marca configurada.

### 2. Confirmar tu cuenta de administrador

El SQL le da el rol **admin** al usuario más antiguo del proyecto. Si ya creaste tu
usuario, ya eres admin. Compruébalo entrando al panel: arriba a la derecha debe decir
*Administrador*.

### 3. Conectar

Pega tus dos valores en `config.js` (o usa el asistente de `admin.html`, que te
descarga el archivo listo). Los dos valores están en el botón verde **Connect** de
Supabase o en **Settings → API Keys**.

### 4. Desactivar la confirmación por correo (recomendado)

Supabase → **Authentication → Sign In / Providers → Email** → desactiva
*Confirm email*. Así un DJ que se registra entra al instante en vez de esperar un
correo. Si prefieres dejarlo activo, la web le avisa que revise su bandeja.

**Si lo dejas activo**, en Supabase → **Authentication → URL Configuration**
agrega la URL real donde vayas a publicar el sitio (paso 6) a **Site URL** y a
**Redirect URLs** (por ejemplo `https://tu-sitio.netlify.app`). Si no lo haces,
el enlace del correo de confirmación intentará abrir `localhost:3000` — la
dirección de desarrollo que trae Supabase por defecto — y el navegador del DJ
la va a rechazar con "no se puede obtener acceso a esta página".

### 5. Activar "+ Nueva cuenta" en el panel (recomendado, una sola vez)

El panel tiene un botón en **Editores y roles → + Nueva cuenta** para crear el
acceso de un DJ (correo, contraseña temporal y rol) sin entrar nunca a Supabase.
Para que ese botón funcione hace falta subir una vez la función que lo respalda
(usa la clave secreta del proyecto, que por seguridad no puede vivir en el
navegador). Se hace desde una terminal, con el mismo `supabase` que ya
instalaste para el asistente de conexión:

```
supabase login
supabase link --project-ref TU-REF-DE-PROYECTO
supabase functions deploy crear-usuario
```

El `TU-REF-DE-PROYECTO` es el texto que aparece en la URL de tu proyecto
(`https://TU-REF-DE-PROYECTO.supabase.co`). Después de este paso, el botón
queda funcionando para siempre — no hay que repetirlo salvo que cambies de
proyecto de Supabase.

Si no haces este paso, el panel sigue funcionando igual; ese botón en particular
avisa con un mensaje claro que la función no está desplegada, y puedes seguir
usando las dos formas de siempre (que el DJ se registre solo, o crearlo en
Supabase → *Authentication → Users → Add user*).

### 6. Agregar a los 5 DJs

Tres formas, de la más a la menos recomendada:

1. **Desde el panel**: **Editores y roles → + Nueva cuenta**, le pones el rol
   **editor** de una vez y le compartes la contraseña temporal por WhatsApp.
2. **El DJ se registra solo** desde la web (**Ingresar → Crear cuenta**). Aparece
   en el panel, en **Editores y roles**, como *miembro*; le cambias el rol a
   **editor** y desde ese momento entra al panel y sube su material.
3. **Desde Supabase** → *Authentication → Users → Add user*, y luego le cambias
   el rol igual que en la opción 2.

### 7. Publicar

Arrastra la carpeta a **app.netlify.com/drop**. La web queda en `tu-url/` y el panel
en `tu-url/admin.html`.

---

## Temas de temporada (Halloween, Navidad, Año Nuevo...)

En **Marca y contacto → Tema de temporada** eliges uno y se aplica al instante en
toda la web pública: cambian los colores de acento (botones, bordes, el brillo
detrás del título) por una paleta pensada para esa fecha. No cambia la tipografía
ni el orden de nada, así que no hay riesgo de que algo se desarme.

El panel de administración **no cambia de color** — sigue igual sin importar el
tema que elijas, para que tú y el equipo trabajen siempre con la misma vista.

Para completar el ambiente de temporada, combina el tema con lo que ya podías
cambiar antes: sube una **imagen de portada** (hero) alusiva, ajusta las
**frases del letrero animado** (agrega "🎃 Especial Halloween" o similar), y si
quieres avisar algo puntual, publica un **comunicado** fijado arriba de los demás.

Para volver a la normalidad, elige **"Normal"** en el mismo selector.

---

## Subir un track

Cada track admite **tres archivos** y cada uno cumple un papel distinto:

| Campo | Bucket | Quién lo ve |
|---|---|---|
| **Portada** | `portadas` (público) | Todos |
| **Muestra pública** (60-90 s) | `previews` (público) | Todos, sin registrarse |
| **Archivo completo** | `descargas` (**privado**) | Solo miembros con membresía activa |

Si dejas la muestra vacía, el reproductor toca un beat generado por el navegador con
el BPM y el género del track: la web nunca se ve muerta, aunque todavía no hayas
subido audio.

La casilla **"Gratis para usuarios registrados"** convierte un track en gancho: se
descarga con solo tener cuenta, sin pagar. Útil para captar correos de DJs.

**"Precio de venta suelta"**: si le pones un número mayor que 0, cualquiera puede
comprar **solo esa canción** sin necesitar membresía — ver la siguiente sección.
Déjalo en 0 si ese track solo se descarga con membresía (comportamiento de siempre).

---

## Vender una canción suelta (sin membresía)

Hay DJs que no quieren suscribirse, solo quieren 2 o 3 canciones puntuales. Para eso:

1. En **Tracks**, ponle un **precio** a la canción (campo "Precio de venta suelta").
2. En la web, esa canción muestra un botón de **carrito** en vez del candado. El
   visitante la agrega, revisa su carrito (ícono arriba a la derecha, junto a
   "Mi cuenta"), y paga con Yape/Plin subiendo su comprobante — igual que al
   elegir un plan. Puede juntar varias canciones de distintos DJs en una sola compra.
3. Tú apruebas desde el panel, en **Compras sueltas** (al lado de "Pagos por
   aprobar"). Igual que con las membresías, puedes avisarle por WhatsApp con un clic.
4. Una vez aprobada, esa persona puede descargar esas canciones **para siempre** —
   no vence, y no cuenta contra el límite diario de ningún plan.

Si la persona además tiene una membresía activa, igual puede comprar canciones
sueltas de otros DJs por separado; son dos cosas independientes.

---

## Publicar un comunicado

En **Comunicados** (panel) → **+ Nuevo comunicado**: título, texto y, si quieres,
una imagen o póster. Aparece en la web pública en la sección "Comunicados", entre
Membresías y El crew — perfecto para avisar dinámicas nuevas, temporadas o eventos,
como el que armaste para 2026.

- Lo puede publicar **cualquiera del equipo** (admin o editor).
- Cada uno edita o borra **solo lo que publicó**; el administrador puede tocar cualquiera.
- **"Fijar arriba"** lo deja primero en la lista sin importar la fecha — útil mientras
  una dinámica siga vigente.
- Si lo dejas sin marcar **"Publicado en la web"**, queda guardado pero oculto: sirve
  para prepararlo con anticipación.
- Si no hay ningún comunicado publicado, la sección entera desaparece de la web —
  no queda un espacio vacío.

**Además**, el comunicado más importante (el fijado, o si no hay ninguno fijado, el
más reciente) aparece solo, un momento después de cargar la página, como una
tarjeta pequeña en la esquina — sin bloquear el resto de la web. El visitante la
cierra con la X, o toca "Ver más" para ir directo a la sección. Aparece en
**cada** visita o recarga mientras siga publicado — no se acuerda de si el
visitante ya lo cerró antes.

---

## Seguridad: cómo se bloquea de verdad la descarga

No es una restricción de pantalla que se pueda saltar con las herramientas del
navegador. Son tres capas en la base de datos:

1. **La ruta del archivo vive en otra tabla** (`track_files`), que un visitante
   anónimo no puede leer. Del catálogo público solo salen título, portada y muestra.
2. **La descarga pasa por una función del servidor** (`solicitar_descarga`) que
   comprueba la membresía y el límite diario antes de devolver la ruta.
3. **El bucket privado tiene su propia política**: solo firma un enlace si la
   membresía está vigente. Aunque alguien consiguiera la ruta, no obtiene el archivo.

Probado en un Postgres real, rol por rol:

- Anónimo: ve el catálogo, no lee rutas, no descarga, no crea tracks, no ve miembros.
- Miembro sin plan: bloqueado en los tracks de pago, permitido en los gratis.
- Miembro vencido: bloqueado automáticamente al pasar la fecha.
- Miembro que intenta activarse su propia membresía o insertarse una "activa": rechazado.
- Editor: crea y edita solo sus tracks; no puede tocar los de otro DJ ni aprobar pagos.
- Nadie puede ascenderse a admin: la columna `rol` no es editable desde la API.

---

## Conectar Power BI

Vistas listas para analizar:

| Vista | Qué trae |
|---|---|
| `v_ingresos_mes` | membresías, ingresos y ticket promedio por mes |
| `v_top_tracks` | descargas y reproducciones por track |
| `v_editores` | aporte de cada DJ: tracks, descargas, último aporte |
| `v_miembros` | estado, plan, vencimiento y descargas por miembro |

Power BI → *Obtener datos* → **PostgreSQL**, con los datos de Supabase →
*Settings → Database*. Usa el *Connection pooler* si tu red bloquea IPv6.

El embudo completo queda en tablas: reproducción → descarga → membresía → renovación.
Con eso puedes responder qué género retiene mejor, qué DJ del crew aporta el material
que más se descarga, y cuántos miembros renuevan al vencer.

---

## Antes de lanzar

- [ ] Subir el logo y la imagen de portada en **Marca y contacto**
- [ ] Poner el número de Yape real y el titular
- [ ] Revisar los precios y los días de cada plan
- [ ] Borrar los 6 tracks de ejemplo y subir material real con sus tres archivos
- [ ] Completar el crew con los 5 DJs y sus fotos
- [ ] Ajustar los hitos de la historia (2016 → hoy)
- [ ] Probar el circuito completo con una cuenta de prueba: registro → pago → aprobación → descarga
- [ ] Desactivar *Confirm email* si quieres registro inmediato
- [ ] Desplegar `crear-usuario` (`supabase functions deploy crear-usuario`) para usar
      "+ Nueva cuenta" en el panel sin entrar a Supabase

## Dos cosas para planificar

**Términos de uso.** Un pool que distribuye edits y remixes conviene que publique sus
condiciones (uso exclusivo para DJs, prohibida la redistribución) y un correo de
contacto para reclamos de derechos. Es lo que hacen los pools establecidos, y es la
razón por la que las descargas van detrás de una membresía y no abiertas al público.

**Cobro automático.** Cuando la aprobación manual empiece a pesar (más o menos a
partir de 30 o 40 miembros), el paso siguiente es Mercado Pago o Culqi con una Edge
Function que apruebe la membresía sola al confirmarse el pago. La estructura ya está
lista: solo cambia quién llama a `aprobar_membresia`.

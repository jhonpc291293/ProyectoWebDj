// ============================================================================
//  VIP PAITA MIX · Fase 6: exporta todo de Supabase al formato del hosting.
//
//  Lee la base de datos y los archivos de Supabase y genera, en la carpeta
//  de salida:
//    datos.sql   -> se importa en MySQL (phpMyAdmin) DESPUÉS de schema.sql
//    subidas/    -> se sube dentro de public_html/subidas/
//    privado/    -> se sube a la carpeta privada, FUERA de public_html
//    resumen.txt -> cuántos registros y archivos salieron, y advertencias
//
//  No escribe nada en Supabase: solo lee. Uso (las tres claves son secretas,
//  nunca se guardan en el código):
//    npm install
//    SUPABASE_DB_URL="postgresql://postgres:CLAVE@..."      \
//    SUPABASE_URL="https://xxxx.supabase.co"                \
//    SUPABASE_SERVICE_KEY="eyJ... (service_role)"           \
//    node exportar.js salida
// ============================================================================
'use strict';
const { Client, types } = require('pg');
const fs = require('fs');
const path = require('path');
const { Readable } = require('stream');
const { pipeline } = require('stream/promises');

// fechas, decimales y JSON llegan como texto tal cual, sin que JavaScript
// los convierta (y les cambie la zona horaria o la precisión por el camino)
for (const oid of [1082, 1114, 1184, 1700]) types.setTypeParser(oid, v => v);

const DB_URL = process.env.SUPABASE_DB_URL;
const SB_URL = (process.env.SUPABASE_URL || '').replace(/\/+$/, '');
const SB_KEY = process.env.SUPABASE_SERVICE_KEY;
const SALIDA = path.resolve(process.argv[2] || 'salida');
if (!DB_URL || !SB_URL || !SB_KEY) {
  console.error('Faltan SUPABASE_DB_URL, SUPABASE_URL o SUPABASE_SERVICE_KEY (ver el encabezado de este archivo).');
  process.exit(1);
}

const avisos = [];
const conteo = {};

// ---------------------------------------------------------------------------
// Valores SQL. Los textos van en hexadecimal (_utf8mb4 X'...'): así ningún
// apóstrofo, barra invertida o tilde puede romper el archivo ni cambiar de
// significado según cómo esté configurado el MySQL del hosting.
// ---------------------------------------------------------------------------
function lit(v) {
  if (v === null || v === undefined) return 'NULL';
  if (typeof v === 'boolean') return v ? '1' : '0';
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : 'NULL';
  const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
  if (s === '') return "''";
  return `_utf8mb4 X'${Buffer.from(s, 'utf8').toString('hex')}'`;
}
// "2026-10-17 05:33:00.123-05" (ya en hora de Lima) -> "2026-10-17 05:33:00"
const fechaHora = v => (v ? String(v).slice(0, 19) : null);

// URL pública de Supabase -> URL en el hosting. Las de otros sitios
// (ej. un link de YouTube) se dejan igual.
function urlNueva(url) {
  if (!url) return url ?? '';
  const m = String(url).match(/\/storage\/v1\/object\/public\/(portadas|previews)\/([^?#]+)/);
  return m ? `/subidas/${m[1]}/${m[2]}` : url;
}
// ruta dentro de un bucket privado de Supabase -> ruta privada en el hosting
const rutaPrivada = (bucket, ruta) => (ruta ? `${bucket}/${ruta}` : '');

// En Supabase casi todas las columnas aceptan NULL; en MySQL muchas son
// NOT NULL con un valor por defecto. Un NULL ahí haría fallar la importación
// a la mitad, así que se reemplaza por el mismo valor por defecto del esquema.
let AHORA = null; // se llena con la hora de Lima al conectar
function rellenar(filas, defectos) {
  return filas.map(f => {
    const g = { ...f };
    for (const [k, v] of Object.entries(defectos)) if (g[k] === null || g[k] === undefined) g[k] = v;
    if ('creado' in g && !g.creado) g.creado = AHORA;
    return g;
  });
}

function inserts(tabla, columnas, filas) {
  conteo[tabla] = filas.length;
  if (!filas.length) return `-- ${tabla}: sin registros\n`;
  const cab = `INSERT INTO ${tabla} (${columnas.join(', ')}) VALUES\n`;
  const lotes = [];
  for (let i = 0; i < filas.length; i += 200) {
    lotes.push(cab + filas.slice(i, i + 200).map(f => `  (${columnas.map(c => lit(f[c])).join(', ')})`).join(',\n') + ';');
  }
  return `-- ${tabla}: ${filas.length}\n${lotes.join('\n')}\n`;
}

(async () => {
  const db = new Client({ connectionString: DB_URL, ssl: /supabase\.(co|com)/.test(DB_URL) ? { rejectUnauthorized: false } : undefined });
  await db.connect();
  await db.query("SET TIME ZONE 'America/Lima'"); // las fechas salen en hora de Lima, como las guarda MySQL
  const q = async (sql) => (await db.query(sql)).rows;
  AHORA = (await q("SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SS') AS t"))[0].t;

  // ----------------------------- usuarios -----------------------------
  // auth.users (correo y contraseña) + profiles (nombre, rol...) = usuarios.
  // Supabase guarda las contraseñas con bcrypt, el mismo formato que usa
  // password_verify() de PHP: los miembros siguen entrando con su clave.
  const filasUsuarios = (await q(`
    SELECT u.id, lower(u.email) AS email, u.encrypted_password, u.created_at,
           p.nombre, p.alias, p.rol, p.telefono, p.avatar, p.creado
      FROM auth.users u LEFT JOIN public.profiles p ON p.id = u.id
     ORDER BY u.created_at`)).map(u => {
    let hash = u.encrypted_password || '';
    if (!hash.startsWith('$2')) {
      // sin contraseña (ej. cuenta invitada que nunca la creó): una huella que
      // no coincide con nada; esa persona entra con "Olvidé mi contraseña"
      hash = '!sin-clave';
      avisos.push(`Usuario ${u.email || u.id} no tiene contraseña: deberá usar "Olvidé mi contraseña".`);
    }
    let email = u.email;
    if (!email) {
      email = `sin-correo-${u.id}@invalido.local`;
      avisos.push(`Usuario ${u.id} no tenía correo: quedó como ${email}.`);
    }
    return {
      id: u.id, email, password_hash: hash, nombre: u.nombre || '', alias: u.alias || '',
      rol: ['admin', 'editor', 'member'].includes(u.rol) ? u.rol : 'member',
      telefono: u.telefono || '', avatar: urlNueva(u.avatar), creado: fechaHora(u.creado || u.created_at),
    };
  });

  // ----------------------------- marca -----------------------------
  const COLS_SETTINGS = ['marca', 'creador', 'desde', 'ciudad', 'claim', 'hero_l1', 'hero_l2', 'hero_l3', 'logo_url',
    'hero_img', 'hero_video_fondo', 'whatsapp', 'email', 'moneda', 'yape_nombre', 'yape_numero', 'yape_qr', 'pago_nota',
    'frases', 'hitos', 'redes', 'tema', 'color_fondo', 'color_tarjetas', 'color_encabezado', 'color_piepagina',
    'color_texto', 'color_acento', 'fuente_titulos', 'fuente_texto', 'video_activo', 'video_url', 'video_archivo',
    'audio_destacado_titulo', 'audio_destacado_archivo'];
  const URLS_SETTINGS = ['logo_url', 'hero_img', 'hero_video_fondo', 'yape_qr', 'video_archivo', 'audio_destacado_archivo'];
  const st = (await q('SELECT * FROM public.settings WHERE id = 1'))[0];
  let sqlSettings = '-- settings: sin fila en Supabase, se dejan los valores por defecto\n';
  if (st) {
    const sets = COLS_SETTINGS.filter(c => c in st).map(c => {
      let v = st[c];
      if (URLS_SETTINGS.includes(c)) v = urlNueva(v);
      if (['frases', 'hitos', 'redes'].includes(c)) v = v === null ? null : JSON.stringify(v);
      if (v === null && !['frases', 'hitos', 'redes', 'desde'].includes(c)) v = '';
      return `${c} = ${lit(v)}`;
    });
    sqlSettings = `-- settings: 1\nUPDATE settings SET\n  ${sets.join(',\n  ')}\nWHERE id = 1;\n`;
    conteo.settings = 1;
  }

  // ----------------------------- el resto -----------------------------
  const crew = rellenar((await q('SELECT * FROM public.crew ORDER BY orden')).map(c => ({ ...c, foto: urlNueva(c.foto), creado: fechaHora(c.creado) })),
    { orden: 0, nombre: '', cargo: 'DJ / Editor', email: '', foto: '', ig: '', visible: true });
  const comunicados = rellenar((await q('SELECT * FROM public.comunicados')).map(c => ({ ...c, imagen: urlNueva(c.imagen), creado: fechaHora(c.creado) })),
    { imagen: '', autor: '', fijado: false, visible: true });
  const planes = rellenar((await q('SELECT * FROM public.plans ORDER BY orden')).map(p => ({ ...p, beneficios: JSON.stringify(p.beneficios ?? []), creado: fechaHora(p.creado) })),
    { orden: 0, dias: 30, precio: 0, limite_diario: 0, destacado: false, activo: true });
  const tracks = rellenar((await q('SELECT * FROM public.tracks')).map(t => ({
    ...t, portada: urlNueva(t.portada), preview: urlNueva(t.preview), creado: fechaHora(t.creado),
  })), { artista: '', tipo: 'edit', genero: '', tonalidad: '', duracion: '', portada: '', preview: '', editor: '',
         editor_email: '', gratis: false, precio: 0, destacado: false, visible: true, descargas: 0 });
  const trackFiles = rellenar((await q('SELECT * FROM public.track_files')).map(f => ({ ...f, ruta: rutaPrivada('descargas', f.ruta) })),
    { formato: 'mp3' });
  const compras = rellenar((await q('SELECT * FROM public.compras')).map(c => ({ ...c, comprobante: rutaPrivada('comprobantes', c.comprobante), creado: fechaHora(c.creado) })),
    { monto: 0, metodo: 'yape', estado: 'pendiente' });
  const compraTracks = rellenar(await q('SELECT * FROM public.compra_tracks'), { precio: 0 });
  const memberships = rellenar((await q('SELECT * FROM public.memberships')).map(m => ({ ...m, comprobante: rutaPrivada('comprobantes', m.comprobante), creado: fechaHora(m.creado) })),
    { plan_nombre: '', monto: 0, metodo: 'yape', estado: 'pendiente' });
  const downloads = rellenar((await q('SELECT * FROM public.downloads ORDER BY id')).map(d => ({ ...d, creado: fechaHora(d.creado) })), {});
  const plays = rellenar((await q('SELECT * FROM public.plays ORDER BY id')).map(p => ({ ...p, creado: fechaHora(p.creado) })), {});
  const bookings = rellenar((await q('SELECT * FROM public.bookings')).map(b => ({ ...b, creado: fechaHora(b.creado) })),
    { nombre: '', email: '', tipo: '', lugar: '', estado: 'nuevo' });

  // -------------------- registros huérfanos --------------------
  // En Supabase algunas tablas no tenían la llave foránea, así que al borrar
  // una canción o un usuario quedaron filas sueltas apuntando a la nada (en
  // producción: 10 track_files de canciones ya borradas). En MySQL esas
  // relaciones sí existen: lo que apunta a algo inexistente se descarta (o,
  // si la columna lo permite, se deja vacía), avisando cuánto fue.
  const idsTrack = new Set(tracks.map(t => t.id));
  const idsUsuario = new Set(filasUsuarios.map(u => u.id));
  const idsPlan = new Set(planes.map(p => p.id));
  function sinHuerfanos(nombre, filas, debeExistir, puedeQuedarVacio = {}) {
    let descartadas = 0, vaciadas = 0;
    const limpias = filas.filter(f => {
      for (const [col, ids] of Object.entries(debeExistir)) if (f[col] != null && !ids.has(f[col])) { descartadas++; return false; }
      for (const [col, ids] of Object.entries(puedeQuedarVacio)) if (f[col] != null && !ids.has(f[col])) { f[col] = null; vaciadas++; }
      return true;
    });
    if (descartadas) avisos.push(`${nombre}: ${descartadas} registro(s) descartado(s) porque apuntaban a algo que ya no existe.`);
    if (vaciadas) avisos.push(`${nombre}: ${vaciadas} referencia(s) a usuarios/planes borrados quedaron vacías.`);
    return limpias;
  }
  const trackFilesOk = sinHuerfanos('track_files', trackFiles, { track_id: idsTrack });
  const comprasOk = sinHuerfanos('compras', compras, { user_id: idsUsuario }, { aprobado_por: idsUsuario });
  const idsCompraOk = new Set(comprasOk.map(c => c.id));
  const compraTracksOk = sinHuerfanos('compra_tracks', compraTracks, { compra_id: idsCompraOk, track_id: idsTrack });
  const membershipsOk = sinHuerfanos('memberships', memberships, { user_id: idsUsuario }, { plan_id: idsPlan, aprobado_por: idsUsuario });
  const downloadsOk = sinHuerfanos('downloads', downloads, { track_id: idsTrack }, { user_id: idsUsuario });
  const playsOk = sinHuerfanos('plays', plays, { track_id: idsTrack }, { user_id: idsUsuario });
  const tracksOk = tracks.map(t => {
    const g = { ...t };
    if (g.editor_id && !idsUsuario.has(g.editor_id)) g.editor_id = null;
    if (g.plan_minimo_id && !idsPlan.has(g.plan_minimo_id)) g.plan_minimo_id = null;
    return g;
  });
  const comunicadosOk = comunicados.map(c => (c.autor_id && !idsUsuario.has(c.autor_id) ? { ...c, autor_id: null } : c));

  // ----------------------------- datos.sql -----------------------------
  fs.mkdirSync(SALIDA, { recursive: true });
  const partes = [
    '-- VIP PAITA MIX: datos exportados de Supabase. Importar DESPUÉS de schema.sql.',
    `-- Generado: ${new Date().toISOString()}`,
    'SET NAMES utf8mb4;', "SET time_zone = '-05:00';", 'SET FOREIGN_KEY_CHECKS = 0;', 'START TRANSACTION;',
    '-- schema.sql trae planes y crew de ejemplo: se reemplazan por los reales',
    'DELETE FROM planes;', 'DELETE FROM crew;',
    inserts('usuarios', ['id', 'email', 'password_hash', 'nombre', 'alias', 'rol', 'telefono', 'avatar', 'creado'], filasUsuarios),
    sqlSettings,
    inserts('crew', ['id', 'orden', 'alias', 'nombre', 'cargo', 'email', 'bio', 'foto', 'ig', 'visible', 'creado'], crew),
    inserts('comunicados', ['id', 'titulo', 'cuerpo', 'imagen', 'autor_id', 'autor', 'fijado', 'visible', 'creado'], comunicadosOk),
    inserts('planes', ['id', 'orden', 'nombre', 'dias', 'precio', 'descripcion', 'beneficios', 'limite_diario', 'destacado', 'activo', 'creado'], planes),
    // OJO con el orden: las descargas van ANTES que los tracks. MySQL tiene un
    // trigger que suma +1 al contador del track por cada descarga insertada;
    // como los tracks todavía no existen, no suma nada, y luego los tracks
    // entran con su contador real. Al revés, cada descarga se contaría doble.
    inserts('downloads', ['id', 'creado', 'user_id', 'track_id'], downloadsOk),
    inserts('tracks', ['id', 'titulo', 'artista', 'tipo', 'genero', 'bpm', 'tonalidad', 'duracion', 'anio', 'portada', 'preview',
      'editor_id', 'editor', 'editor_email', 'gratis', 'precio', 'plan_minimo_id', 'destacado', 'visible', 'descargas', 'creado'], tracksOk),
    inserts('track_files', ['track_id', 'ruta', 'peso_mb', 'formato'], trackFilesOk),
    inserts('compras', ['id', 'user_id', 'monto', 'metodo', 'comprobante', 'estado', 'aprobado_por', 'creado'], comprasOk),
    inserts('compra_tracks', ['compra_id', 'track_id', 'precio'], compraTracksOk),
    inserts('memberships', ['id', 'user_id', 'plan_id', 'plan_nombre', 'monto', 'metodo', 'comprobante', 'estado', 'inicio', 'fin',
      'notas', 'aprobado_por', 'creado'], membershipsOk),
    inserts('plays', ['id', 'creado', 'track_id', 'user_id'], playsOk),
    inserts('bookings', ['id', 'creado', 'nombre', 'email', 'tipo', 'fecha', 'lugar', 'mensaje', 'estado', 'notas'], bookings),
    'COMMIT;', 'SET FOREIGN_KEY_CHECKS = 1;',
  ];
  fs.writeFileSync(path.join(SALIDA, 'datos.sql'), partes.join('\n') + '\n', 'utf8');

  // ----------------------------- archivos -----------------------------
  const objetos = await q(`SELECT bucket_id, name FROM storage.objects
                            WHERE bucket_id IN ('portadas','previews','descargas','comprobantes') ORDER BY bucket_id, name`);
  await db.end();
  let archivos = 0, bytes = 0;
  for (const o of objetos) {
    if (o.name.split('/').some(p => p === '..' || p === '')) { avisos.push(`Archivo omitido por nombre no válido: ${o.bucket_id}/${o.name}`); continue; }
    const publico = ['portadas', 'previews'].includes(o.bucket_id);
    const destino = path.join(SALIDA, publico ? 'subidas' : 'privado', o.bucket_id, ...o.name.split('/'));
    const url = `${SB_URL}/storage/v1/object/${o.bucket_id}/${o.name.split('/').map(encodeURIComponent).join('/')}`;
    const r = await fetch(url, { headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` } });
    if (!r.ok) { avisos.push(`No se pudo bajar ${o.bucket_id}/${o.name} (HTTP ${r.status})`); continue; }
    fs.mkdirSync(path.dirname(destino), { recursive: true });
    await pipeline(Readable.fromWeb(r.body), fs.createWriteStream(destino)); // a disco directo: sirve para archivos grandes
    archivos++; bytes += fs.statSync(destino).size;
  }

  // archivos que la base de datos menciona pero que no están en Storage
  const enDisco = rel => fs.existsSync(path.join(SALIDA, rel));
  for (const t of tracks) for (const c of ['portada', 'preview']) {
    if (t[c]?.startsWith('/subidas/') && !enDisco(decodeURIComponent(t[c].slice(1)))) avisos.push(`El track "${t.titulo}" apunta a un ${c} que no existe en Storage.`);
  }
  for (const f of trackFilesOk) if (f.ruta && !enDisco(path.join('privado', f.ruta))) avisos.push(`El archivo completo ${f.ruta} no existe en Storage.`);

  const resumen = [
    'VIP PAITA MIX · resumen de la exportación', '',
    ...Object.entries(conteo).map(([t, n]) => `  ${t.padEnd(14)} ${n}`), '',
    `  archivos       ${archivos} (${(bytes / 1048576).toFixed(1)} MB)`, '',
    avisos.length ? `ADVERTENCIAS (${avisos.length}):\n  - ${avisos.join('\n  - ')}` : 'Sin advertencias.',
  ].join('\n');
  fs.writeFileSync(path.join(SALIDA, 'resumen.txt'), resumen + '\n', 'utf8');
  console.log(resumen);
})().catch(e => { console.error('La exportación falló:', e.message); process.exit(1); });

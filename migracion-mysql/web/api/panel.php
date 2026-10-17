<?php
/**
 * VIP PAITA MIX · Fase 5b: API del panel de administración (reemplaza lo
 * que admin.html hace hoy con sb.from()/sb.rpc()/sb.storage y la función
 * "crear-usuario" de Supabase).
 *
 * Dos niveles de permiso, igual que las políticas RLS de antes:
 *  - staff (admin o editor): entrar al panel, sus tracks, comunicados.
 *  - solo admin: pagos, compras, miembros, roles, planes, crew, marca,
 *    mensajes, y los tracks/comunicados de cualquiera.
 * Un editor solo ve, edita y borra los tracks y comunicados que son suyos.
 *
 * Mismo formato que publica.php: ?accion=..., respuesta JSON, y los POST
 * llevan cuerpo JSON + la cabecera "X-VPM: 1" (anti-CSRF).
 */

declare(strict_types=1);
session_start();
require __DIR__ . '/../../auth.php';
require __DIR__ . '/../../archivos.php';
require __DIR__ . '/../config.php';

header('Content-Type: application/json; charset=utf-8');

function responder(array $datos, int $codigo = 200): never {
  http_response_code($codigo);
  echo json_encode(fechas_iso(['ok' => $codigo < 400] + $datos), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
  exit;
}

// cuerpo JSON de un POST (exige la cabecera anti-CSRF)
function entrada(): array {
  if ($_SERVER['REQUEST_METHOD'] !== 'POST') throw new InvalidArgumentException('Usa POST');
  if (($_SERVER['HTTP_X_VPM'] ?? '') !== '1') throw new AccesoDenegado('Petición no permitida');
  $datos = json_decode(file_get_contents('php://input') ?: '{}', true);
  if (!is_array($datos)) throw new InvalidArgumentException('Datos no válidos');
  return $datos;
}

function solo_admin(PDO $pdo, string $id): void {
  if (!es_admin($pdo, $id)) throw new AccesoDenegado('Solo el administrador puede hacer esto');
}

function texto(array $in, string $k, int $max = 255): string {
  return mb_substr(trim((string) ($in[$k] ?? '')), 0, $max);
}
function entero_o_null(array $in, string $k): ?int {
  return isset($in[$k]) && $in[$k] !== '' && $in[$k] !== null ? (int) $in[$k] : null;
}
function si_no(array $in, string $k, bool $def = false): int {
  return array_key_exists($k, $in) ? (int) (bool) $in[$k] : (int) $def;
}

// las URLs públicas que guardamos son "/subidas/<bucket>/<archivo>"; para
// borrar el archivo físico se necesita la ruta relativa de vuelta
function relativa_de_url(?string $url, string $bucket): ?string {
  $marca = '/subidas/' . $bucket . '/';
  $i = strpos((string) $url, $marca);
  if ($i === false) return null;
  // se decodifica (%20 -> espacio) porque en el disco el archivo tiene el
  // nombre real; el chequeo de ".." va DESPUÉS, para que %2e%2e no lo esquive
  $rel = $bucket . '/' . rawurldecode(strtok(substr((string) $url, $i + strlen($marca)), '?#'));
  return str_contains($rel, '..') ? null : $rel;
}

function ruta_descarga_valida(string $ruta): bool {
  return str_starts_with($ruta, 'descargas/') && !str_contains($ruta, '..')
      && is_file(ruta_fisica_privada($ruta));
}

function normalizar_bools(array $fila, array $campos): array {
  foreach ($campos as $k) if (array_key_exists($k, $fila)) $fila[$k] = (bool) $fila[$k];
  return $fila;
}

try {
  $accion = $_GET['accion'] ?? '';
  $yo = requiere_sesion();
  if (!es_staff($pdo, $yo)) throw new AccesoDenegado('Esta cuenta no tiene acceso al panel');
  $soyAdmin = es_admin($pdo, $yo);

  switch ($accion) {

    // ======================= arranque del panel =======================
    case 'yo': {
      $st = $pdo->prepare('SELECT id, email, nombre, alias, rol, telefono, avatar FROM usuarios WHERE id = ?');
      $st->execute([$yo]);
      $perfil = $st->fetch(PDO::FETCH_ASSOC);
      $vencidas = $soyAdmin ? vencer_membresias($pdo, $yo) : 0; // antes: rpc("vencer_membresias") al abrir
      $moneda = $pdo->query('SELECT moneda FROM settings WHERE id = 1')->fetchColumn();
      $planes = $pdo->query('SELECT id, nombre, precio FROM planes ORDER BY precio')->fetchAll(PDO::FETCH_ASSOC);
      // la lista del equipo (con correos) es solo para el admin: un editor solo
      // se ve a sí mismo, como con la RLS "ve su perfil" de antes
      $staff = $soyAdmin
        ? $pdo->query("SELECT id, nombre, alias, email, rol FROM usuarios WHERE rol IN ('admin','editor')")->fetchAll(PDO::FETCH_ASSOC)
        : [array_intersect_key($perfil, array_flip(['id', 'nombre', 'alias', 'email', 'rol']))];
      responder(['perfil' => $perfil, 'moneda' => $moneda, 'vencidas' => $vencidas,
                 'planes' => $planes, 'staff' => $staff]);
    }

    case 'contadores': {
      solo_admin($pdo, $yo);
      $n = fn(string $sql) => (int) $pdo->query($sql)->fetchColumn();
      responder([
        'pagos' => $n("SELECT COUNT(*) FROM memberships WHERE estado = 'pendiente'"),
        'compras' => $n("SELECT COUNT(*) FROM compras WHERE estado = 'pendiente'"),
        'mensajes' => $n("SELECT COUNT(*) FROM bookings WHERE estado = 'nuevo'"),
      ]);
    }

    case 'resumen': {
      solo_admin($pdo, $yo);
      $hoy = hoy_lima();
      $n = function (string $sql, array $p = []) use ($pdo) {
        $st = $pdo->prepare($sql); $st->execute($p); return $st->fetchColumn();
      };
      $top = $pdo->query(
        'SELECT t.id, t.titulo, t.artista, t.tipo, t.editor, t.descargas,
                (SELECT COUNT(*) FROM plays p WHERE p.track_id = t.id) AS reproducciones
           FROM tracks t ORDER BY t.descargas DESC LIMIT 6'
      )->fetchAll(PDO::FETCH_ASSOC);
      $editores = $pdo->query(
        "SELECT COALESCE(NULLIF(editor,''), 'sin asignar') AS editor, COUNT(*) AS tracks,
                SUM(descargas) AS descargas, MAX(creado) AS ultimo_aporte
           FROM tracks GROUP BY 1 ORDER BY descargas DESC"
      )->fetchAll(PDO::FETCH_ASSOC);
      responder([
        'pendientes' => (int) $n("SELECT COUNT(*) FROM memberships WHERE estado = 'pendiente'"),
        'activos' => (int) $n("SELECT COUNT(*) FROM memberships WHERE estado = 'activa' AND fin >= ?", [$hoy]),
        'tracks' => (int) $n('SELECT COUNT(*) FROM tracks'),
        'descargas_7d' => (int) $n('SELECT COUNT(*) FROM downloads WHERE creado >= DATE_SUB(NOW(), INTERVAL 7 DAY)'),
        'ingresos_mes' => (float) $n(
          "SELECT COALESCE(SUM(monto),0) FROM memberships
            WHERE estado IN ('activa','vencida') AND creado >= DATE_FORMAT(NOW(), '%Y-%m-01')"),
        'top' => $top, 'editores' => $editores,
      ]);
    }

    // ======================= tracks =======================
    case 'tracks': {
      // admin: todo el catálogo; editor: solo los suyos (antes RLS "editor ve sus tracks")
      if ($soyAdmin) {
        $tracks = $pdo->query('SELECT * FROM tracks ORDER BY creado DESC')->fetchAll(PDO::FETCH_ASSOC);
      } else {
        $st = $pdo->prepare('SELECT * FROM tracks WHERE editor_id = ? ORDER BY creado DESC');
        $st->execute([$yo]);
        $tracks = $st->fetchAll(PDO::FETCH_ASSOC);
      }
      $ids = array_column($tracks, 'id');
      $archivos = [];
      if ($ids) {
        $st = $pdo->prepare('SELECT track_id, ruta FROM track_files WHERE track_id IN (' . implode(',', array_fill(0, count($ids), '?')) . ')');
        $st->execute($ids);
        $archivos = $st->fetchAll(PDO::FETCH_KEY_PAIR);
      }
      $tracks = array_map(fn($t) => normalizar_bools($t, ['gratis', 'destacado', 'visible']), $tracks);
      responder(['tracks' => $tracks, 'archivos' => $archivos]);
    }

    case 'guardar_track': {
      $in = entrada();
      $id = $in['id'] ?? null;
      if ($id) {
        $st = $pdo->prepare('SELECT editor_id FROM tracks WHERE id = ?');
        $st->execute([$id]);
        $dueno = $st->fetchColumn();
        if ($dueno === false) throw new InvalidArgumentException('Ese track no existe');
        if (!$soyAdmin && $dueno !== $yo) throw new AccesoDenegado('Solo puedes editar tus propios tracks');
      }

      $titulo = texto($in, 'titulo');
      if ($titulo === '') throw new InvalidArgumentException('Falta el título');
      $tipo = $in['tipo'] ?? 'edit';
      if (!in_array($tipo, ['edit','remix','mashup','intro','acapella','transicion'], true)) {
        throw new InvalidArgumentException('Tipo no válido');
      }
      $plan = $in['plan_minimo_id'] ?? null;
      if ($plan) {
        $st = $pdo->prepare('SELECT 1 FROM planes WHERE id = ?');
        $st->execute([$plan]);
        if (!$st->fetchColumn()) throw new InvalidArgumentException('Ese plan no existe');
      } else {
        $plan = null;
      }

      // de quién es el track: el editor siempre se lo asigna a sí mismo; el
      // admin puede elegir a otra persona del equipo. El alias y correo
      // mostrados salen de la base de datos, nunca del navegador.
      $editorId = $soyAdmin && !empty($in['editor_id']) ? $in['editor_id'] : $yo;
      $st = $pdo->prepare("SELECT alias, nombre, email FROM usuarios WHERE id = ? AND rol IN ('admin','editor')");
      $st->execute([$editorId]);
      $ed = $st->fetch(PDO::FETCH_ASSOC);
      if (!$ed) throw new InvalidArgumentException('El DJ elegido no es parte del equipo');

      $datos = [
        'titulo' => $titulo, 'artista' => texto($in, 'artista'), 'tipo' => $tipo,
        'genero' => texto($in, 'genero', 100), 'bpm' => entero_o_null($in, 'bpm'),
        'tonalidad' => texto($in, 'tonalidad', 10), 'duracion' => texto($in, 'duracion', 10),
        'anio' => entero_o_null($in, 'anio'), 'portada' => texto($in, 'portada', 500),
        'preview' => texto($in, 'preview', 500), 'editor_id' => $editorId,
        'editor' => $ed['alias'] ?: ($ed['nombre'] ?: 'DJ'), 'editor_email' => $ed['email'],
        'gratis' => si_no($in, 'gratis'), 'precio' => max(0, round((float) ($in['precio'] ?? 0), 2)),
        'plan_minimo_id' => $plan, 'destacado' => si_no($in, 'destacado'), 'visible' => si_no($in, 'visible', true),
      ];

      $archivo = $in['archivo'] ?? null;
      if ($archivo !== null && $archivo !== '' && !ruta_descarga_valida($archivo)) {
        throw new InvalidArgumentException('El archivo completo no es válido; vuelve a subirlo');
      }

      $pdo->beginTransaction();
      if ($id) {
        $sets = implode(', ', array_map(fn($k) => "$k = ?", array_keys($datos)));
        $pdo->prepare("UPDATE tracks SET $sets WHERE id = ?")->execute([...array_values($datos), $id]);
      } else {
        $id = uuid_v4();
        $cols = implode(', ', array_keys($datos));
        $marcas = implode(', ', array_fill(0, count($datos), '?'));
        $pdo->prepare("INSERT INTO tracks (id, $cols) VALUES (?, $marcas)")->execute([$id, ...array_values($datos)]);
      }
      if ($archivo) {
        $pdo->prepare(
          'INSERT INTO track_files (track_id, ruta, formato) VALUES (?, ?, ?)
           ON DUPLICATE KEY UPDATE ruta = VALUES(ruta), formato = VALUES(formato)'
        )->execute([$id, $archivo, strtolower(pathinfo($archivo, PATHINFO_EXTENSION))]);
      }
      $pdo->commit();
      responder(['id' => $id]);
    }

    case 'borrar_track': {
      $in = entrada();
      $st = $pdo->prepare('SELECT t.editor_id, t.portada, t.preview, tf.ruta
                             FROM tracks t LEFT JOIN track_files tf ON tf.track_id = t.id WHERE t.id = ?');
      $st->execute([$in['id'] ?? '']);
      $t = $st->fetch(PDO::FETCH_ASSOC);
      if (!$t) throw new InvalidArgumentException('Ese track no existe');
      if (!$soyAdmin && $t['editor_id'] !== $yo) throw new AccesoDenegado('Solo puedes borrar tus propios tracks');

      $pdo->prepare('DELETE FROM tracks WHERE id = ?')->execute([$in['id']]);
      // los archivos se borran después; si alguno falla, el track ya no existe igual.
      // Un archivo público que todavía usa otro registro NO se borra (así nadie
      // puede borrar el logo, o la portada de otro, apuntando su track a esa URL).
      foreach (['portadas' => $t['portada'], 'previews' => $t['preview']] as $bucket => $url) {
        $rel = relativa_de_url($url, $bucket);
        if ($rel && !url_en_uso($pdo, $url)) eliminar_archivo($bucket, $rel);
      }
      if ($t['ruta'] && str_starts_with($t['ruta'], 'descargas/') && !str_contains($t['ruta'], '..')) {
        eliminar_archivo('descargas', $t['ruta']);
      }
      responder([]);
    }

    // ======================= pagos de membresía =======================
    case 'membresias': {
      solo_admin($pdo, $yo);
      $filas = $pdo->query(
        'SELECT m.*, u.nombre, u.alias, u.telefono, u.email
           FROM memberships m LEFT JOIN usuarios u ON u.id = m.user_id
          ORDER BY m.creado DESC'
      )->fetchAll(PDO::FETCH_ASSOC);
      responder(['membresias' => $filas]);
    }

    case 'aprobar_membresia': {
      $in = entrada();
      responder(['membresia' => aprobar_membresia($pdo, $yo, $in['id'] ?? '')]); // valida admin adentro
    }

    case 'rechazar_membresia': {
      solo_admin($pdo, $yo);
      $in = entrada();
      $pdo->prepare("UPDATE memberships SET estado = 'rechazada', aprobado_por = ? WHERE id = ?")
        ->execute([$yo, $in['id'] ?? '']);
      responder([]);
    }

    case 'cambiar_fin_membresia': {
      solo_admin($pdo, $yo);
      $in = entrada();
      $fin = $in['fin'] ?? '';
      $d = DateTime::createFromFormat('Y-m-d', $fin);
      if (!$d || $d->format('Y-m-d') !== $fin) throw new InvalidArgumentException('Fecha no válida');
      $pdo->prepare('UPDATE memberships SET fin = ? WHERE id = ?')->execute([$fin, $in['id'] ?? '']);
      responder([]);
    }

    // ======================= compras sueltas =======================
    case 'compras': {
      solo_admin($pdo, $yo);
      $compras = $pdo->query(
        'SELECT c.*, u.nombre, u.alias, u.telefono, u.email
           FROM compras c LEFT JOIN usuarios u ON u.id = c.user_id ORDER BY c.creado DESC'
      )->fetchAll(PDO::FETCH_ASSOC);
      $lineas = $pdo->query(
        'SELECT ct.compra_id, ct.track_id, ct.precio, t.titulo, t.artista
           FROM compra_tracks ct LEFT JOIN tracks t ON t.id = ct.track_id'
      )->fetchAll(PDO::FETCH_ASSOC);
      $porCompra = [];
      foreach ($lineas as $l) $porCompra[$l['compra_id']][] = $l;
      foreach ($compras as &$c) $c['tracks'] = $porCompra[$c['id']] ?? [];
      unset($c);
      responder(['compras' => $compras]);
    }

    case 'aprobar_compra': {
      $in = entrada();
      responder(['compra' => aprobar_compra($pdo, $yo, $in['id'] ?? '')]); // valida admin adentro
    }

    case 'rechazar_compra': {
      solo_admin($pdo, $yo);
      $in = entrada();
      $pdo->prepare("UPDATE compras SET estado = 'rechazada', aprobado_por = ? WHERE id = ?")
        ->execute([$yo, $in['id'] ?? '']);
      responder([]);
    }

    // ======================= miembros y cuentas =======================
    case 'miembros': {
      // equivalente a la vista v_miembros: cada miembro con su membresía "principal"
      solo_admin($pdo, $yo);
      $filas = $pdo->query(
        "SELECT u.id, u.nombre, u.alias, u.telefono, u.email, m.estado, m.plan_nombre, m.inicio, m.fin,
                GREATEST(0, DATEDIFF(m.fin, CURDATE())) AS dias_restantes,
                (SELECT COUNT(*) FROM downloads d WHERE d.user_id = u.id) AS descargas_totales
           FROM usuarios u
           LEFT JOIN memberships m ON m.id = (
             SELECT x.id FROM memberships x WHERE x.user_id = u.id
              ORDER BY CASE x.estado WHEN 'activa' THEN 0 WHEN 'pendiente' THEN 1 ELSE 2 END,
                       x.fin IS NULL, x.fin DESC LIMIT 1)
          WHERE u.rol = 'member' ORDER BY u.creado DESC"
      )->fetchAll(PDO::FETCH_ASSOC);
      responder(['miembros' => $filas]);
    }

    case 'usuarios': {
      solo_admin($pdo, $yo);
      $filas = $pdo->query('SELECT id, email, nombre, alias, rol, telefono, avatar, creado FROM usuarios ORDER BY creado')
        ->fetchAll(PDO::FETCH_ASSOC);
      responder(['usuarios' => $filas]);
    }

    case 'cambiar_rol': {
      $in = entrada();
      // quitarse el admin a uno mismo dejaría el panel sin dueño
      if (($in['id'] ?? '') === $yo) throw new InvalidArgumentException('No puedes cambiar tu propio rol');
      cambiar_rol($pdo, $yo, $in['id'] ?? '', $in['rol'] ?? ''); // valida admin adentro
      responder([]);
    }

    case 'crear_usuario': {
      $in = entrada();
      $id = admin_crear_usuario($pdo, $yo, $in['email'] ?? '', (string) ($in['password'] ?? ''),
        texto($in, 'nombre'), $in['rol'] ?? 'member'); // valida admin, correo y clave adentro
      if (texto($in, 'alias') !== '' || texto($in, 'telefono') !== '') {
        $pdo->prepare('UPDATE usuarios SET alias = ?, telefono = ? WHERE id = ?')
          ->execute([texto($in, 'alias'), preg_replace('/\D/', '', texto($in, 'telefono', 50)), $id]);
      }
      responder(['id' => $id]);
    }

    case 'editar_usuario': {
      solo_admin($pdo, $yo);
      $in = entrada();
      $email = strtolower(texto($in, 'email'));
      if (!filter_var($email, FILTER_VALIDATE_EMAIL)) throw new InvalidArgumentException('Correo no válido');
      $st = $pdo->prepare('SELECT 1 FROM usuarios WHERE email = ? AND id <> ?');
      $st->execute([$email, $in['id'] ?? '']);
      if ($st->fetchColumn()) throw new CorreoYaRegistrado("Ya existe otra cuenta con el correo $email");
      $pdo->prepare('UPDATE usuarios SET email = ?, nombre = ?, alias = ?, telefono = ? WHERE id = ?')
        ->execute([$email, texto($in, 'nombre'), texto($in, 'alias'),
                   preg_replace('/\D/', '', texto($in, 'telefono', 50)), $in['id'] ?? '']);
      responder([]);
    }

    case 'resetear_password': {
      $in = entrada();
      admin_resetear_password($pdo, $yo, $in['id'] ?? '', (string) ($in['password'] ?? '')); // valida admin
      responder([]);
    }

    case 'borrar_usuario': {
      solo_admin($pdo, $yo);
      $in = entrada();
      if (($in['id'] ?? '') === $yo) throw new InvalidArgumentException('No puedes borrar tu propia cuenta desde aquí');
      $pdo->prepare('DELETE FROM usuarios WHERE id = ?')->execute([$in['id'] ?? '']);
      responder([]);
    }

    // ======================= planes y crew =======================
    case 'planes': {
      solo_admin($pdo, $yo);
      $filas = $pdo->query('SELECT * FROM planes ORDER BY orden')->fetchAll(PDO::FETCH_ASSOC);
      foreach ($filas as &$p) {
        $p['beneficios'] = json_decode($p['beneficios'] ?? '[]', true);
        $p = normalizar_bools($p, ['destacado', 'activo']);
      }
      unset($p);
      responder(['planes' => $filas]);
    }

    case 'guardar_plan': {
      solo_admin($pdo, $yo);
      $in = entrada();
      $nombre = texto($in, 'nombre');
      if ($nombre === '') throw new InvalidArgumentException('Falta el nombre del plan');
      $beneficios = array_values(array_filter(array_map('strval', (array) ($in['beneficios'] ?? [])), 'strlen'));
      $datos = [
        'nombre' => $nombre, 'dias' => max(1, (int) ($in['dias'] ?? 30)),
        'precio' => max(0, round((float) ($in['precio'] ?? 0), 2)), 'descripcion' => texto($in, 'descripcion', 1000),
        'beneficios' => json_encode($beneficios, JSON_UNESCAPED_UNICODE),
        'limite_diario' => max(0, (int) ($in['limite_diario'] ?? 0)),
        'destacado' => si_no($in, 'destacado'), 'activo' => si_no($in, 'activo', true),
      ];
      responder(['id' => guardar_fila($pdo, 'planes', $in['id'] ?? null, $datos)]);
    }

    case 'crew': {
      solo_admin($pdo, $yo);
      $filas = $pdo->query('SELECT * FROM crew ORDER BY orden')->fetchAll(PDO::FETCH_ASSOC);
      responder(['crew' => array_map(fn($c) => normalizar_bools($c, ['visible']), $filas)]);
    }

    case 'guardar_crew': {
      solo_admin($pdo, $yo);
      $in = entrada();
      $alias = texto($in, 'alias');
      if ($alias === '') throw new InvalidArgumentException('Falta el alias');
      $email = strtolower(texto($in, 'email'));
      if ($email !== '' && !filter_var($email, FILTER_VALIDATE_EMAIL)) throw new InvalidArgumentException('Correo no válido');

      $aliasAnterior = $alias;
      if (!empty($in['id'])) {
        $st = $pdo->prepare('SELECT alias FROM crew WHERE id = ?');
        $st->execute([$in['id']]);
        $aliasAnterior = $st->fetchColumn() ?: $alias;
      }
      $datos = [
        'alias' => $alias, 'nombre' => texto($in, 'nombre'), 'cargo' => texto($in, 'cargo') ?: 'DJ / Editor',
        'email' => $email, 'bio' => texto($in, 'bio', 2000), 'foto' => texto($in, 'foto', 500),
        'ig' => texto($in, 'ig'), 'visible' => si_no($in, 'visible', true),
      ];
      $id = guardar_fila($pdo, 'crew', $in['id'] ?? null, $datos);
      // igual que antes: el correo del crew se copia a sus tracks, para filtrarlos en el catálogo
      if ($email !== '') {
        $pdo->prepare('UPDATE tracks SET editor_email = ? WHERE editor = ?')->execute([$email, $aliasAnterior]);
      }
      responder(['id' => $id]);
    }

    case 'borrar_fila': {
      solo_admin($pdo, $yo);
      $in = entrada();
      $tabla = ['planes' => 'planes', 'crew' => 'crew'][$in['tabla'] ?? ''] ?? null;
      if (!$tabla) throw new InvalidArgumentException('Tabla no válida');
      $pdo->prepare("DELETE FROM $tabla WHERE id = ?")->execute([$in['id'] ?? '']);
      responder([]);
    }

    case 'intercambiar_orden': {
      solo_admin($pdo, $yo);
      $in = entrada();
      $tabla = ['planes' => 'planes', 'crew' => 'crew'][$in['tabla'] ?? ''] ?? null;
      if (!$tabla) throw new InvalidArgumentException('Tabla no válida');
      $st = $pdo->prepare("SELECT id, orden FROM $tabla WHERE id IN (?, ?)");
      $st->execute([$in['a'] ?? '', $in['b'] ?? '']);
      $o = $st->fetchAll(PDO::FETCH_KEY_PAIR);
      if (count($o) !== 2) throw new InvalidArgumentException('Registros no encontrados');
      $pdo->beginTransaction();
      $up = $pdo->prepare("UPDATE $tabla SET orden = ? WHERE id = ?");
      $up->execute([$o[$in['b']], $in['a']]);
      $up->execute([$o[$in['a']], $in['b']]);
      $pdo->commit();
      responder([]);
    }

    // ======================= comunicados =======================
    case 'comunicados': {
      $filas = $pdo->query('SELECT * FROM comunicados ORDER BY fijado DESC, creado DESC')->fetchAll(PDO::FETCH_ASSOC);
      responder(['comunicados' => array_map(fn($c) => normalizar_bools($c, ['fijado', 'visible']), $filas)]);
    }

    case 'guardar_comunicado': {
      $in = entrada();
      $titulo = texto($in, 'titulo');
      if ($titulo === '') throw new InvalidArgumentException('Falta el título');
      $datos = ['titulo' => $titulo, 'cuerpo' => texto($in, 'cuerpo', 5000), 'imagen' => texto($in, 'imagen', 500),
                'fijado' => si_no($in, 'fijado'), 'visible' => si_no($in, 'visible', true)];
      if (!empty($in['id'])) {
        $st = $pdo->prepare('SELECT autor_id FROM comunicados WHERE id = ?');
        $st->execute([$in['id']]);
        $autor = $st->fetchColumn();
        if ($autor === false) throw new InvalidArgumentException('Ese comunicado no existe');
        if (!$soyAdmin && $autor !== $yo) throw new AccesoDenegado('Solo puedes editar tus propios comunicados');
        responder(['id' => guardar_fila($pdo, 'comunicados', $in['id'], $datos)]);
      }
      $st = $pdo->prepare('SELECT alias, nombre FROM usuarios WHERE id = ?');
      $st->execute([$yo]);
      $p = $st->fetch(PDO::FETCH_ASSOC);
      $datos += ['autor_id' => $yo, 'autor' => $p['alias'] ?: ($p['nombre'] ?: '—')];
      responder(['id' => guardar_fila($pdo, 'comunicados', null, $datos)]);
    }

    case 'borrar_comunicado': {
      $in = entrada();
      $st = $pdo->prepare('SELECT autor_id FROM comunicados WHERE id = ?');
      $st->execute([$in['id'] ?? '']);
      $autor = $st->fetchColumn();
      if ($autor === false) throw new InvalidArgumentException('Ese comunicado no existe');
      if (!$soyAdmin && $autor !== $yo) throw new AccesoDenegado('Solo puedes borrar tus propios comunicados');
      $pdo->prepare('DELETE FROM comunicados WHERE id = ?')->execute([$in['id']]);
      responder([]);
    }

    // ======================= marca y contacto =======================
    case 'settings': {
      solo_admin($pdo, $yo);
      $s = $pdo->query('SELECT * FROM settings WHERE id = 1')->fetch(PDO::FETCH_ASSOC);
      foreach (['frases', 'hitos', 'redes'] as $k) $s[$k] = json_decode($s[$k] ?? 'null', true);
      responder(['settings' => normalizar_bools($s, ['video_activo'])]);
    }

    case 'guardar_settings': {
      solo_admin($pdo, $yo);
      $in = entrada();
      // solo se aceptan columnas conocidas: nada de lo que mande el navegador
      // llega a la consulta como nombre de columna sin pasar por esta lista
      $textos = ['marca', 'creador', 'ciudad', 'claim', 'hero_l1', 'hero_l2', 'hero_l3', 'logo_url', 'hero_img',
        'hero_video_fondo', 'whatsapp', 'email', 'moneda', 'yape_nombre', 'yape_numero', 'yape_qr', 'pago_nota',
        'color_fondo', 'color_tarjetas', 'color_encabezado', 'color_piepagina', 'color_texto', 'color_acento',
        'fuente_titulos', 'fuente_texto', 'video_url', 'video_archivo',
        'audio_destacado_titulo', 'audio_destacado_archivo'];
      $datos = [];
      foreach ($textos as $k) if (array_key_exists($k, $in)) $datos[$k] = texto($in, $k, 2000);
      foreach (['color_fondo', 'color_tarjetas', 'color_encabezado', 'color_piepagina', 'color_texto', 'color_acento'] as $k) {
        if (isset($datos[$k]) && $datos[$k] !== '' && !preg_match('/^#[0-9a-fA-F]{6}$/', $datos[$k])) {
          throw new InvalidArgumentException("Color no válido en $k");
        }
      }
      if (array_key_exists('desde', $in)) $datos['desde'] = (int) $in['desde'];
      if (array_key_exists('video_activo', $in)) $datos['video_activo'] = si_no($in, 'video_activo');
      if (array_key_exists('tema', $in)) {
        if (!in_array($in['tema'], ['normal', 'halloween', 'navidad', 'ano-nuevo'], true)) throw new InvalidArgumentException('Tema no válido');
        $datos['tema'] = $in['tema'];
      }
      foreach (['frases', 'hitos', 'redes'] as $k) {
        if (array_key_exists($k, $in)) $datos[$k] = json_encode($in[$k], JSON_UNESCAPED_UNICODE);
      }
      if ($datos) {
        $sets = implode(', ', array_map(fn($k) => "$k = ?", array_keys($datos)));
        $pdo->prepare("UPDATE settings SET $sets WHERE id = 1")->execute(array_values($datos));
      }
      responder([]);
    }

    // ======================= mensajes (bookings) =======================
    case 'mensajes': {
      solo_admin($pdo, $yo);
      responder(['mensajes' => $pdo->query('SELECT * FROM bookings ORDER BY creado DESC')->fetchAll(PDO::FETCH_ASSOC)]);
    }

    case 'estado_mensaje': {
      solo_admin($pdo, $yo);
      $in = entrada();
      if (!in_array($in['estado'] ?? '', ['nuevo', 'cotizado', 'cerrado', 'perdido'], true)) throw new InvalidArgumentException('Estado no válido');
      $pdo->prepare('UPDATE bookings SET estado = ? WHERE id = ?')->execute([$in['estado'], $in['id'] ?? '']);
      responder([]);
    }

    case 'borrar_mensaje': {
      solo_admin($pdo, $yo);
      $in = entrada();
      $pdo->prepare('DELETE FROM bookings WHERE id = ?')->execute([$in['id'] ?? '']);
      responder([]);
    }

    default:
      responder(['error' => 'Acción desconocida'], 404);
  }
} catch (AccesoDenegado $e) {
  responder(['error' => $e->getMessage()], 403);
} catch (InvalidArgumentException | ArchivoInvalido | CorreoYaRegistrado $e) {
  if (isset($pdo) && $pdo->inTransaction()) $pdo->rollBack();
  responder(['error' => $e->getMessage()], 400);
} catch (Throwable $e) {
  if (isset($pdo) && $pdo->inTransaction()) $pdo->rollBack();
  error_log((string) $e);
  responder(['error' => 'Error interno del servidor'], 500);
}

// ¿alguna otra parte del sitio sigue usando este archivo público?
function url_en_uso(PDO $pdo, ?string $url): bool {
  if (!$url) return false;
  $st = $pdo->prepare(
    'SELECT 1 FROM tracks WHERE portada = ? OR preview = ?
     UNION SELECT 1 FROM crew WHERE foto = ?
     UNION SELECT 1 FROM comunicados WHERE imagen = ?
     UNION SELECT 1 FROM settings WHERE ? IN (logo_url, hero_img, hero_video_fondo, yape_qr,
                                              video_archivo, audio_destacado_archivo)
     LIMIT 1'
  );
  $st->execute([$url, $url, $url, $url, $url]);
  return (bool) $st->fetchColumn();
}

// inserta o actualiza una fila; los nombres de columna vienen siempre de
// arreglos escritos en este archivo, nunca del navegador
function guardar_fila(PDO $pdo, string $tabla, ?string $id, array $datos): string {
  if ($id) {
    $sets = implode(', ', array_map(fn($k) => "$k = ?", array_keys($datos)));
    $st = $pdo->prepare("UPDATE $tabla SET $sets WHERE id = ?");
    $st->execute([...array_values($datos), $id]);
    return $id;
  }
  $id = uuid_v4();
  if (in_array($tabla, ['planes', 'crew'], true) && !isset($datos['orden'])) {
    $datos['orden'] = (int) $pdo->query("SELECT COALESCE(MAX(orden), 0) + 1 FROM $tabla")->fetchColumn();
  }
  $cols = implode(', ', array_keys($datos));
  $marcas = implode(', ', array_fill(0, count($datos), '?'));
  $pdo->prepare("INSERT INTO $tabla (id, $cols) VALUES (?, $marcas)")->execute([$id, ...array_values($datos)]);
  return $id;
}

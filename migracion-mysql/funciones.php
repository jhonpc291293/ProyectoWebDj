<?php
/**
 * VIP PAITA MIX · Fase 2 de la migración: reglas de negocio y seguridad
 * que en Supabase vivían como funciones SQL con auth.uid(). Aquí cada
 * función recibe el id del usuario logueado como parámetro explícito
 * (en la Fase 3, ese id saldrá de la sesión de PHP) porque MySQL no
 * tiene equivalente a auth.uid().
 *
 * Todas las consultas usan sentencias preparadas (prepared statements):
 * nunca se arma SQL pegando texto directamente, para no abrir la puerta
 * a inyección SQL.
 */

declare(strict_types=1);

// PHP en hora de Lima, igual que la conexión a MySQL (web/config.php)
date_default_timezone_set('America/Lima');

final class AccesoDenegado extends Exception {}

// ---------------------------------------------------------------------------
// Roles (antes mi_rol() / es_admin() / es_staff())
// ---------------------------------------------------------------------------
function mi_rol(PDO $pdo, string $userId): string {
  $st = $pdo->prepare('SELECT rol FROM usuarios WHERE id = ?');
  $st->execute([$userId]);
  $rol = $st->fetchColumn();
  return $rol !== false ? $rol : 'anon';
}

function es_admin(PDO $pdo, string $userId): bool {
  return mi_rol($pdo, $userId) === 'admin';
}

function es_staff(PDO $pdo, string $userId): bool {
  return in_array(mi_rol($pdo, $userId), ['admin', 'editor'], true);
}

// ---------------------------------------------------------------------------
// Medianoche de Perú de hoy, como string 'Y-m-d H:i:s' (Perú no tiene
// horario de verano, así que no hace falta más lógica que esta).
// ---------------------------------------------------------------------------
function inicio_dia_local(): string {
  $tz = new DateTimeZone('America/Lima');
  $hoy = new DateTime('now', $tz);
  $hoy->setTime(0, 0, 0);
  return $hoy->format('Y-m-d H:i:s');
}

// Las fechas con hora se guardan en hora de Lima (ver web/config.php). Antes
// de mandarlas al navegador se les agrega la zona (-05:00), como hacía
// Supabase: sin zona, el navegador las leería en la hora local de quien mira,
// y alguien fuera de Perú vería las horas corridas.
function fechas_iso(mixed $v): mixed {
  if (is_array($v)) {
    foreach ($v as $k => $x) $v[$k] = fechas_iso($x);
    return $v;
  }
  if (is_string($v) && preg_match('/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/', $v)) {
    return str_replace(' ', 'T', $v) . '-05:00';
  }
  return $v;
}

function hoy_lima(): string {
  $tz = new DateTimeZone('America/Lima');
  return (new DateTime('now', $tz))->format('Y-m-d');
}

// ---------------------------------------------------------------------------
// Solo el admin cambia roles (antes cambiar_rol())
// ---------------------------------------------------------------------------
function cambiar_rol(PDO $pdo, string $adminId, string $targetUserId, string $nuevoRol): void {
  if (!es_admin($pdo, $adminId)) {
    throw new AccesoDenegado('Solo el administrador puede cambiar roles');
  }
  if (!in_array($nuevoRol, ['admin', 'editor', 'member'], true)) {
    throw new InvalidArgumentException("Rol no válido: $nuevoRol");
  }
  $st = $pdo->prepare('UPDATE usuarios SET rol = ? WHERE id = ?');
  $st->execute([$nuevoRol, $targetUserId]);
}

// ---------------------------------------------------------------------------
// ¿Tiene una membresía activa y vigente? El admin siempre pasa.
// (antes membresia_activa())
// ---------------------------------------------------------------------------
function membresia_activa(PDO $pdo, string $userId): bool {
  if (es_admin($pdo, $userId)) return true;
  $st = $pdo->prepare(
    "SELECT 1 FROM memberships
      WHERE user_id = ? AND estado = 'activa' AND fin >= ? LIMIT 1"
  );
  $st->execute([$userId, hoy_lima()]);
  return (bool) $st->fetchColumn();
}

// ---------------------------------------------------------------------------
// ¿El usuario ya compró y le aprobaron este track suelto?
// (antes compro_track())
// ---------------------------------------------------------------------------
function compro_track(PDO $pdo, string $userId, string $trackId): bool {
  $st = $pdo->prepare(
    "SELECT 1 FROM compra_tracks ct
       JOIN compras c ON c.id = ct.compra_id
      WHERE ct.track_id = ? AND c.user_id = ? AND c.estado = 'aprobada' LIMIT 1"
  );
  $st->execute([$trackId, $userId]);
  return (bool) $st->fetchColumn();
}

// lista de track_id ya comprados y aprobados (antes mis_compras())
function mis_compras(PDO $pdo, string $userId): array {
  $st = $pdo->prepare(
    "SELECT ct.track_id FROM compra_tracks ct
       JOIN compras c ON c.id = ct.compra_id
      WHERE c.user_id = ? AND c.estado = 'aprobada'"
  );
  $st->execute([$userId]);
  return $st->fetchAll(PDO::FETCH_COLUMN);
}

// ---------------------------------------------------------------------------
// LA PUERTA DE VERDAD: decide si el usuario puede bajar este track, respetando
// el plan mínimo exigido por el track (si tiene uno). Sin plan_minimo_id, se
// comporta como antes: cualquier membresía activa alcanza. Con plan_minimo_id,
// hace falta un plan de ese precio o uno mayor (o comprado suelto, o admin,
// o que el track sea gratis). Un editor NO tiene vía libre por su rol.
// (antes puede_descargar_track())
// ---------------------------------------------------------------------------
function puede_descargar_track(PDO $pdo, string $userId, string $trackId): bool {
  if (es_admin($pdo, $userId)) return true;

  $st = $pdo->prepare('SELECT gratis, plan_minimo_id FROM tracks WHERE id = ?');
  $st->execute([$trackId]);
  $track = $st->fetch(PDO::FETCH_ASSOC);
  if (!$track) return false;
  if ((bool) $track['gratis']) return true;

  if (compro_track($pdo, $userId, $trackId)) return true;

  $st = $pdo->prepare(
    "SELECT mp.precio AS precio_plan
       FROM memberships m
       LEFT JOIN planes mp ON mp.id = m.plan_id
      WHERE m.user_id = ? AND m.estado = 'activa' AND m.fin >= ?
      ORDER BY m.fin DESC LIMIT 1"
  );
  $st->execute([$userId, hoy_lima()]);
  $membresia = $st->fetch(PDO::FETCH_ASSOC);
  if (!$membresia) return false;

  if ($track['plan_minimo_id'] === null) return true; // cualquier membresía activa alcanza

  $st = $pdo->prepare('SELECT precio FROM planes WHERE id = ?');
  $st->execute([$track['plan_minimo_id']]);
  $precioRequerido = (float) ($st->fetchColumn() ?: 0);
  $precioDelPlan = (float) ($membresia['precio_plan'] ?? 0);
  return $precioDelPlan >= $precioRequerido;
}

// ---------------------------------------------------------------------------
// LA PUERTA DE LAS DESCARGAS: valida membresía, compra suelta y límite diario,
// registra la descarga y devuelve la ruta del archivo (NUNCA pública: la sirve
// un script PHP aparte que llama a esta función primero).
// (antes solicitar_descarga())
// ---------------------------------------------------------------------------
function solicitar_descarga(PDO $pdo, string $userId, string $trackId): string {
  $st = $pdo->prepare(
    "SELECT t.gratis, tf.ruta FROM tracks t
       JOIN track_files tf ON tf.track_id = t.id
      WHERE t.id = ? AND t.visible = 1"
  );
  $st->execute([$trackId]);
  $fila = $st->fetch(PDO::FETCH_ASSOC);
  if (!$fila || $fila['ruta'] === null) {
    throw new RuntimeException('Este track no tiene archivo disponible');
  }

  $comprado = compro_track($pdo, $userId, $trackId);

  if (!puede_descargar_track($pdo, $userId, $trackId)) {
    throw new AccesoDenegado('Esta canción necesita un plan superior activo, o comprarla por separado');
  }

  if (!$comprado && !es_admin($pdo, $userId)) {
    $st = $pdo->prepare(
      "SELECT p.limite_diario FROM memberships m
         JOIN planes p ON p.id = m.plan_id
        WHERE m.user_id = ? AND m.estado = 'activa' AND m.fin >= ?
        ORDER BY m.fin DESC LIMIT 1"
    );
    $st->execute([$userId, hoy_lima()]);
    $limite = (int) ($st->fetchColumn() ?: 0);

    if ($limite > 0) {
      $st = $pdo->prepare('SELECT COUNT(*) FROM downloads WHERE user_id = ? AND creado >= ?');
      $st->execute([$userId, inicio_dia_local()]);
      $hoy = (int) $st->fetchColumn();
      if ($hoy >= $limite) {
        throw new RuntimeException("Alcanzaste tu límite de $limite descargas por día");
      }
    }
  }

  $st = $pdo->prepare('INSERT INTO downloads (user_id, track_id) VALUES (?, ?)');
  $st->execute([$userId, $trackId]);

  return $fila['ruta'];
}

// ---------------------------------------------------------------------------
// Resumen de la membresía del usuario, para pintar su cuenta en la web.
// (antes mi_membresia())
// ---------------------------------------------------------------------------
function mi_membresia(PDO $pdo, string $userId): array {
  $st = $pdo->prepare(
    "SELECT m.estado, COALESCE(p.nombre, m.plan_nombre) AS plan,
            COALESCE(p.precio, 0) AS plan_precio,
            m.inicio, m.fin, COALESCE(p.limite_diario, 0) AS limite_diario
       FROM memberships m LEFT JOIN planes p ON p.id = m.plan_id
      WHERE m.user_id = ?
      ORDER BY CASE WHEN m.estado = 'activa'    AND m.fin >= ? THEN 0
                     WHEN m.estado = 'pendiente' THEN 1
                     ELSE 2 END,
               m.fin DESC
      LIMIT 1"
  );
  $hoy = hoy_lima();
  $st->execute([$userId, $hoy]);
  $m = $st->fetch(PDO::FETCH_ASSOC);
  if (!$m) return ['estado' => 'ninguna'];

  // si quedó marcada "activa" pero ya venció (todavía no pasó el barrido de
  // vencer_membresias), se reporta como vencida: así coincide con
  // membresia_activa(), que es lo que de verdad decide el acceso
  $estado = ($m['estado'] === 'activa' && $m['fin'] < $hoy) ? 'vencida' : $m['estado'];

  $st = $pdo->prepare('SELECT COUNT(*) FROM downloads WHERE user_id = ? AND creado >= ?');
  $st->execute([$userId, inicio_dia_local()]);
  $descargasHoy = (int) $st->fetchColumn();

  $diasRestantes = 0;
  if ($m['fin']) {
    $dias = (int) (new DateTime($hoy))->diff(new DateTime($m['fin']))->format('%r%a');
    $diasRestantes = max(0, $dias);
  }

  return [
    'estado' => $estado,
    'plan' => $m['plan'],
    'plan_precio' => (float) $m['plan_precio'],
    'inicio' => $m['inicio'],
    'fin' => $m['fin'],
    'dias_restantes' => $diasRestantes,
    'limite_diario' => (int) $m['limite_diario'],
    'descargas_hoy' => $descargasHoy,
  ];
}

// ---------------------------------------------------------------------------
// Aprobar un pago de membresía: activa la membresía y calcula el vencimiento.
// Si ya tenía una vigente, los días se SUMAN desde su fin actual en vez de
// reiniciar desde hoy. (antes aprobar_membresia())
// ---------------------------------------------------------------------------
function aprobar_membresia(PDO $pdo, string $adminId, string $membershipId): array {
  if (!es_admin($pdo, $adminId)) {
    throw new AccesoDenegado('Solo el administrador puede aprobar pagos');
  }
  $st = $pdo->prepare(
    "SELECT mm.user_id, COALESCE(p.dias, 30) AS dias
       FROM memberships mm LEFT JOIN planes p ON p.id = mm.plan_id
      WHERE mm.id = ?"
  );
  $st->execute([$membershipId]);
  $fila = $st->fetch(PDO::FETCH_ASSOC);
  if (!$fila) throw new RuntimeException('Membresía no encontrada');

  $hoy = hoy_lima();
  $st = $pdo->prepare(
    "SELECT MAX(fin) FROM memberships
      WHERE user_id = ? AND estado = 'activa' AND fin >= ?"
  );
  $st->execute([$fila['user_id'], $hoy]);
  $finVigente = $st->fetchColumn();
  $base = ($finVigente && $finVigente > $hoy) ? $finVigente : $hoy;

  $fin = (new DateTime($base))->modify('+' . (int) $fila['dias'] . ' days')->format('Y-m-d');

  $st = $pdo->prepare(
    "UPDATE memberships SET estado = 'activa', inicio = ?, fin = ?, aprobado_por = ? WHERE id = ?"
  );
  $st->execute([$hoy, $fin, $adminId, $membershipId]);

  $st = $pdo->prepare('SELECT * FROM memberships WHERE id = ?');
  $st->execute([$membershipId]);
  return $st->fetch(PDO::FETCH_ASSOC);
}

// ---------------------------------------------------------------------------
// Aprobar una compra suelta: desbloquea esas canciones para siempre.
// (antes aprobar_compra())
// ---------------------------------------------------------------------------
function aprobar_compra(PDO $pdo, string $adminId, string $compraId): array {
  if (!es_admin($pdo, $adminId)) {
    throw new AccesoDenegado('Solo el administrador puede aprobar compras');
  }
  $st = $pdo->prepare("UPDATE compras SET estado = 'aprobada', aprobado_por = ? WHERE id = ?");
  $st->execute([$adminId, $compraId]);

  $st = $pdo->prepare('SELECT * FROM compras WHERE id = ?');
  $st->execute([$compraId]);
  return $st->fetch(PDO::FETCH_ASSOC);
}

// ---------------------------------------------------------------------------
// Vence las membresías cuyo plazo ya pasó (se llama al abrir el panel admin).
// (antes vencer_membresias())
// ---------------------------------------------------------------------------
function vencer_membresias(PDO $pdo, string $adminId): int {
  if (!es_admin($pdo, $adminId)) {
    throw new AccesoDenegado('Solo el administrador puede ejecutar esta acción');
  }
  $st = $pdo->prepare("UPDATE memberships SET estado = 'vencida' WHERE estado = 'activa' AND fin < ?");
  $st->execute([hoy_lima()]);
  return $st->rowCount();
}

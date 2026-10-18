<?php
/**
 * VIP PAITA MIX · Fase 5a: API de la web pública (reemplaza las llamadas
 * sb.from()/sb.auth/sb.storage que hoy hace index.html contra Supabase).
 *
 * Una sola entrada, con ?accion=... (mismo estilo que la función
 * "crear-usuario" que ya usa el panel). Siempre responde JSON:
 *   éxito -> {"ok":true, ...datos}     error -> {"ok":false,"error":"..."}
 *
 * Toda acción que cambia algo (POST) exige la cabecera "X-VPM: 1". Un
 * formulario de otro sitio no puede mandar cabeceras propias, así que
 * esto evita que una página ajena use la sesión del visitante para
 * hacer pedidos a su nombre (CSRF). El fetch() del sitio la agrega solo.
 */

declare(strict_types=1);
require __DIR__ . '/../../auth.php';
require __DIR__ . '/../../archivos.php';
require __DIR__ . '/../config.php';

header('Content-Type: application/json; charset=utf-8');

function responder(array $datos, int $codigo = 200): never {
  http_response_code($codigo);
  echo json_encode(fechas_iso(['ok' => $codigo < 400] + $datos), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
  exit;
}

function exigir_post(): void {
  if ($_SERVER['REQUEST_METHOD'] !== 'POST') throw new InvalidArgumentException('Usa POST');
  if (($_SERVER['HTTP_X_VPM'] ?? '') !== '1') throw new AccesoDenegado('Petición no permitida');
}

// convierte columnas BOOLEAN/JSON de MySQL a lo que el front-end espera
function normalizar_track(array $t): array {
  foreach (['gratis', 'destacado', 'visible'] as $k) $t[$k] = (bool) $t[$k];
  foreach (['bpm', 'anio', 'descargas'] as $k) $t[$k] = $t[$k] === null ? null : (int) $t[$k];
  $t['precio'] = (float) $t['precio'];
  return $t;
}

try {
  $accion = $_GET['accion'] ?? '';
  $userId = usuario_actual();

  switch ($accion) {

    // ---------------- sesión ----------------
    case 'sesion': {
      if (!$userId) responder(['usuario' => null]);
      $st = $pdo->prepare('SELECT id, email, nombre, alias, rol, telefono, avatar FROM usuarios WHERE id = ?');
      $st->execute([$userId]);
      responder(['usuario' => $st->fetch(PDO::FETCH_ASSOC) ?: null]);
    }

    case 'registrar': {
      exigir_post();
      $id = registrar_usuario($pdo, $_POST['email'] ?? '', $_POST['password'] ?? '',
        trim($_POST['nombre'] ?? ''), preg_replace('/\D/', '', $_POST['telefono'] ?? ''));
      $u = iniciar_sesion($pdo, $_POST['email'], $_POST['password']);
      responder(['usuario' => $u]);
    }

    case 'login': {
      exigir_post();
      $u = iniciar_sesion($pdo, $_POST['email'] ?? '', $_POST['password'] ?? '');
      responder(['usuario' => $u]);
    }

    case 'logout': {
      exigir_post();
      cerrar_sesion();
      responder([]);
    }

    case 'olvide': {
      exigir_post();
      // el token viaja solo por correo, nunca en la respuesta; y la respuesta
      // es igual exista o no el correo (no se revela quién tiene cuenta)
      $marca = (string) $pdo->query('SELECT marca FROM settings WHERE id = 1')->fetchColumn();
      enviar_restablecer($pdo, $_POST['email'] ?? '', URL_SITIO, CORREO_REMITENTE, $marca);
      responder(['mensaje' => 'Si el correo existe, te llegará un enlace para cambiar tu contraseña.']);
    }

    case 'restablecer': {
      exigir_post();
      restablecer_con_token($pdo, $_POST['token'] ?? '', $_POST['password'] ?? '');
      responder([]);
    }

    // ---------------- contenido público ----------------
    case 'inicio': {
      // todo lo que la web pinta al cargar, en una sola ida al servidor
      $s = $pdo->query('SELECT * FROM settings WHERE id = 1')->fetch(PDO::FETCH_ASSOC);
      foreach (['frases', 'hitos', 'redes'] as $k) $s[$k] = json_decode($s[$k] ?? 'null', true);
      $s['video_activo'] = (bool) $s['video_activo'];

      $planes = $pdo->query('SELECT * FROM planes WHERE activo = 1 ORDER BY orden')->fetchAll(PDO::FETCH_ASSOC);
      foreach ($planes as &$p) {
        $p['beneficios'] = json_decode($p['beneficios'] ?? '[]', true);
        $p['precio'] = (float) $p['precio'];
        $p['destacado'] = (bool) $p['destacado'];
      }
      unset($p);

      $crew = $pdo->query('SELECT id, orden, alias, nombre, cargo, bio, foto, ig FROM crew WHERE visible = 1 ORDER BY orden')
        ->fetchAll(PDO::FETCH_ASSOC);

      // editor_email no se publica: es dato interno del equipo
      $tracks = $pdo->query(
        'SELECT id, titulo, artista, tipo, genero, bpm, tonalidad, duracion, anio, portada, preview,
                editor_id, editor, gratis, precio, plan_minimo_id, destacado, visible, descargas, creado
           FROM tracks WHERE visible = 1 ORDER BY creado DESC'
      )->fetchAll(PDO::FETCH_ASSOC);
      $tracks = array_map('normalizar_track', $tracks);

      // qué tracks tienen archivo completo (sin revelar la ruta)
      $conArchivo = $pdo->query('SELECT track_id FROM track_files')->fetchAll(PDO::FETCH_COLUMN);

      $comunicados = $pdo->query(
        'SELECT id, titulo, cuerpo, imagen, autor, fijado, creado FROM comunicados
          WHERE visible = 1 ORDER BY fijado DESC, creado DESC'
      )->fetchAll(PDO::FETCH_ASSOC);
      foreach ($comunicados as &$c) $c['fijado'] = (bool) $c['fijado'];
      unset($c);

      responder(['settings' => $s, 'planes' => $planes, 'crew' => $crew, 'tracks' => $tracks,
                 'con_archivo' => $conArchivo, 'comunicados' => $comunicados]);
    }

    // ---------------- cuenta del miembro ----------------
    case 'mi_cuenta': {
      $id = requiere_sesion();
      $tracks = $pdo->query('SELECT id FROM tracks WHERE visible = 1')->fetchAll(PDO::FETCH_COLUMN);
      $descargables = array_values(array_filter($tracks, fn($t) => puede_descargar_track($pdo, $id, $t)));
      responder([
        'membresia' => mi_membresia($pdo, $id),
        'comprados' => mis_compras($pdo, $id),
        'descargables' => $descargables,
      ]);
    }

    case 'mis_descargas': {
      $id = requiere_sesion();
      $st = $pdo->prepare('SELECT creado, track_id FROM downloads WHERE user_id = ? ORDER BY creado DESC LIMIT 20');
      $st->execute([$id]);
      responder(['descargas' => $st->fetchAll(PDO::FETCH_ASSOC)]);
    }

    // Valida el permiso, registra la descarga y entrega un enlace temporal
    // (5 minutos, ligado a esta sesión) para descargar.php -- el mismo patrón
    // que el "enlace firmado" de Supabase. La ruta real nunca sale al navegador.
    case 'solicitar_descarga': {
      exigir_post();
      $id = requiere_sesion();
      $trackId = $_POST['track_id'] ?? '';
      $ruta = solicitar_descarga($pdo, $id, $trackId);

      $st = $pdo->prepare('SELECT titulo FROM tracks WHERE id = ?');
      $st->execute([$trackId]);
      // el archivo baja con el título tal cual se ve en la web: solo se quitan
      // los caracteres que Windows no acepta en un nombre (\ / : * ? " < > |)
      $titulo = preg_replace(['/[\\\\\/:*?"<>|\x00-\x1f]/u', '/\s+/u'], ['', ' '], (string) $st->fetchColumn()) ?? '';
      $titulo = rtrim(trim($titulo), '.') ?: 'track';
      $ext = strtolower(pathinfo($ruta, PATHINFO_EXTENSION)) ?: 'mp3';

      $ahora = time();
      $_SESSION['descargas'] = array_filter($_SESSION['descargas'] ?? [], fn($d) => $d['expira'] > $ahora);
      $token = bin2hex(random_bytes(16));
      $_SESSION['descargas'][$token] = ['ruta' => $ruta, 'nombre' => "$titulo.$ext", 'expira' => $ahora + 300];
      responder(['url' => 'descargar.php?t=' . $token]);
    }

    case 'solicitar_membresia': {
      exigir_post();
      $id = requiere_sesion();
      $st = $pdo->prepare('SELECT id, nombre, precio FROM planes WHERE id = ? AND activo = 1');
      $st->execute([$_POST['plan_id'] ?? '']);
      $plan = $st->fetch(PDO::FETCH_ASSOC);
      if (!$plan) throw new InvalidArgumentException('Ese plan no existe');
      if (!isset($_FILES['comprobante'])) throw new InvalidArgumentException('Adjunta la captura del pago');

      // cada quien sube a su propia subcarpeta (antes: carpeta = su user id)
      $ruta = subir_desde_http('comprobantes', $_FILES['comprobante'], $id);
      $st = $pdo->prepare(
        "INSERT INTO memberships (id, user_id, plan_id, plan_nombre, monto, metodo, comprobante, estado, notas)
         VALUES (?, ?, ?, ?, ?, 'yape', ?, 'pendiente', ?)"
      );
      $st->execute([uuid_v4(), $id, $plan['id'], $plan['nombre'], $plan['precio'], $ruta,
                    trim($_POST['notas'] ?? '')]);
      responder([]);
    }

    case 'solicitar_compra': {
      exigir_post();
      $id = requiere_sesion();
      $ids = array_values(array_unique(array_filter(explode(',', $_POST['track_ids'] ?? ''))));
      if (!$ids) throw new InvalidArgumentException('No elegiste canciones');
      if (!isset($_FILES['comprobante'])) throw new InvalidArgumentException('Adjunta la captura del pago');

      // el precio se toma de la base de datos, NUNCA del navegador
      $marcas = implode(',', array_fill(0, count($ids), '?'));
      $st = $pdo->prepare("SELECT id, precio FROM tracks WHERE visible = 1 AND precio > 0 AND id IN ($marcas)");
      $st->execute($ids);
      $tracks = $st->fetchAll(PDO::FETCH_KEY_PAIR);
      if (count($tracks) !== count($ids)) {
        throw new InvalidArgumentException('Alguna de esas canciones no está a la venta');
      }
      $total = array_sum(array_map('floatval', $tracks));

      $ruta = subir_desde_http('comprobantes', $_FILES['comprobante'], $id);
      $compraId = uuid_v4();
      $pdo->beginTransaction();
      $pdo->prepare("INSERT INTO compras (id, user_id, monto, metodo, comprobante, estado) VALUES (?, ?, ?, 'yape', ?, 'pendiente')")
        ->execute([$compraId, $id, $total, $ruta]);
      $linea = $pdo->prepare('INSERT INTO compra_tracks (compra_id, track_id, precio) VALUES (?, ?, ?)');
      foreach ($tracks as $tid => $precio) $linea->execute([$compraId, $tid, $precio]);
      $pdo->commit();
      responder(['total' => $total]);
    }

    case 'registrar_play': {
      exigir_post();
      $st = $pdo->prepare('INSERT INTO plays (track_id, user_id) SELECT id, ? FROM tracks WHERE id = ? AND visible = 1');
      $st->execute([$userId, $_POST['track_id'] ?? '']);
      responder([]);
    }

    case 'booking': {
      exigir_post();
      $fecha = $_POST['fecha'] ?? '';
      $st = $pdo->prepare(
        'INSERT INTO bookings (id, nombre, email, tipo, fecha, lugar, mensaje) VALUES (?, ?, ?, ?, ?, ?, ?)'
      );
      $st->execute([uuid_v4(), trim($_POST['nombre'] ?? ''), trim($_POST['email'] ?? ''),
        trim($_POST['tipo'] ?? ''), preg_match('/^\d{4}-\d{2}-\d{2}$/', $fecha) ? $fecha : null,
        trim($_POST['lugar'] ?? ''), trim($_POST['mensaje'] ?? '')]);
      responder([]);
    }

    default:
      responder(['error' => 'Acción desconocida'], 404);
  }
} catch (AccesoDenegado $e) {
  responder(['error' => $e->getMessage()], 403);
} catch (CredencialesInvalidas $e) {
  responder(['error' => $e->getMessage()], 401);
} catch (InvalidArgumentException | ArchivoInvalido | CorreoYaRegistrado | TokenInvalido $e) {
  responder(['error' => $e->getMessage()], 400);
} catch (Throwable $e) {
  if (isset($pdo) && $pdo->inTransaction()) $pdo->rollBack();
  error_log((string) $e);
  responder(['error' => 'Error interno del servidor'], 500);
}

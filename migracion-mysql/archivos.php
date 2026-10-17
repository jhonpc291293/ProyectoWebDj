<?php
/**
 * VIP PAITA MIX · Fase 4 de la migración: subida y entrega de archivos.
 * Reemplaza el Storage de Supabase, que no existe en un hosting normal --
 * aquí los archivos van al disco del servidor, organizados igual que los
 * "buckets" de antes (portadas, previews, descargas, comprobantes).
 *
 * LA REGLA DE ORO: "descargas" y "comprobantes" viven FUERA de la carpeta
 * pública del hosting (fuera de public_html). Así, aunque alguien adivine
 * el nombre exacto del archivo, Apache/Nginx no se lo va a servir -- solo
 * lo entrega descargar.php / ver_comprobante.php, y solo después de
 * verificar permisos contra la base de datos (igual que hacía RLS antes).
 */

declare(strict_types=1);
require_once __DIR__ . '/funciones.php';

final class ArchivoInvalido extends Exception {}

// Rutas físicas reales. En producción: RUTA_PUBLICA = la carpeta "subidas"
// dentro de public_html; RUTA_PRIVADA = una carpeta hermana de public_html,
// un nivel afuera, inalcanzable por URL.
define('RUTA_PUBLICA', __DIR__ . '/web/subidas');
define('RUTA_PRIVADA', __DIR__ . '/privado');

const BUCKETS = [
  'portadas'     => ['publico' => true,  'extensiones' => ['jpg','jpeg','png','webp','gif'],        'limite_mb' => 8],
  'previews'     => ['publico' => true,  'extensiones' => ['mp3','wav','m4a','mp4','webm'],          'limite_mb' => 100],
  'descargas'    => ['publico' => false, 'extensiones' => ['mp3','wav','m4a','zip'],                 'limite_mb' => 200],
  'comprobantes' => ['publico' => false, 'extensiones' => ['jpg','jpeg','png','pdf'],                'limite_mb' => 8],
];

function nombre_seguro(string $original): string {
  $limpio = strtolower($original);
  $limpio = preg_replace('/[^a-z0-9.]+/', '-', $limpio) ?? 'archivo';
  return time() . '-' . $limpio;
}

/**
 * Valida y guarda un archivo en el bucket indicado. $mover es la función que
 * de verdad mueve el archivo (move_uploaded_file en producción, copy en las
 * pruebas) -- así esta función se puede probar sin necesitar una subida HTTP
 * real. Devuelve la ruta relativa que se guarda en la base de datos.
 */
function procesar_subida(
  string $bucket, string $rutaFuente, string $nombreOriginal, int $tamanoBytes,
  callable $mover, ?string $subcarpeta = null
): string {
  if (!isset(BUCKETS[$bucket])) throw new InvalidArgumentException("Bucket desconocido: $bucket");
  $conf = BUCKETS[$bucket];

  $ext = strtolower(pathinfo($nombreOriginal, PATHINFO_EXTENSION));
  if (!in_array($ext, $conf['extensiones'], true)) {
    throw new ArchivoInvalido("Extensión no permitida para $bucket: ." . ($ext ?: '(ninguna)'));
  }
  if ($tamanoBytes > $conf['limite_mb'] * 1024 * 1024) {
    throw new ArchivoInvalido("El archivo pasa de {$conf['limite_mb']} MB");
  }
  if ($subcarpeta !== null && (str_contains($subcarpeta, '..') || str_contains($subcarpeta, '/'))) {
    throw new InvalidArgumentException('Subcarpeta no válida');
  }

  $nombre = nombre_seguro($nombreOriginal);
  $carpetaBase = $conf['publico'] ? RUTA_PUBLICA : RUTA_PRIVADA;
  $carpeta = $carpetaBase . '/' . $bucket . ($subcarpeta ? '/' . $subcarpeta : '');
  if (!is_dir($carpeta) && !mkdir($carpeta, 0755, true) && !is_dir($carpeta)) {
    throw new RuntimeException('No se pudo crear la carpeta de destino');
  }

  $destino = $carpeta . '/' . $nombre;
  if (!$mover($rutaFuente, $destino)) {
    throw new RuntimeException('No se pudo guardar el archivo en el servidor');
  }

  return $bucket . ($subcarpeta ? '/' . $subcarpeta : '') . '/' . $nombre;
}

// para usar desde un formulario HTTP real, con $_FILES['campo']
function subir_desde_http(string $bucket, array $archivo, ?string $subcarpeta = null): string {
  if (($archivo['error'] ?? UPLOAD_ERR_NO_FILE) !== UPLOAD_ERR_OK) {
    throw new ArchivoInvalido('Hubo un problema al recibir el archivo');
  }
  return procesar_subida(
    $bucket, $archivo['tmp_name'], $archivo['name'], (int) $archivo['size'],
    fn($de, $a) => move_uploaded_file($de, $a), $subcarpeta
  );
}

// la URL pública (portadas/previews) que arma el front-end con el dominio
function url_publica(string $rutaRelativa): string {
  return '/subidas/' . $rutaRelativa;
}

function ruta_fisica_privada(string $rutaRelativa): string {
  return RUTA_PRIVADA . '/' . $rutaRelativa;
}

function eliminar_archivo(string $bucket, string $rutaRelativa): void {
  if (!isset(BUCKETS[$bucket])) throw new InvalidArgumentException("Bucket desconocido: $bucket");
  $base = BUCKETS[$bucket]['publico'] ? RUTA_PUBLICA : RUTA_PRIVADA;
  $ruta = $base . '/' . $rutaRelativa;
  if (is_file($ruta)) unlink($ruta);
}

// ---------------------------------------------------------------------------
// ¿Puede este usuario ver este comprobante de pago? Su dueño, o el admin.
// (antes la política "lee comprobante" de Supabase Storage)
// ---------------------------------------------------------------------------
function puede_ver_comprobante(PDO $pdo, string $userId, string $rutaComprobante): bool {
  if (es_admin($pdo, $userId)) return true;
  $st = $pdo->prepare(
    'SELECT 1 FROM memberships WHERE comprobante = ? AND user_id = ?
     UNION SELECT 1 FROM compras WHERE comprobante = ? AND user_id = ?'
  );
  $st->execute([$rutaComprobante, $userId, $rutaComprobante, $userId]);
  return (bool) $st->fetchColumn();
}

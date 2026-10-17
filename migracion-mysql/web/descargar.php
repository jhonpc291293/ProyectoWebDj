<?php
/**
 * Entrega el archivo completo de un track. Solo funciona con un enlace
 * temporal que emite api/publica.php?accion=solicitar_descarga, que es
 * donde se valida el permiso (membresía, plan mínimo, compra, límite
 * diario) y se registra la descarga.
 */
declare(strict_types=1);
require __DIR__ . '/../auth.php';
require __DIR__ . '/../archivos.php';

try {
  requiere_sesion();
  $d = $_SESSION['descargas'][$_GET['t'] ?? ''] ?? null;
  if (!$d || $d['expira'] < time()) {
    throw new AccesoDenegado('El enlace de descarga venció. Vuelve a tocar "Descargar".');
  }
  $fisica = ruta_fisica_privada($d['ruta']);
  if (!is_file($fisica)) throw new RuntimeException('El archivo no está disponible en el servidor');

  // libera la sesión ANTES de mandar el archivo: PHP la deja bloqueada mientras
  // dura la petición, y con un archivo grande el resto de la web de ese
  // usuario quedaría congelada hasta que termine la descarga
  session_write_close();

  $ascii = preg_replace('/[^A-Za-z0-9 ._-]/', '', $d['nombre']) ?: 'track';
  header('Content-Type: application/octet-stream');
  header("Content-Disposition: attachment; filename=\"$ascii\"; filename*=UTF-8''" . rawurlencode($d['nombre']));
  header('Content-Length: ' . filesize($fisica));
  while (ob_get_level()) ob_end_clean();
  readfile($fisica);
  exit;
} catch (AccesoDenegado $e) {
  http_response_code(403); echo 'ERROR:' . $e->getMessage();
} catch (Throwable $e) {
  http_response_code(400); echo 'ERROR:' . $e->getMessage();
}

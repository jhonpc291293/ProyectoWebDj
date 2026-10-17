<?php
declare(strict_types=1);
require __DIR__ . '/../auth.php';
require __DIR__ . '/../archivos.php';
require __DIR__ . '/config.php';

try {
  $userId = requiere_sesion();
  $ruta = $_GET['ruta'] ?? '';
  if ($ruta === '' || str_contains($ruta, '..') || !str_starts_with($ruta, 'comprobantes/')) {
    throw new InvalidArgumentException('Ruta no válida');
  }
  if (!puede_ver_comprobante($pdo, $userId, $ruta)) {
    throw new AccesoDenegado('No puedes ver este comprobante');
  }

  $fisica = ruta_fisica_privada($ruta);
  if (!is_file($fisica)) throw new RuntimeException('No se encontró el archivo');

  header('Content-Type: ' . (mime_content_type($fisica) ?: 'application/octet-stream'));
  readfile($fisica);
  exit;
} catch (AccesoDenegado $e) {
  http_response_code(403); echo 'ERROR:' . $e->getMessage();
} catch (Throwable $e) {
  http_response_code(400); echo 'ERROR:' . $e->getMessage();
}

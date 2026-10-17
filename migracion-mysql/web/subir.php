<?php
declare(strict_types=1);
require __DIR__ . '/../auth.php';
require __DIR__ . '/../archivos.php';
require __DIR__ . '/config.php';

try {
  $userId = requiere_sesion();
  if (!es_staff($pdo, $userId)) {
    throw new AccesoDenegado('Solo el equipo (admin/editor) puede subir archivos');
  }
  $bucket = $_POST['bucket'] ?? '';
  if (!isset($_FILES['archivo'])) throw new InvalidArgumentException('Falta el archivo');

  $ruta = subir_desde_http($bucket, $_FILES['archivo']);
  echo 'OK:' . $ruta;
} catch (AccesoDenegado $e) {
  http_response_code(403); echo 'ERROR:' . $e->getMessage();
} catch (Throwable $e) {
  http_response_code(400); echo 'ERROR:' . $e->getMessage();
}

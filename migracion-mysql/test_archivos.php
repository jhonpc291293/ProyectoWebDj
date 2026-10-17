<?php
declare(strict_types=1);
require __DIR__ . '/archivos.php';

$fallos = 0;
function verificar(string $titulo, bool $condicion): void {
  global $fallos;
  echo ($condicion ? "OK   " : "FALLO") . " - $titulo\n";
  if (!$condicion) $fallos++;
}

// archivo de prueba real en disco (para poder "subirlo")
$tmp = sys_get_temp_dir() . '/fixture-' . uniqid() . '.jpg';
file_put_contents($tmp, str_repeat('x', 1024)); // 1 KB

$mueve = fn($de, $a) => copy($de, $a);

echo "=== Validación de extensión y tamaño ===\n";
$ruta = procesar_subida('portadas', $tmp, 'logo.JPG', filesize($tmp), $mueve);
verificar('acepta .JPG (mayúsculas) en portadas y guarda la ruta en minúsculas', str_ends_with($ruta, '.jpg'));
verificar('la ruta empieza con el nombre del bucket', str_starts_with($ruta, 'portadas/'));
verificar('el archivo quedó de verdad en el disco', is_file(RUTA_PUBLICA . '/' . $ruta));

try {
  procesar_subida('portadas', $tmp, 'virus.exe', filesize($tmp), $mueve);
  verificar('NO debería aceptar .exe en portadas', false);
} catch (ArchivoInvalido $e) {
  verificar('rechaza una extensión no permitida (' . $e->getMessage() . ')', true);
}

try {
  procesar_subida('portadas', $tmp, 'foto.jpg', 20 * 1024 * 1024, $mueve); // dice pesar 20MB
  verificar('NO debería aceptar un archivo que pasa el límite', false);
} catch (ArchivoInvalido $e) {
  verificar('rechaza un archivo que pasa el límite de tamaño (' . $e->getMessage() . ')', true);
}

echo "\n=== Bucket privado vs público ===\n";
$rutaPrivada = procesar_subida('descargas', $tmp, 'cancion.mp3', filesize($tmp), $mueve);
verificar('un archivo de "descargas" se guarda en RUTA_PRIVADA, no en la pública', is_file(ruta_fisica_privada($rutaPrivada)) && !is_file(RUTA_PUBLICA . '/' . $rutaPrivada));

echo "\n=== Nombre de archivo con caracteres raros ===\n";
$rutaRara = procesar_subida('portadas', $tmp, 'Mi Foto Año 2026 (final)!!.PNG', filesize($tmp), $mueve);
verificar('limpia espacios, tildes/símbolos y mayúsculas del nombre', preg_match('/^portadas\/\d+-mi-foto-a-o-2026-final-\.png$/', $rutaRara) === 1);

echo "\n=== Subcarpeta con intento de escape ===\n";
try {
  procesar_subida('portadas', $tmp, 'x.jpg', filesize($tmp), $mueve, '../../etc');
  verificar('NO debería aceptar una subcarpeta con ".."', false);
} catch (InvalidArgumentException $e) {
  verificar('rechaza un intento de escape de carpeta (' . $e->getMessage() . ')', true);
}

echo "\n=== Eliminar archivo ===\n";
eliminar_archivo('portadas', $ruta);
verificar('tras eliminar_archivo, el archivo ya no existe', !is_file(RUTA_PUBLICA . '/' . $ruta));

unlink($tmp);

echo "\n" . ($fallos === 0 ? "TODO OK ({$fallos} fallos)\n" : "HAY {$fallos} FALLO(S)\n");
exit($fallos === 0 ? 0 : 1);

<?php
declare(strict_types=1);
// Pruebas locales: apunta al contenedor de MySQL de prueba.
// En producción, esto se cambia por los datos reales del hosting.
$pdo = new PDO('mysql:host=vpm-mysql-test;dbname=vip_paita_mix;charset=utf8mb4', 'root', 'test1234', [
  PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
]);

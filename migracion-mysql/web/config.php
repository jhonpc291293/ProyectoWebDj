<?php
declare(strict_types=1);
// Pruebas locales: apunta al contenedor de MySQL de prueba.
// En producción, esto se cambia por los datos reales del hosting.
//
// time_zone = -05:00: todas las fechas se guardan y comparan en hora de Lima
// (Perú no cambia de horario en el año). Sin esto, MySQL usa la hora del
// servidor del hosting (casi siempre UTC) y el "límite de descargas por día"
// se reiniciaría a las 7 p. m. en vez de a medianoche.
$pdo = new PDO('mysql:host=vpm-mysql-test;dbname=vip_paita_mix;charset=utf8mb4', 'root', 'test1234', [
  PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
  PDO::MYSQL_ATTR_INIT_COMMAND => "SET time_zone = '-05:00'",
]);

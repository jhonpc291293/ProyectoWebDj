#!/bin/bash
# Pruebas que solo tienen sentido con Apache (como en el hosting): .htaccess,
# la carpeta de subidas sin ejecución de código y la cookie de sesión.
# Contenedor vpm-php-test con php:8.2-apache y base de datos limpia.
BASE="http://127.0.0.1:8099"; PUB="$BASE/api/publica.php"; H="X-VPM: 1"
FALLOS=0
verificar() {
  if [ "$2" = "$3" ]; then echo "OK    - $1"; else echo "FALLO - $1 (esperado=$2, obtuvo=$3)"; FALLOS=$((FALLOS+1)); fi
}
cod() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
dentro() { MSYS_NO_PATHCONV=1 docker exec vpm-php-test sh -c "$1"; }

echo "=== La web abre ==="
verificar "la portada (index.html) responde" "200" "$(cod "$BASE/")"
verificar "la portada es la nuestra" "1" "$(curl -s "$BASE/" | grep -c '<title>')"
verificar "la API responde" "200" "$(cod "$PUB?accion=inicio")"

echo ""
echo "=== Archivos que nunca deben verse por URL ==="
verificar "config.php (tiene la clave de la base) -> 403" "403" "$(cod "$BASE/config.php")"
verificar ".htaccess -> 403" "403" "$(cod "$BASE/.htaccess")"
verificar "auth.php vive fuera de la carpeta pública -> 404" "404" "$(cod "$BASE/auth.php")"
verificar "la carpeta privada no existe por URL -> 404" "404" "$(cod "$BASE/privado/")"

echo ""
echo "=== La carpeta de subidas ==="
curl -s -c /tmp/cka -H "$H" -d "email=admin@test.com&password=claveadmin&nombre=Admin" "$PUB?accion=registrar" >/dev/null
echo "imagen" > /tmp/img.jpg
RUTA=$(curl -s -b /tmp/cka -F "bucket=portadas" -F "archivo=@/tmp/img.jpg" "$BASE/subir.php" | sed 's/^OK://')
verificar "una portada subida se ve" "200" "$(cod "$BASE/subidas/$RUTA")"
verificar "la carpeta se protegió sola con su .htaccess" "si" "$(dentro 'test -f /app/web/subidas/.htaccess && echo si || echo no')"
verificar "no lista los archivos de la carpeta" "403" "$(cod "$BASE/subidas/portadas/")"
# simulamos que un .php se coló en subidas (por FTP, un bug futuro...): no debe ejecutarse
dentro "echo '<?php echo \"CODIGO-EJECUTADO\";' > /app/web/subidas/portadas/colado.php"
verificar "un .php dentro de subidas NO se ejecuta (403)" "403" "$(cod "$BASE/subidas/portadas/colado.php")"
verificar "y su código no aparece en ningún lado" "0" "$(curl -s "$BASE/subidas/portadas/colado.php" | grep -c CODIGO-EJECUTADO)"
rm -f "$(dirname "$0")/web/subidas/portadas/colado.php" # misma carpeta, vista desde fuera del contenedor

echo ""
echo "=== Cookie de sesión blindada ==="
COOKIE=$(curl -s -D - -o /dev/null -H "$H" -d "email=admin@test.com&password=claveadmin" "$PUB?accion=login" | grep -i '^set-cookie: vpm_sesion' | tail -1)
verificar "la sesión usa su propia cookie (vpm_sesion)" "1" "$(echo "$COOKIE" | grep -c 'vpm_sesion=')"
verificar "el JavaScript no puede leerla (HttpOnly)" "1" "$(echo "$COOKIE" | grep -ci 'httponly')"
verificar "otros sitios no pueden usarla (SameSite=Lax)" "1" "$(echo "$COOKIE" | grep -ci 'samesite=lax')"
verificar "un ID de sesión inventado no se acepta" "None" \
  "$(curl -s -b 'vpm_sesion=inventado1234567890abcdef' "$PUB?accion=sesion" | python -c "import sys,json; print(json.load(sys.stdin)['usuario'])")"

rm -f /tmp/cka /tmp/img.jpg
echo ""
if [ "$FALLOS" -eq 0 ]; then echo "TODO OK (0 fallos)"; else echo "HAY $FALLOS FALLO(S)"; fi
exit $FALLOS

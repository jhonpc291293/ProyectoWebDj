#!/bin/bash
BASE="http://127.0.0.1:8099"
FALLOS=0
verificar() {
  if [ "$2" = "$3" ]; then echo "OK    - $1 (esperado=$2)"; else echo "FALLO - $1 (esperado=$2, obtuvo=$3)"; FALLOS=$((FALLOS+1)); fi
}

TRACK_ID="83a52d0af66e1dab08c0fe49985a170f"

echo "=== Login ==="
rm -f /tmp/ck_admin /tmp/ck_a /tmp/ck_b
LOGIN_ADMIN=$(curl -s -c /tmp/ck_admin -d "email=admin@test.com" -d "password=claveadmin" "$BASE/login.php")
echo "admin login: $LOGIN_ADMIN"
LOGIN_A=$(curl -s -c /tmp/ck_a -d "email=membera@test.com" -d "password=clavea123" "$BASE/login.php")
echo "memberA login: $LOGIN_A"
LOGIN_B=$(curl -s -c /tmp/ck_b -d "email=memberb@test.com" -d "password=claveb123" "$BASE/login.php")
echo "memberB login: $LOGIN_B"

echo ""
echo "=== Descargar (protegido por membresía, con enlace temporal) ==="
API="$BASE/api/publica.php?accion=solicitar_descarga"
URL_A=$(curl -s -b /tmp/ck_a -H "X-VPM: 1" -d "track_id=$TRACK_ID" "$API" | python -c "import sys,json; print(json.load(sys.stdin).get('url',''))")
CODE=$(curl -s -o /tmp/salida_a -w "%{http_code}" -b /tmp/ck_a "$BASE/$URL_A")
verificar "miembro A (con plan activo) descarga el track" 200 "$CODE"
verificar "el contenido descargado es el archivo real" "contenido falso de audio" "$(cat /tmp/salida_a)"

CODE=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/ck_b "$BASE/$URL_A")
verificar "el enlace temporal de A no le sirve a B (está atado a la sesión de A)" 403 "$CODE"

CODE=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/ck_b -H "X-VPM: 1" -d "track_id=$TRACK_ID" "$API")
verificar "miembro B (SIN plan) NO consigue enlace de descarga" 403 "$CODE"

CODE=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/ck_a "$BASE/descargar.php?t=inventado")
verificar "un enlace inventado no descarga nada" 403 "$CODE"

CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/$URL_A")
verificar "sin sesión (sin cookie) NO puede descargar" 403 "$CODE"

echo ""
echo "=== Ver comprobante (protegido: dueño o admin) ==="
CODE=$(curl -s -o /tmp/comp_a -w "%{http_code}" -b /tmp/ck_a "$BASE/ver_comprobante.php?ruta=comprobantes/pago-membera.jpg")
verificar "la dueña (miembro A) ve su propio comprobante" 200 "$CODE"
verificar "el contenido es el comprobante real" "contenido falso de imagen" "$(cat /tmp/comp_a)"

CODE=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/ck_b "$BASE/ver_comprobante.php?ruta=comprobantes/pago-membera.jpg")
verificar "miembro B NO puede ver el comprobante ajeno" 403 "$CODE"

CODE=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/ck_admin "$BASE/ver_comprobante.php?ruta=comprobantes/pago-membera.jpg")
verificar "el admin SÍ puede ver cualquier comprobante" 200 "$CODE"

CODE=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/ck_a "$BASE/ver_comprobante.php?ruta=../../archivos.php")
verificar "un intento de path traversal es rechazado" 400 "$CODE"

echo ""
echo "=== Subir archivo (solo staff) ==="
echo "contenido de una foto de prueba" > /tmp/foto_prueba.jpg
CODE=$(curl -s -o /tmp/subida_b -w "%{http_code}" -b /tmp/ck_b -F "bucket=portadas" -F "archivo=@/tmp/foto_prueba.jpg" "$BASE/subir.php")
verificar "un miembro normal NO puede subir archivos" 403 "$CODE"

CODE=$(curl -s -o /tmp/subida_admin -w "%{http_code}" -b /tmp/ck_admin -F "bucket=portadas" -F "archivo=@/tmp/foto_prueba.jpg" "$BASE/subir.php")
verificar "el admin SÍ puede subir un archivo" 200 "$CODE"
echo "respuesta: $(cat /tmp/subida_admin)"

echo "contenido de un script malicioso" > /tmp/malo.php
CODE=$(curl -s -o /tmp/subida_mala -w "%{http_code}" -b /tmp/ck_admin -F "bucket=portadas" -F "archivo=@/tmp/malo.php" "$BASE/subir.php")
verificar "rechaza subir un .php disfrazado de portada" 400 "$CODE"
echo "respuesta: $(cat /tmp/subida_mala)"

echo ""
if [ "$FALLOS" -eq 0 ]; then echo "TODO OK (0 fallos)"; else echo "HAY $FALLOS FALLO(S)"; fi
exit $FALLOS

#!/bin/bash
# Prueba la sección "Servicios" (sin precios, solo cotizar) en las dos APIs.
# Requiere: contenedores vpm-mysql-test (con schema.sql recién cargado, sin
# usuarios) y vpm-php-test corriendo.
PUB="http://127.0.0.1:8099/api/publica.php"
PANEL="http://127.0.0.1:8099/api/panel.php"
H="X-VPM: 1"
FALLOS=0
export PYTHONIOENCODING=utf-8
verificar() {
  if [ "$2" = "$3" ]; then echo "OK    - $1"; else echo "FALLO - $1 (esperado=$2, obtuvo=$3)"; FALLOS=$((FALLOS+1)); fi
}
json() { python -c "import sys,json; d=json.load(sys.stdin); print(eval('d'+sys.argv[1]))" "$1"; }
sql() { docker exec vpm-mysql-test mysql -uroot -ptest1234 vip_paita_mix --default-character-set=utf8mb4 -N -e "$1" 2>/dev/null; }
post() { printf '%s' "$3" > /tmp/cuerpo.json
  curl -s -b "/tmp/ck_$1" -H "$H" -H "Content-Type: application/json" --data-binary @/tmp/cuerpo.json "$PANEL?accion=$2"; }
cod() { printf '%s' "$3" > /tmp/cuerpo.json
  curl -s -o /dev/null -w "%{http_code}" -b "/tmp/ck_$1" -H "$H" -H "Content-Type: application/json" --data-binary @/tmp/cuerpo.json "$PANEL?accion=$2"; }
titulos() { curl -s "$PUB?accion=inicio" | json "['servicios']" | python -c "import sys,ast; print('|'.join(s['titulo'] for s in ast.literal_eval(sys.stdin.read())))"; }

rm -f /tmp/ck_adm /tmp/ck_ed
curl -s -c /tmp/ck_adm -H "$H" -d "email=admin@test.com&password=claveadmin&nombre=Admin" "$PUB?accion=registrar" >/dev/null
curl -s -c /tmp/ck_ed  -H "$H" -d "email=editor@test.com&password=claveeditor&nombre=Editor" "$PUB?accion=registrar" >/dev/null
sql "UPDATE usuarios SET rol='editor' WHERE email='editor@test.com'"

echo "=== Lo que ve el visitante ==="
verificar "la web trae los 2 servicios iniciales, en orden" "DJ para tu evento|Edits a medida" "$(titulos)"
verificar "sin precios: la API no manda ningún campo de precio" "False" "$(curl -s "$PUB?accion=inicio" | json "['servicios'][0].__contains__('precio')")"

echo ""
echo "=== El admin los administra ==="
verificar "el admin ve la lista en el panel" "2" "$(curl -s -b /tmp/ck_adm "$PANEL?accion=servicios" | json "['servicios'].__len__()")"
R=$(post adm guardar_servicio '{"titulo":"Intro con tu nombre","descripcion":"Para DJs y locales.\nCon tu voz o la nuestra.","icono":"🎤","visible":true}')
NUEVO=$(echo "$R" | json "['id']")
verificar "crear un servicio nuevo" "Intro con tu nombre" "$(sql "SELECT titulo FROM servicios WHERE id='$NUEVO'")"
verificar "el nuevo va al final del orden" "3" "$(sql "SELECT orden FROM servicios WHERE id='$NUEVO'")"
verificar "el emoji se guarda bien (utf8mb4)" "🎤" "$(sql "SELECT icono FROM servicios WHERE id='$NUEVO'")"
verificar "la web ya lo muestra" "DJ para tu evento|Edits a medida|Intro con tu nombre" "$(titulos)"

PRIMERO=$(sql "SELECT id FROM servicios WHERE orden=1")
post adm intercambiar_orden "{\"tabla\":\"servicios\",\"a\":\"$PRIMERO\",\"b\":\"$NUEVO\"}" >/dev/null
verificar "reordenar (▲▼) cambia el orden en la web" "Intro con tu nombre|Edits a medida|DJ para tu evento" "$(titulos)"

post adm guardar_servicio "{\"id\":\"$NUEVO\",\"titulo\":\"Intro personalizada\",\"descripcion\":\"x\",\"icono\":\"🎤\",\"visible\":false}" >/dev/null
verificar "editar el nombre" "Intro personalizada" "$(sql "SELECT titulo FROM servicios WHERE id='$NUEVO'")"
verificar "oculto: la web ya no lo muestra" "Edits a medida|DJ para tu evento" "$(titulos)"
verificar "oculto: el panel sí lo sigue viendo" "3" "$(curl -s -b /tmp/ck_adm "$PANEL?accion=servicios" | json "['servicios'].__len__()")"

verificar "sin nombre no se guarda (400)" "400" "$(cod adm guardar_servicio '{"titulo":"  ","visible":true}')"
post adm borrar_fila "{\"tabla\":\"servicios\",\"id\":\"$NUEVO\"}" >/dev/null
verificar "borrar" "0" "$(sql "SELECT COUNT(*) FROM servicios WHERE id='$NUEVO'")"

echo ""
echo "=== Nadie más puede tocarlos ==="
verificar "un editor no ve la lista del panel (403)" "403" "$(curl -s -o /dev/null -w '%{http_code}' -b /tmp/ck_ed "$PANEL?accion=servicios")"
verificar "un editor no puede crear (403)" "403" "$(cod ed guardar_servicio '{"titulo":"Hack","visible":true}')"
verificar "un editor no puede borrar (403)" "403" "$(cod ed borrar_fila "{\"tabla\":\"servicios\",\"id\":\"$PRIMERO\"}")"
verificar "sin sesión no se puede crear (403, como el resto del panel)" "403" "$(printf '%s' '{"titulo":"x"}' > /tmp/cuerpo.json; curl -s -o /dev/null -w '%{http_code}' -H "$H" -H 'Content-Type: application/json' --data-binary @/tmp/cuerpo.json "$PANEL?accion=guardar_servicio")"
verificar "borrar_fila sigue rechazando tablas fuera de la lista" "400" "$(cod adm borrar_fila '{"tabla":"usuarios","id":"x"}')"
verificar "siguen los 2 servicios" "2" "$(sql "SELECT COUNT(*) FROM servicios")"

rm -f /tmp/ck_adm /tmp/ck_ed /tmp/cuerpo.json
echo ""
if [ "$FALLOS" -eq 0 ]; then echo "TODO OK (0 fallos)"; else echo "HAY $FALLOS FALLO(S)"; fi
exit $FALLOS

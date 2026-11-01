#!/bin/bash
# Prueba la sección "Tienda" (productos) y el video opcional de servicios/productos.
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
inicio() { curl -s "$PUB?accion=inicio"; }

rm -f /tmp/ck_adm /tmp/ck_ed
curl -s -c /tmp/ck_adm -H "$H" -d "email=admin@test.com&password=claveadmin&nombre=Admin" "$PUB?accion=registrar" >/dev/null
curl -s -c /tmp/ck_ed  -H "$H" -d "email=editor@test.com&password=claveeditor&nombre=Editor" "$PUB?accion=registrar" >/dev/null
sql "UPDATE usuarios SET rol='editor' WHERE email='editor@test.com'"

echo "=== Tienda vacía ==="
verificar "sin productos, la web recibe la lista vacía" "0" "$(inicio | json "['productos'].__len__()")"

echo ""
echo "=== El admin carga productos ==="
P1=$(post adm guardar_producto '{"nombre":"Polo VIP PAITA MIX","categoria":"Ropa","descripcion":"Tallas S a XL","precio":45,"etiqueta":"nuevo","foto":"/subidas/portadas/polo.jpg","visible":true}' | json "['id']")
P2=$(post adm guardar_producto '{"nombre":"Audífonos de cabina","categoria":"Accesorios","precio":"","etiqueta":"proximamente","visible":true}' | json "['id']")
P3=$(post adm guardar_producto '{"nombre":"Controlador usado","precio":0,"etiqueta":"agotado","video":"/subidas/previews/demo.mp4","visible":false}' | json "['id']")
verificar "se crearon los 3" "3" "$(sql "SELECT COUNT(*) FROM productos")"
verificar "quedan en orden de creación" "1,2,3" "$(sql "SELECT GROUP_CONCAT(orden ORDER BY orden) FROM productos")"
verificar "con precio: se guarda el número" "45.00" "$(sql "SELECT precio FROM productos WHERE id='$P1'")"
verificar "precio vacío -> sin precio (Consultar)" "NULL" "$(sql "SELECT IFNULL(precio,'NULL') FROM productos WHERE id='$P2'")"
verificar "precio 0 -> sin precio (Consultar)" "NULL" "$(sql "SELECT IFNULL(precio,'NULL') FROM productos WHERE id='$P3'")"
verificar "el video se guarda" "/subidas/previews/demo.mp4" "$(sql "SELECT video FROM productos WHERE id='$P3'")"

R=$(inicio)
verificar "la web solo ve los visibles" "Polo VIP PAITA MIX|Audífonos de cabina" "$(echo "$R" | json "['productos']" | python -c "import sys,ast; print('|'.join(p['nombre'] for p in ast.literal_eval(sys.stdin.read())))")"
verificar "el precio llega como número (no como texto)" "True" "$(echo "$R" | json "['productos'][0]['precio'] == 45 and type(d['productos'][0]['precio']) in (int, float)")"
verificar "sin precio llega como null" "None" "$(echo "$R" | json "['productos'][1]['precio']")"
verificar "el panel ve los 3 (también el oculto)" "3" "$(curl -s -b /tmp/ck_adm "$PANEL?accion=productos" | json "['productos'].__len__()")"

verificar "etiqueta inventada -> 400" "400" "$(cod adm guardar_producto '{"nombre":"x","etiqueta":"oferta"}')"
verificar "sin nombre -> 400" "400" "$(cod adm guardar_producto '{"nombre":" "}')"

post adm intercambiar_orden "{\"tabla\":\"productos\",\"a\":\"$P1\",\"b\":\"$P2\"}" >/dev/null
verificar "reordenar cambia el orden en la web" "Audífonos de cabina" "$(inicio | json "['productos'][0]['nombre']")"
post adm guardar_producto "{\"id\":\"$P2\",\"nombre\":\"Audífonos de cabina\",\"precio\":120,\"etiqueta\":\"\",\"visible\":true}" >/dev/null
verificar "editar: ya tiene precio y sin etiqueta" "120.00|" "$(sql "SELECT CONCAT(precio,'|',etiqueta) FROM productos WHERE id='$P2'")"

echo ""
echo "=== Video en servicios ==="
S1=$(sql "SELECT id FROM servicios ORDER BY orden LIMIT 1")
post adm guardar_servicio "{\"id\":\"$S1\",\"titulo\":\"DJ para tu evento\",\"video\":\"/subidas/previews/evento.mp4\",\"visible\":true}" >/dev/null
verificar "el servicio guarda su video" "/subidas/previews/evento.mp4" "$(inicio | json "['servicios'][0]['video']")"

echo ""
echo "=== Nadie más puede tocarlos ==="
verificar "un editor no ve los productos del panel (403)" "403" "$(curl -s -o /dev/null -w '%{http_code}' -b /tmp/ck_ed "$PANEL?accion=productos")"
verificar "un editor no puede crear (403)" "403" "$(cod ed guardar_producto '{"nombre":"Hack"}')"
verificar "un editor no puede borrar (403)" "403" "$(cod ed borrar_fila "{\"tabla\":\"productos\",\"id\":\"$P1\"}")"
post adm borrar_fila "{\"tabla\":\"productos\",\"id\":\"$P3\"}" >/dev/null
verificar "el admin sí puede borrar" "2" "$(sql "SELECT COUNT(*) FROM productos")"

rm -f /tmp/ck_adm /tmp/ck_ed /tmp/cuerpo.json
echo ""
if [ "$FALLOS" -eq 0 ]; then echo "TODO OK (0 fallos)"; else echo "HAY $FALLOS FALLO(S)"; fi
exit $FALLOS

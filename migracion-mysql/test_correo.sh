#!/bin/bash
# Prueba el correo de "Olvidé mi contraseña". El servidor PHP de prueba debe
# correr con un sendmail falso que guarda cada correo en /tmp/correos.txt
# (ver el arranque del contenedor en el commit). Base de datos limpia.
PUB="http://127.0.0.1:8099/api/publica.php"; H="X-VPM: 1"
FALLOS=0
export PYTHONIOENCODING=utf-8
verificar() {
  if [ "$2" = "$3" ]; then echo "OK    - $1"; else echo "FALLO - $1 (esperado=$2, obtuvo=$3)"; FALLOS=$((FALLOS+1)); fi
}
correos() { MSYS_NO_PATHCONV=1 docker exec vpm-php-test cat /tmp/correos.txt 2>/dev/null; }
cuantos() { correos | grep -c '^To: '; }
olvide() { curl -s -H "$H" "${@:2}" -d "email=$1" "$PUB?accion=olvide"; }

curl -s -H "$H" -d "email=admin@test.com&password=claveadmin&nombre=Ronald" "$PUB?accion=registrar" >/dev/null
curl -s -H "$H" -d "email=cliente@test.com&password=clave123&nombre=Cliente" "$PUB?accion=registrar" >/dev/null
MSYS_NO_PATHCONV=1 docker exec vpm-php-test sh -c ': > /tmp/correos.txt'

echo "=== El correo sale bien ==="
R=$(olvide cliente@test.com)
verificar "la respuesta no revela nada" "Si el correo existe, te llegará un enlace para cambiar tu contraseña." "$(echo "$R" | python -c "import sys,json; print(json.load(sys.stdin)['mensaje'])")"
verificar "se envió 1 correo" "1" "$(cuantos)"
verificar "va al correo de la cuenta" "To: cliente@test.com" "$(correos | grep '^To: ')"
verificar "sale de la cuenta del sitio" "From: VIP PAITA MIX <no-responder@vippaitamix.com>" "$(correos | grep '^From: ')"
verificar "con el remitente de sobre (-f), para no caer en spam" "1" "$(correos | grep -c 'ARGS:.*-fno-responder@vippaitamix.com')"
ASUNTO=$(correos | grep '^Subject: ' | sed 's/^Subject: //' | python -c "import sys,email.header; print(str(email.header.make_header(email.header.decode_header(sys.stdin.read().strip()))))")
verificar "el asunto llega con su tilde" "Restablece tu contraseña de VIP PAITA MIX" "$ASUNTO"
ENLACE=$(correos | grep -oE 'http[^ ]+\?restablecer=[0-9a-f]{64}')
verificar "el enlace apunta al sitio configurado" "http://127.0.0.1:8099/?restablecer=" "${ENLACE%%restablecer=*}restablecer="

echo ""
echo "=== El enlace del correo funciona ==="
TOKEN=${ENLACE##*=}
curl -s -H "$H" -d "token=$TOKEN&password=desdeelcorreo1" "$PUB?accion=restablecer" >/dev/null
verificar "con la clave elegida desde el correo, entra" "True" "$(curl -s -H "$H" -d 'email=cliente@test.com&password=desdeelcorreo1' "$PUB?accion=login" | python -c "import sys,json; print(json.load(sys.stdin)['ok'])")"

echo ""
echo "=== Abusos ==="
MSYS_NO_PATHCONV=1 docker exec vpm-php-test sh -c ': > /tmp/correos.txt'
olvide admin@test.com -H "Host: sitio-del-atacante.com" >/dev/null
verificar "con un Host falso, el enlace sigue apuntando al sitio real" "1" "$(correos | grep -c 'http://127.0.0.1:8099/?restablecer=')"
verificar "y en ningún lado aparece el sitio del atacante" "0" "$(correos | grep -c 'atacante')"
olvide admin@test.com >/dev/null; olvide admin@test.com >/dev/null
verificar "pedirlo 3 veces seguidas manda 1 solo correo (no se llena el buzón de nadie)" "1" "$(cuantos)"
olvide noexiste@test.com >/dev/null
verificar "a un correo que no tiene cuenta no se le manda nada" "1" "$(cuantos)"

echo ""
if [ "$FALLOS" -eq 0 ]; then echo "TODO OK (0 fallos)"; else echo "HAY $FALLOS FALLO(S)"; fi
exit $FALLOS

// Prueba de punta a punta de la web pública (web/index.html) con un navegador
// real, contra el servidor PHP + MySQL de prueba en http://127.0.0.1:8099.
// Requiere: npm i playwright, y los datos sembrados por el bloque de arranque
// (admin ya registrado, tracks t-gratis / t-normal / t-venta / t-premium).
const { chromium } = require('playwright');
const { execSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const BASE = 'http://127.0.0.1:8099/';
const env = { ...process.env, MSYS_NO_PATHCONV: '1' };
const sql = q => execSync(`docker exec vpm-mysql-test mysql -uroot -ptest1234 vip_paita_mix -N -e "${q}"`,
  { env, stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();

let fallos = 0;
function verificar(titulo, esperado, obtenido) {
  const ok = String(esperado) === String(obtenido);
  console.log(`${ok ? 'OK   ' : 'FALLO'} - ${titulo}${ok ? '' : ` (esperado=${esperado}, obtuvo=${obtenido})`}`);
  if (!ok) fallos++;
}

(async () => {
  const comprobante = path.join(os.tmpdir(), 'pago-yape.jpg');
  fs.writeFileSync(comprobante, 'captura de pago de prueba');

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ acceptDownloads: true });
  const page = await ctx.newPage();
  const errores = [];
  page.on('pageerror', e => errores.push(e.message));
  const modal = () => page.locator('#modal');
  const botonModal = texto => page.locator('#mFoot button', { hasText: texto });
  const filaTrack = id => page.locator(`#lista .tr[data-id="${id}"]`);

  console.log('=== Carga inicial ===');
  await page.goto(BASE, { waitUntil: 'load' });
  await page.waitForSelector('#lista .tr:not(.tr-cab)');
  verificar('el catálogo muestra los 4 tracks visibles', 4, await page.locator('#lista .tr:not(.tr-cab)').count());
  verificar('no aparece el aviso de "catálogo de demostración"', 0, await page.locator('#avisoDemo').count());
  verificar('el nombre de la marca viene de la base de datos', true, (await page.title()).startsWith('VIP PAITA MIX'));

  console.log('\n=== Crear cuenta ===');
  await page.click('#btnIngresar');
  await page.click('#mBody [data-tab="crear"]');
  await page.fill('#cNom', 'Cliente Prueba');
  await page.fill('#cMail', 'cliente@test.com');
  await page.fill('#cTel', '999 888 777');
  await page.fill('#cPass', 'clave123');
  await page.click('#bCrear');
  await page.waitForSelector('#mBody [data-elegir]');
  verificar('tras crear la cuenta se abre "Elige tu plan"', 'Elige tu plan', await page.textContent('#mTitle'));
  verificar('queda con la sesión iniciada (botón Mi cuenta visible)', false, await page.locator('#btnCuenta').evaluate(e => e.classList.contains('hide')));
  verificar('la cuenta nueva es "member", no admin', 'member', sql("SELECT rol FROM usuarios WHERE email='cliente@test.com'"));

  console.log('\n=== Pedir membresía ===');
  await page.locator('#mBody [data-elegir]', { hasText: 'Mensual' }).click();
  await page.setInputFiles('#cmp', comprobante);
  await botonModal('Enviar comprobante').click();
  await page.waitForFunction(() => document.querySelector('#mTitle').textContent === '¡Listo!');
  verificar('se confirma el envío del comprobante', '¡Listo!', await page.textContent('#mTitle'));
  verificar('la membresía queda pendiente, con el precio del plan', 'pendiente 40.00', sql("SELECT CONCAT(estado,' ',monto) FROM memberships"));
  await botonModal('Entendido').click();

  console.log('\n=== Descargar sin membresía activa ===');
  await filaTrack('t-normal').locator('.dl').click();
  await page.waitForFunction(() => document.querySelector('#modal').classList.contains('on'));
  verificar('con la membresía pendiente, pide membresía en vez de descargar', 'Necesitas una membresía', await page.textContent('#mTitle'));
  await page.keyboard.press('Escape');

  console.log('\n=== El admin aprueba y se descarga ===');
  sql("UPDATE memberships SET estado='activa', inicio=CURDATE(), fin=DATE_ADD(CURDATE(), INTERVAL 30 DAY)");
  await page.reload({ waitUntil: 'load' });
  await page.waitForSelector('#lista .tr:not(.tr-cab)');
  await page.waitForFunction(() => !document.querySelector('#btnCuenta').classList.contains('hide'));
  verificar('tras recargar, la sesión sigue iniciada', false, await page.locator('#btnCuenta').evaluate(e => e.classList.contains('hide')));
  const [descarga] = await Promise.all([page.waitForEvent('download'), filaTrack('t-normal').locator('.dl').click()]);
  verificar('el archivo baja con el nombre limpio del track', 'Normal.mp3', descarga.suggestedFilename());
  verificar('el contenido es el archivo real', 'audio normal', fs.readFileSync(await descarga.path(), 'utf8'));
  verificar('la descarga quedó registrada', '1', sql("SELECT descargas FROM tracks WHERE id='t-normal'"));

  await filaTrack('t-premium').locator('.dl').click();
  await page.waitForFunction(() => document.querySelector('#modal').classList.contains('on'));
  verificar('con plan Mensual, el track premium (Anual+) sigue bloqueado', true, (await page.textContent('#mBody')).includes('premium'));
  await page.keyboard.press('Escape');

  console.log('\n=== Mi cuenta ===');
  await page.click('#btnCuenta');
  await page.waitForFunction(() => document.querySelector('#mTitle').textContent === 'Mi cuenta');
  const cuerpoCuenta = await page.textContent('#mBody');
  verificar('muestra la membresía activa', true, cuerpoCuenta.includes('Activa'));
  verificar('muestra el plan', true, cuerpoCuenta.includes('Mensual'));
  verificar('el historial incluye la descarga recién hecha', true, cuerpoCuenta.includes('Normal'));
  await page.keyboard.press('Escape');

  console.log('\n=== Compra suelta ===');
  // con plan activo, "A la venta" ya se descarga directo (su plan la cubre):
  verificar('un track a la venta que el plan cubre se ofrece para descargar, no para comprar', '',
    await filaTrack('t-venta').locator('.dl').getAttribute('data-comprar'));
  // para comprar hace falta uno que el plan NO cubra: el premium, puesto a la venta
  sql("UPDATE tracks SET precio=7 WHERE id='t-premium'");
  await page.reload({ waitUntil: 'load' });
  await page.waitForFunction(() => !document.querySelector('#btnCuenta').classList.contains('hide'));
  await filaTrack('t-premium').locator('.dl').click();
  await page.waitForFunction(() => !document.querySelector('#btnCarrito').classList.contains('hide'));
  await page.click('#btnCarrito');
  await botonModal('Pagar').click();
  await page.setInputFiles('#cmpC', comprobante);
  await botonModal('Enviar comprobante').click();
  await page.waitForFunction(() => document.querySelector('#mTitle').textContent === '¡Listo!');
  verificar('la compra queda pendiente con el total correcto', 'pendiente 7.00', sql("SELECT CONCAT(estado,' ',monto) FROM compras"));
  verificar('el carrito se vacía', true, await page.locator('#btnCarrito').evaluate(e => e.classList.contains('hide')));
  await botonModal('Entendido').click();

  console.log('\n=== Reproducir ===');
  await filaTrack('t-gratis').locator('.art').click();
  await page.waitForTimeout(1200);
  verificar('reproducir registra el play', '1', sql("SELECT COUNT(*) FROM plays WHERE track_id='t-gratis'"));

  console.log('\n=== Contacto ===');
  const nuevaPestana = ctx.waitForEvent('page').catch(() => null); // abre WhatsApp
  await page.fill('#formContacto [name="nombre"]', 'Organizador');
  await page.fill('#formContacto [name="email"]', 'evento@test.com');
  await page.fill('#formContacto [name="mensaje"]', 'Quiero cotizar un evento en Paita');
  await page.click('#formContacto [type="submit"]');
  const wa = await nuevaPestana; if (wa) await wa.close();
  await page.waitForTimeout(800);
  verificar('el formulario de contacto guarda la solicitud', 'Organizador', sql('SELECT nombre FROM bookings'));

  console.log('\n=== Cerrar sesión e ingresar ===');
  await page.click('#btnCuenta');
  // cerrar sesión recarga la página: hay que esperar esa recarga, no el estado
  // "load" de la página vieja (que ya estaba cargada y daría falso negativo)
  await Promise.all([page.waitForNavigation({ waitUntil: 'load' }), botonModal('Cerrar sesión').click()]);
  await page.waitForSelector('#lista .tr:not(.tr-cab)');
  verificar('tras cerrar sesión vuelve el botón Ingresar', false, await page.locator('#btnIngresar').evaluate(e => e.classList.contains('hide')));
  await page.click('#btnIngresar');
  await page.fill('#sMail', 'cliente@test.com');
  await page.fill('#sPass', 'clave-mala');
  await page.click('#bEntrar');
  await page.waitForFunction(() => document.querySelector('#sMsg').textContent.length > 0);
  verificar('con la clave equivocada muestra el error', true, (await page.textContent('#sMsg')).includes('incorrectos'));

  console.log('\n=== Recuperar contraseña desde el enlace del correo ===');
  const token = execSync(
    `docker exec vpm-php-test php -r "require 'auth.php'; $pdo=new PDO('mysql:host=vpm-mysql-test;dbname=vip_paita_mix','root','test1234'); echo solicitar_restablecer($pdo,'cliente@test.com');"`,
    { env }).toString().trim();
  await page.goto(`${BASE}?restablecer=${token}`, { waitUntil: 'load' });
  await page.waitForSelector('#rPass');
  await page.fill('#rPass', 'nuevaclave1');
  await botonModal('Guardar contraseña').click();
  await page.waitForSelector('#sMail');
  verificar('tras guardar, la dirección queda limpia (sin el token)', '', new URL(page.url()).search);
  await page.fill('#sMail', 'cliente@test.com');
  await page.fill('#sPass', 'nuevaclave1');
  await page.click('#bEntrar');
  await page.waitForFunction(() => !document.querySelector('#btnCuenta').classList.contains('hide'));
  verificar('ingresa con la contraseña nueva', false, await page.locator('#btnCuenta').evaluate(e => e.classList.contains('hide')));

  verificar('ningún error de JavaScript en todo el recorrido', '[]', JSON.stringify(errores));
  await browser.close();
  fs.unlinkSync(comprobante);
  console.log('\n' + (fallos === 0 ? 'TODO OK (0 fallos)' : `HAY ${fallos} FALLO(S)`));
  process.exit(fallos ? 1 : 0);
})().catch(e => { console.error('FALLÓ:', e); process.exit(1); });

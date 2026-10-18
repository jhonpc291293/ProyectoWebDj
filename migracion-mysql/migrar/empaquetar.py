"""
VIP PAITA MIX · Fase 7: empaqueta la exportación para subirla al hosting.

Toma la carpeta de salida de exportar.js y genera, en la carpeta indicada:
  vippaitamix-datos.sql    -> phpMyAdmin > Importar (borra las tablas de prueba,
                              crea la estructura y carga los datos reales)
  vippaitamix-subidas.zip  -> Administrador de archivos: extraer en public_html
  vippaitamix-privado.zip  -> Administrador de archivos: extraer en /home/<cuenta>

Los ZIP llevan permisos de Unix (0644 archivos, 0755 carpetas): sin eso,
cPanel los descomprime en 0600 y Apache responde 403 a todo.

Uso:  python empaquetar.py <carpeta_salida> <carpeta_destino>
"""
import os
import sys
import zipfile

AQUI = os.path.dirname(os.path.abspath(__file__))
SAL = sys.argv[1] if len(sys.argv) > 1 else os.path.join(AQUI, 'salida')
DEST = sys.argv[2] if len(sys.argv) > 2 else SAL

TABLAS = ['plays', 'downloads', 'compra_tracks', 'compras', 'memberships', 'track_files',
          'tracks', 'planes', 'comunicados', 'crew', 'settings', 'bookings', 'usuarios']

PROTECCION_SUBIDAS = (
    '# Archivos subidos por el panel: aquí nunca se ejecuta código\n'
    '<FilesMatch "\\.(php[0-9]?|phtml|phar|pht|cgi|pl|py|sh)$">\n'
    '  Require all denied\n'
    '</FilesMatch>\n'
    'Options -Indexes -ExecCGI\n'
)


def sql_completo():
    cab = ('-- VIP PAITA MIX: carga completa en el hosting.\n'
           '-- Borra TODAS las tablas de la base y las vuelve a crear con los datos exportados de Supabase.\n'
           'SET FOREIGN_KEY_CHECKS = 0;\n'
           + ''.join(f'DROP TABLE IF EXISTS {t};\n' for t in TABLAS)
           + 'SET FOREIGN_KEY_CHECKS = 1;\n\n')
    with open(os.path.join(AQUI, '..', 'schema.sql'), encoding='utf-8') as f:
        schema = f.read()
    with open(os.path.join(SAL, 'datos.sql'), encoding='utf-8') as f:
        datos = f.read()
    destino = os.path.join(DEST, 'vippaitamix-datos.sql')
    with open(destino, 'w', encoding='utf-8', newline='\n') as f:
        f.write(cab + schema + '\n' + datos)
    return destino


def zip_unix(carpeta, destino, extra=None):
    """Comprime 'carpeta' (incluido su nombre) con permisos de Unix."""
    n = 0
    base = os.path.dirname(carpeta)
    with zipfile.ZipFile(destino, 'w', zipfile.ZIP_DEFLATED) as z:
        def agregar(nombre, contenido, es_carpeta=False):
            zi = zipfile.ZipInfo(nombre + ('/' if es_carpeta else ''))
            zi.create_system = 3  # "hecho en Unix": así el descompresor respeta los permisos
            modo = 0o40755 if es_carpeta else 0o100644
            zi.external_attr = (modo << 16) | (0x10 if es_carpeta else 0)
            zi.compress_type = zipfile.ZIP_STORED if es_carpeta else zipfile.ZIP_DEFLATED
            z.writestr(zi, contenido)

        for raiz, _, archivos in os.walk(carpeta):
            rel = os.path.relpath(raiz, base).replace(os.sep, '/')
            agregar(rel, b'', es_carpeta=True)
            for a in sorted(archivos):
                with open(os.path.join(raiz, a), 'rb') as f:
                    agregar(f'{rel}/{a}', f.read())
                n += 1
        for nombre, texto in (extra or {}).items():
            agregar(nombre, texto.encode('utf-8'))
            n += 1
    return n


if __name__ == '__main__':
    os.makedirs(DEST, exist_ok=True)
    sql = sql_completo()
    n1 = zip_unix(os.path.join(SAL, 'subidas'), os.path.join(DEST, 'vippaitamix-subidas.zip'),
                  {'subidas/.htaccess': PROTECCION_SUBIDAS})
    n2 = zip_unix(os.path.join(SAL, 'privado'), os.path.join(DEST, 'vippaitamix-privado.zip'))
    for nombre in ('vippaitamix-datos.sql', 'vippaitamix-subidas.zip', 'vippaitamix-privado.zip'):
        print(f'{nombre}: {os.path.getsize(os.path.join(DEST, nombre)) / 1048576:.1f} MB')
    print(f'archivos dentro: subidas {n1} (incluye su .htaccess) · privado {n2}')

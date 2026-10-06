project('singularity-browser', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
gnome = import('gnome')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-browser"', language: 'c')
subdir('po')

gtk_dep     = dependency('gtk4')
gee_dep     = dependency('gee-0.8')
json_dep    = dependency('json-glib-1.0')
xml_dep     = dependency('libxml-2.0')
sqlite_dep  = dependency('sqlite3')
soup_dep    = dependency('libsoup-3.0')
webkit_dep  = dependency('webkitgtk-6.0')
secret_dep  = dependency('libsecret-1')
gnutls_dep  = dependency('gnutls')
polkit_dep  = dependency('polkit-gobject-1')
fido_dep    = dependency('libfido2')
fido_lib    = static_library('browser-fido', 'src/fido_device.c', dependencies: [dependency('glib-2.0'), fido_dep])
poppler_dep = dependency('poppler-glib')
math_dep    = meson.get_compiler('c').find_library('m', required: true)
gio_unix_dep = dependency('gio-unix-2.0')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

app_id = 'dev.sinty.browser'

resources = gnome.compile_resources(
  'singularity-browser-resources',
  'resources/dev.sinty.browser.gresource.xml',
  source_dir: 'resources'
)

core = files(
  'src/address.vala',
  'src/util.vala',
  'src/store.vala',
  'src/bookmark_import.vala',
  'src/filter_compiler.vala',
  'src/reader.vala',
)

executable('singularity-browser',
  core + files(
    'src/main.vala',
    'src/services.vala',
    'src/profile.vala',
    'src/content_blocker.vala',
    'src/passwords.vala',
    'src/passkey_crypto.vapi',
    'src/passkey_crypto.c',
    'src/webauthn.vala',
    'src/webauthn_ui.vala',
    'src/fido_device.vapi',
    'src/cable_crypto.vapi',
    'src/cable_crypto.c',
    'src/cable.vala',
    'src/cable_session.vala',
    'src/vault_crypto.vapi',
    'src/vault_crypto.c',
    'src/vault_envelope.vala',
    'src/vault_roster.vala',
    'src/vault_ledger.vala',
    'src/vault_dataset.vala',
    'src/vault_keys.vala',
    'src/vault_sync.vala',
    'src/vault_bridge.vala',
    'src/vault_enrollment.vala',
    'src/vault_transport.vala',
    'src/downloads.vala',
    'src/pages.vala',
    'src/tab.vala',
    'src/sketch.vala',
    'src/tile.vala',
    'src/url_bubble.vala',
    'src/webapps.vala',
    'src/print.vala',
    'src/search_provider.vala',
    'src/window.vala',
    'src/app.vala',
  ) + resources,
  dependencies: [gtk_dep, gee_dep, json_dep, xml_dep, sqlite_dep, soup_dep, webkit_dep,
                 secret_dep, poppler_dep, math_dep, gio_unix_dep, libsingularity_dep, gnutls_dep, polkit_dep],
  link_with: fido_lib,
  include_directories: include_directories('src'),
  install: true,
  install_rpath: get_option('prefix') / get_option('libdir')
)

browser_test = executable('browser-test',
  core + files('tests/browser_test.vala'),
  dependencies: [gtk_dep, gee_dep, json_dep, xml_dep, sqlite_dep, math_dep],
)
foreach suite : ['address', 'store', 'import', 'filters', 'reader']
  test(suite, browser_test,
    args: ['-p', '/' + suite],
    env: ['TMPDIR=' + meson.current_build_dir(), 'BROWSER_FIXTURES=' + meson.current_source_dir() / 'tests' / 'fixtures'])
endforeach

filter_check = executable('filter-webkit-check',
  core + files('tests/filter_webkit_check.vala'),
  dependencies: [gtk_dep, gee_dep, json_dep, xml_dep, sqlite_dep, webkit_dep, math_dep],
)
test('filters-webkit', filter_check,
  env: ['TMPDIR=' + meson.current_build_dir(), 'BROWSER_FIXTURES=' + meson.current_source_dir() / 'tests' / 'fixtures'],
  timeout: 120)

password_check = executable('password-webkit-check',
  core + files('src/passwords.vala', 'tests/password_webkit_check.vala'),
  dependencies: [gtk_dep, gee_dep, json_dep, xml_dep, sqlite_dep, webkit_dep, soup_dep, secret_dep, math_dep],
)

secret_check = executable('password-secret-check',
  core + files('src/passwords.vala', 'tests/password_secret_check.vala'),
  dependencies: [gtk_dep, gee_dep, json_dep, xml_dep, sqlite_dep, secret_dep, math_dep],
)

webauthn_test = executable('webauthn-test',
  core + files('src/passkey_crypto.vapi', 'src/passkey_crypto.c', 'src/webauthn.vala', 'tests/webauthn_test.vala'),
  dependencies: [gtk_dep, gee_dep, json_dep, xml_dep, sqlite_dep, secret_dep, gnutls_dep, math_dep],
  include_directories: include_directories('src'),
)
test('webauthn', webauthn_test)

cable_test = executable('cable-test',
  core + files('src/passkey_crypto.vapi', 'src/passkey_crypto.c', 'src/cable_crypto.vapi', 'src/cable_crypto.c', 'src/webauthn.vala', 'src/cable.vala', 'tests/cable_test.vala'),
  dependencies: [gtk_dep, gee_dep, json_dep, xml_dep, sqlite_dep, secret_dep, gnutls_dep, math_dep],
  include_directories: include_directories('src'),
)
test('cable', cable_test, env: ['CABLE_RESPONDER=' + meson.current_source_dir() / 'tests' / 'cable_responder.py'])

password_import_test = executable('password-import-test',
  core + files('src/passwords.vala', 'tests/password_import_test.vala'),
  dependencies: [gtk_dep, gee_dep, json_dep, xml_dep, sqlite_dep, secret_dep, math_dep],
)
test('password-import', password_import_test)

vault_test = executable('vault-test',
  files('src/vault_crypto.vapi', 'src/vault_crypto.c', 'src/vault_envelope.vala', 'src/vault_roster.vala', 'src/vault_ledger.vala', 'src/vault_dataset.vala', 'tests/vault_test.vala', 'tests/vault_ledger_test.vala', 'tests/vault_dataset_test.vala'),
  dependencies: [gtk_dep, gnutls_dep, gee_dep, json_dep, sqlite_dep],
  include_directories: include_directories('src'),
)

vault_transport_check = executable('vault-transport-check',
  files('src/vault_crypto.vapi', 'src/vault_crypto.c', 'src/vault_envelope.vala', 'src/vault_roster.vala', 'src/vault_ledger.vala', 'src/vault_transport.vala', 'tests/vault_transport_check.vala'),
  dependencies: [gtk_dep, gnutls_dep, gee_dep, json_dep, sqlite_dep, soup_dep, libsingularity_dep],
  include_directories: include_directories('src'),
)

vault_keys_check = executable('vault-keys-check',
  core + files('src/profile.vala', 'src/vault_crypto.vapi', 'src/vault_crypto.c', 'src/vault_envelope.vala', 'src/vault_roster.vala', 'src/vault_ledger.vala', 'src/vault_transport.vala', 'src/vault_keys.vala', 'tests/vault_keys_check.vala'),
  dependencies: [gtk_dep, gnutls_dep, gee_dep, json_dep, sqlite_dep, soup_dep, libsingularity_dep, secret_dep, webkit_dep, xml_dep, math_dep],
  include_directories: include_directories('src'),
)

vault_sync_check = executable('vault-sync-check',
  core + files('src/profile.vala', 'src/vault_crypto.vapi', 'src/vault_crypto.c', 'src/vault_envelope.vala', 'src/vault_roster.vala', 'src/vault_ledger.vala', 'src/vault_dataset.vala', 'src/vault_transport.vala', 'src/vault_keys.vala', 'src/vault_sync.vala', 'tests/vault_sync_check.vala'),
  dependencies: [gtk_dep, gnutls_dep, gee_dep, json_dep, sqlite_dep, soup_dep, libsingularity_dep, secret_dep, webkit_dep, xml_dep, math_dep],
  include_directories: include_directories('src'),
)

vault_bridge_check = executable('vault-bridge-check',
  core + files('src/profile.vala', 'src/passwords.vala', 'src/vault_crypto.vapi', 'src/vault_crypto.c', 'src/vault_envelope.vala', 'src/vault_roster.vala', 'src/vault_ledger.vala', 'src/vault_dataset.vala', 'src/vault_transport.vala', 'src/vault_keys.vala', 'src/vault_sync.vala', 'src/vault_bridge.vala', 'tests/vault_bridge_check.vala'),
  dependencies: [gtk_dep, gnutls_dep, gee_dep, json_dep, sqlite_dep, soup_dep, libsingularity_dep, secret_dep, webkit_dep, xml_dep, math_dep],
  include_directories: include_directories('src'),
)

vault_enrollment_check = executable('vault-enrollment-check',
  core + files('src/profile.vala', 'src/passwords.vala', 'src/vault_crypto.vapi', 'src/vault_crypto.c', 'src/vault_envelope.vala', 'src/vault_roster.vala', 'src/vault_ledger.vala', 'src/vault_dataset.vala', 'src/vault_transport.vala', 'src/vault_keys.vala', 'src/vault_sync.vala', 'src/vault_bridge.vala', 'src/vault_enrollment.vala', 'tests/vault_enrollment_check.vala'),
  dependencies: [gtk_dep, gnutls_dep, gee_dep, json_dep, sqlite_dep, soup_dep, libsingularity_dep, secret_dep, webkit_dep, xml_dep, math_dep],
  include_directories: include_directories('src'),
)

conf = configuration_data()
conf.set('APP_ID', app_id)
conf.set('NAME', 'Browser')
conf.set('OBJECT_PATH', '/' + app_id.replace('.', '/'))
conf.set('bindir', get_option('prefix') / get_option('bindir'))

configure_file(
  input: 'data/browser.desktop.in',
  output: app_id + '.desktop',
  configuration: conf,
  install: true,
  install_dir: get_option('datadir') / 'applications'
)
configure_file(
  input: 'data/browser.search-provider.ini.in',
  output: app_id + '.ini',
  configuration: conf,
  install: true,
  install_dir: get_option('datadir') / 'singularity' / 'search-providers'
)
configure_file(
  input: 'data/browser.service.in',
  output: app_id + '.service',
  configuration: conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

install_data('data/dev.sinty.browser.passkey.policy',
  install_dir: get_option('datadir') / 'polkit-1' / 'actions'
)

install_data('data/dev.sinty.browser.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data('data/dev.sinty.browser.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)

install_data('data/icons/dev.sinty.browser.svg', 'data/icons/dev.sinty.browser-private.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

install_data('resources/icons/browser-private-symbolic.svg',
  rename: app_id + '-private-symbolic.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'symbolic' / 'apps'
)

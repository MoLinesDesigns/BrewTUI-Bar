#!/usr/bin/env node
// Single source of truth for "the app and the CLI ship the same version".
//
// The two products live in separate repos but must carry the same version:
// AppDelegate's VersionChecker warns the user when they drift, the cask's
// `depends_on formula` pairs them, and the CLI's prepublish guard looks for a
// GitHub release tagged with *its own* version in the *app's* repo — so a
// mismatch is only discovered at `npm publish`, after the app has already been
// notarised and released. This moves that check to the front.
//
//   node scripts/version-sync.mjs check        compare, exit 1 on mismatch
//   node scripts/version-sync.mjs set X.Y.Z    write X.Y.Z into both repos
//
// The CLI checkout is located via $BREWTUI_CLI_PATH, falling back to the
// conventional path. `check` degrades to reading the CLI's package.json from
// GitHub when no local checkout is present, so it still works on a machine
// that only has one of the two repos; `set` requires the local checkout.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const APP_PKG = resolve(__dirname, '..', 'package.json');
const CLI_REPO = process.env.BREWTUI_CLI_PATH || '/Volumes/SSD/Projects/BrewTUI-Bar';
const CLI_PKG = resolve(CLI_REPO, 'package.json');
const CLI_RAW =
  'https://raw.githubusercontent.com/MoLinesDesigns/BrewTUI/main/package.json';

const SEMVER = /^\d+\.\d+\.\d+$/;

const readVersion = (path) => JSON.parse(readFileSync(path, 'utf8')).version;

/** Rewrites only the version line, so formatting and key order survive. */
function writeVersion(path, version) {
  const raw = readFileSync(path, 'utf8');
  const field = /^(\s*"version"\s*:\s*)"[^"]+"/m;
  // Se comprueba con test(), no comparando el resultado: si el fichero ya
  // estaba en la version pedida el reemplazo es identico, y eso es exito, no
  // un campo ausente.
  if (!field.test(raw)) {
    console.error(`✘ No pude localizar el campo "version" en ${path}`);
    process.exit(1);
  }
  writeFileSync(path, raw.replace(field, `$1"${version}"`));
}

async function cliVersion() {
  if (existsSync(CLI_PKG)) return { version: readVersion(CLI_PKG), source: CLI_PKG };
  try {
    const res = await fetch(CLI_RAW, { headers: { 'User-Agent': 'brewtui-bar-version-sync' } });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return { version: (await res.json()).version, source: `${CLI_RAW} (remoto)` };
  } catch (err) {
    console.error(`✘ No hay checkout del CLI en ${CLI_REPO} y GitHub falló: ${err.message}`);
    console.error('  Clónalo o exporta BREWTUI_CLI_PATH=/ruta/al/repo/del/CLI');
    process.exit(1);
  }
}

const [command, argument] = process.argv.slice(2);

if (command === 'check') {
  const app = readVersion(APP_PKG);
  const { version: cli, source } = await cliVersion();

  if (app === cli) {
    console.log(`✓ Versiones sincronizadas: ${app} (app y CLI)`);
    process.exit(0);
  }

  console.error('✘ La app y el CLI tienen versiones distintas:');
  console.error(`    app  ${app}   ${APP_PKG}`);
  console.error(`    CLI  ${cli}   ${source}`);
  console.error('');
  console.error('  Iguálalas antes de seguir:');
  console.error(`    npm run version:set ${app > cli ? app : cli}`);
  process.exit(1);
}

if (command === 'set') {
  if (!SEMVER.test(argument ?? '')) {
    console.error('✘ Uso: npm run version:set X.Y.Z');
    process.exit(1);
  }
  if (!existsSync(CLI_PKG)) {
    console.error(`✘ 'set' necesita el checkout del CLI. No está en ${CLI_REPO}.`);
    console.error('  Exporta BREWTUI_CLI_PATH=/ruta/al/repo/del/CLI');
    process.exit(1);
  }

  writeVersion(APP_PKG, argument);
  writeVersion(CLI_PKG, argument);

  console.log(`✓ ${argument} escrito en los dos repos:`);
  console.log(`    ${APP_PKG}`);
  console.log(`    ${CLI_PKG}`);
  console.log('');
  console.log('  Quedan por hacer, en este orden (ver CLAUDE.md):');
  console.log('    1. commit + tag vX.Y.Z + push en los dos repos');
  console.log('    2. NOTARY_PROFILE=brewbar-notary ./scripts/release.sh');
  console.log('    3. gh release create con los assets .app.zip y .sha256');
  console.log('    4. bump del cask (version + sha256)');
  console.log('    5. npm publish en el CLI');
  process.exit(0);
}

console.error('Uso: node scripts/version-sync.mjs check | set X.Y.Z');
process.exit(1);

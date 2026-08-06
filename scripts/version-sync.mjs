#!/usr/bin/env node
// Single source of truth for "everything ships the same version".
//
// Six places carry the version and all six must agree:
//   1. this repo's package.json      (feeds MARKETING_VERSION via Project.swift)
//   2. the CLI repo's package.json   (the npm package)
//   3. the published npm package
//   4. the GitHub release tag + assets
//   5. the tap's Casks/brewtui-bar.rb   (the app)
//   6. the tap's Formula/brewtui-bar.rb (the CLI, pulled in by the cask's
//      depends_on — this is the one that got missed in 5.0.1, which would have
//      shipped the 5.0.1 app against the 5.0.0 CLI and made VersionChecker
//      nag on every launch)
//
//   check              app vs CLI, exit 1 on drift. Tap reported as a warning
//                      because release.sh runs this *before* notarising, when
//                      the tap legitimately still points at the old version.
//   check --tap        same, but tap drift is also an error
//   status             report all six, exit 1 if anything disagrees
//   set X.Y.Z          write X.Y.Z into both package.json files
//   sync-tap           point cask + formula at the current version, with the
//                      sha256 of the real published artefacts
//
// Paths are overridable: $BREWTUI_CLI_PATH, $BREWTUI_TAP_PATH.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const APP_PKG = resolve(__dirname, '..', 'package.json');
const CLI_REPO = process.env.BREWTUI_CLI_PATH || '/Volumes/SSD/Projects/BrewTUI-Bar';
const CLI_PKG = resolve(CLI_REPO, 'package.json');
const TAP = process.env.BREWTUI_TAP_PATH || '/opt/homebrew/Library/Taps/molinesdesigns/homebrew-tap';
const CASK = resolve(TAP, 'Casks', 'brewtui-bar.rb');
const FORMULA = resolve(TAP, 'Formula', 'brewtui-bar.rb');

const APP_REPO = 'MoLinesDesigns/BrewTUI-Bar';
const CLI_RAW = 'https://raw.githubusercontent.com/MoLinesDesigns/BrewTUI/main/package.json';
const UA = { 'User-Agent': 'brewtui-bar-version-sync' };

const SEMVER = /^\d+\.\d+\.\d+$/;
const VERSION_FIELD = /^(\s*"version"\s*:\s*)"[^"]+"/m;
const CASK_VERSION = /^(\s*version\s+)"([^"]+)"/m;
const CASK_SHA = /^(\s*sha256\s+)"([^"]+)"/m;
const FORMULA_URL = /brewtui-bar-(\d+\.\d+\.\d+)\.tgz/;
const FORMULA_SHA = /^(\s*sha256\s+)"([^"]+)"/m;

const readVersion = (path) => JSON.parse(readFileSync(path, 'utf8')).version;
const readIf = (path) => (existsSync(path) ? readFileSync(path, 'utf8') : null);

/** Rewrites one field in place, so formatting and key order survive. */
function patch(path, pattern, replacement, label) {
  const raw = readFileSync(path, 'utf8');
  // Checked with test(), not by comparing the result: when the file is already
  // at the target value the replacement is identical, and that is success.
  if (!pattern.test(raw)) {
    console.error(`✘ No pude localizar ${label} en ${path}`);
    process.exit(1);
  }
  writeFileSync(path, raw.replace(pattern, replacement));
}

async function cliVersion() {
  if (existsSync(CLI_PKG)) return { version: readVersion(CLI_PKG), source: CLI_PKG };
  try {
    const res = await fetch(CLI_RAW, { headers: UA });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return { version: (await res.json()).version, source: `${CLI_RAW} (remoto)` };
  } catch (err) {
    console.error(`✘ No hay checkout del CLI en ${CLI_REPO} y GitHub falló: ${err.message}`);
    console.error('  Clónalo o exporta BREWTUI_CLI_PATH=/ruta/al/repo/del/CLI');
    process.exit(1);
  }
}

/** Cask version + formula tarball version, or null when the tap is absent. */
function tapVersions() {
  const cask = readIf(CASK);
  const formula = readIf(FORMULA);
  if (!cask && !formula) return null;
  return {
    cask: cask?.match(CASK_VERSION)?.[2] ?? null,
    formula: formula?.match(FORMULA_URL)?.[1] ?? null,
  };
}

async function sha256OfUrl(url) {
  const res = await fetch(url, { headers: UA, redirect: 'follow' });
  if (!res.ok) throw new Error(`HTTP ${res.status} en ${url}`);
  const buf = Buffer.from(await res.arrayBuffer());
  return { sha: createHash('sha256').update(buf).digest('hex'), bytes: buf.length };
}

const assetURL = (v) =>
  `https://github.com/${APP_REPO}/releases/download/v${v}/BrewTUI-Bar.app.zip`;
const tarballURL = (v) => `https://registry.npmjs.org/brewtui-bar/-/brewtui-bar-${v}.tgz`;

const [command, ...rest] = process.argv.slice(2);

// ── check ────────────────────────────────────────────────────────────────────
if (command === 'check') {
  const strictTap = rest.includes('--tap');
  const app = readVersion(APP_PKG);
  const { version: cli, source } = await cliVersion();

  if (app !== cli) {
    console.error('✘ La app y el CLI tienen versiones distintas:');
    console.error(`    app  ${app}   ${APP_PKG}`);
    console.error(`    CLI  ${cli}   ${source}`);
    console.error('');
    console.error(`  Iguálalas:  npm run version:set ${app > cli ? app : cli}`);
    process.exit(1);
  }
  console.log(`✓ Versiones sincronizadas: ${app} (app y CLI)`);

  const tap = tapVersions();
  if (!tap) {
    console.log(`· Tap no encontrado en ${TAP} — no se comprueba.`);
    process.exit(0);
  }

  const stale = [];
  if (tap.cask !== app) stale.push(`cask ${tap.cask ?? '?'}`);
  if (tap.formula !== app) stale.push(`formula ${tap.formula ?? '?'}`);

  if (stale.length === 0) {
    console.log(`✓ Tap al día: cask y formula en ${app}`);
    process.exit(0);
  }

  const line = `Tap desactualizado (${stale.join(', ')}) frente a ${app}`;
  if (strictTap) {
    console.error(`✘ ${line}`);
    console.error('  Actualízalo:  npm run version:sync-tap');
    process.exit(1);
  }
  // Aviso, no error: durante un release el tap se actualiza al final, después
  // de notarizar, así que aquí estar atrasado es lo normal.
  console.warn(`⚠ ${line}`);
  console.warn('  Normal a mitad de release; al terminar: npm run version:sync-tap');
  process.exit(0);
}

// ── status ───────────────────────────────────────────────────────────────────
if (command === 'status') {
  const app = readVersion(APP_PKG);
  const { version: cli } = await cliVersion();
  const tap = tapVersions();

  let npmVersion = null;
  try {
    const r = await fetch('https://registry.npmjs.org/brewtui-bar/latest', { headers: UA });
    if (r.ok) npmVersion = (await r.json()).version;
  } catch { /* sin red */ }

  let releaseTag = null;
  try {
    const r = await fetch(`https://api.github.com/repos/${APP_REPO}/releases/tags/v${app}`, { headers: UA });
    if (r.ok) releaseTag = (await r.json()).tag_name;
  } catch { /* sin red */ }

  const rows = [
    ['app (package.json)', app],
    ['CLI (package.json)', cli],
    ['npm publicado', npmVersion ?? '—'],
    ['GitHub release', releaseTag ?? '—'],
    ['tap · cask', tap?.cask ?? '—'],
    ['tap · formula', tap?.formula ?? '—'],
  ];
  const width = Math.max(...rows.map(([l]) => l.length));
  for (const [label, value] of rows) {
    const ok = value === app || (label === 'GitHub release' && value === `v${app}`);
    console.log(`  ${ok ? '✓' : '✗'} ${label.padEnd(width)}  ${value}`);
  }

  const bad = rows.filter(([l, v]) => !(v === app || (l === 'GitHub release' && v === `v${app}`)));
  if (bad.length > 0) {
    console.log('');
    console.log(`  ${bad.length} de ${rows.length} no coinciden con ${app}.`);
    console.log('  Un "—" suele ser "aún no publicado", no un error.');
    process.exit(1);
  }
  console.log('');
  console.log(`✓ Los ${rows.length} puntos en ${app}.`);
  process.exit(0);
}

// ── set ──────────────────────────────────────────────────────────────────────
if (command === 'set') {
  const [argument] = rest;
  if (!SEMVER.test(argument ?? '')) {
    console.error('✘ Uso: npm run version:set X.Y.Z');
    process.exit(1);
  }
  if (!existsSync(CLI_PKG)) {
    console.error(`✘ 'set' necesita el checkout del CLI. No está en ${CLI_REPO}.`);
    process.exit(1);
  }

  patch(APP_PKG, VERSION_FIELD, `$1"${argument}"`, 'el campo "version"');
  patch(CLI_PKG, VERSION_FIELD, `$1"${argument}"`, 'el campo "version"');

  console.log(`✓ ${argument} escrito en los dos repos:`);
  console.log(`    ${APP_PKG}`);
  console.log(`    ${CLI_PKG}`);
  console.log('');
  console.log('  Después, en este orden (ver CLAUDE.md):');
  console.log('    1. commit + tag vX.Y.Z + push en los dos repos');
  console.log('    2. NOTARY_PROFILE=brewbar-notary ./scripts/release.sh');
  console.log('    3. gh release create con los assets .app.zip y .sha256');
  console.log('    4. npm publish en el CLI');
  console.log('    5. npm run version:sync-tap   (cask + formula)');
  process.exit(0);
}

// ── sync-tap ─────────────────────────────────────────────────────────────────
if (command === 'sync-tap') {
  const version = readVersion(APP_PKG);
  if (!existsSync(CASK) || !existsSync(FORMULA)) {
    console.error(`✘ No encuentro el tap en ${TAP}.`);
    console.error('  Exporta BREWTUI_TAP_PATH=/ruta/al/homebrew-tap');
    process.exit(1);
  }

  // Los sha256 se calculan sobre los artefactos REALES ya publicados, no sobre
  // copias locales: es lo que descargará el usuario, y un desajuste aquí
  // rompe `brew install` con un checksum mismatch.
  console.log(`→ Descargando artefactos publicados de ${version}…`);
  let asset, tarball;
  try {
    asset = await sha256OfUrl(assetURL(version));
    tarball = await sha256OfUrl(tarballURL(version));
  } catch (err) {
    console.error(`✘ ${err.message}`);
    console.error('  ¿Están ya publicados la release de GitHub y el paquete npm?');
    process.exit(1);
  }

  console.log(`  cask    ${asset.sha}  (${(asset.bytes / 1e6).toFixed(1)} MB)`);
  console.log(`  formula ${tarball.sha}  (${(tarball.bytes / 1e6).toFixed(1)} MB)`);

  patch(CASK, CASK_VERSION, `$1"${version}"`, 'la línea version');
  patch(CASK, CASK_SHA, `$1"${asset.sha}"`, 'la línea sha256');
  patch(FORMULA, FORMULA_URL, `brewtui-bar-${version}.tgz`, 'la URL del tarball');
  patch(FORMULA, FORMULA_SHA, `$1"${tarball.sha}"`, 'la línea sha256');

  console.log('');
  console.log(`✓ Tap actualizado a ${version}:`);
  console.log(`    ${CASK}`);
  console.log(`    ${FORMULA}`);
  console.log('');
  console.log('  Queda:  brew style ambos ficheros, commit y push del tap.');
  process.exit(0);
}

console.error('Uso: node scripts/version-sync.mjs check [--tap] | status | set X.Y.Z | sync-tap');
process.exit(1);

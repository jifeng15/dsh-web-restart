/**
 * dsh-web-hot — core plugin lifecycle: install / uninstall / update /
 * enable-disable profile plugin bundles, hot through the mounted tree.
 *
 * Ported from @kyorakuyk/dsh-plugin-manager (MIT) to plain JS, trimmed to the
 * lifecycle core the dsh-web-restart skill needs. Install runs `pnpm add` in
 * the profile directory, reads the bundle's `dsh.bundle.patch` rows, writes
 * them into the profile's user patch layer (cordis.patch.yml), then
 * hot-applies the delta to the root Include entry via `include.update`.
 *
 * The user patch layer is watched by the launcher's watchUserPatches
 * (transactional HMR), so a written change mounts/unmounts entries without a
 * restart, and recomposes at boot so installs survive restarts without
 * touching dsh.profile.bundles.
 */
import { createRequire } from 'node:module'
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync, renameSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { dirname, join } from 'node:path'
import * as yaml from 'js-yaml'

const managerRequire = createRequire(import.meta.url)

/** The user patch file name inside a profile directory. */
export const PROFILE_PATCH_FILENAME = 'cordis.patch.yml'
/** State file tracking bundles installed through this manager. */
export const STATE_FILENAME = 'dsh-web-hot.state.json'
/** Header written above manager-owned rows. */
export const MANAGED_SECTION_HEADER = '# Rows managed by dsh-web-hot — edit or remove freely, or uninstall the bundle.'

/* ------------------------------------------------------------------ */
/* pnpm runner                                                         */
/* ------------------------------------------------------------------ */

const PNPM_TAIL_LIMIT = 8 * 1024

/**
 * Run pnpm in a directory, capturing output. `--config.minimumReleaseAge=0`
 * bypasses pnpm 11's 24h release-age gate for just-published bundles, and
 * `--registry` (only for install/update, which fetch) pins the official npm
 * registry so installs are not affected by the machine's npm mirror config.
 */
export function runPnpm(args, cwd, timeoutMs = 600_000) {
  return new Promise((resolve, reject) => {
    const needsRegistry = args[0] === 'add' || args[0] === 'update'
    const extra = needsRegistry
      ? ['--config.minimumReleaseAge=0', '--registry=https://registry.npmjs.org']
      : ['--config.minimumReleaseAge=0']
    const child = spawn('pnpm', [...args, ...extra], {
      cwd,
      env: { ...process.env },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let stdout = ''
    let stderr = ''
    let settled = false
    const timer = setTimeout(() => {
      if (settled) return
      settled = true
      child.kill('SIGKILL')
      reject(new Error(`pnpm timed out after ${timeoutMs}ms (${args.join(' ')})`))
    }, timeoutMs)
    child.stdout.on('data', (chunk) => { stdout += chunk })
    child.stderr.on('data', (chunk) => { stderr += chunk })
    child.on('error', (err) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (err.code === 'ENOENT') reject(new Error('pnpm not found on PATH — install pnpm to manage profile plugins'))
      else reject(err)
    })
    child.on('close', (code) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      const tail = (stdout + stderr).slice(-PNPM_TAIL_LIMIT)
      resolve({ exitCode: code ?? 1, tail })
    })
  })
}

async function runPnpmSafe(args, cwd) {
  try {
    return await runPnpm(args, cwd)
  } catch (error) {
    return { exitCode: 1, tail: error instanceof Error ? error.message : String(error) }
  }
}

/* ------------------------------------------------------------------ */
/* patch layer                                                         */
/* ------------------------------------------------------------------ */

function readUserLayer(file) {
  let content
  try {
    content = readFileSync(file, 'utf8')
  } catch (error) {
    if (error?.code === 'ENOENT') return []
    throw error
  }
  if (content.trim() === '') return []
  const parsed = yaml.load(content)
  if (parsed === undefined) return []
  if (!Array.isArray(parsed)) {
    throw new Error(`user patch layer ${file} must be a top-level YAML array`)
  }
  return parsed
}

function writeFileAtomic(file, content) {
  writeFileSync(file + '.' + process.pid + '.tmp', content)
  renameSync(file + '.' + process.pid + '.tmp', file)
}

function writeUserLayer(file, patches) {
  // `noRefs` avoids YAML anchors that would confuse the launcher's diff.
  const body = yaml.dump([...patches], { noRefs: true, lineWidth: -1 })
  writeFileAtomic(file, `${MANAGED_SECTION_HEADER}\n${body}`)
}

/** Row keys a bundle owns: insert entry ids plus its own id. */
function rowKeys(rows) {
  const keys = []
  for (const row of rows) {
    if (Array.isArray(row.insert)) {
      for (const entry of row.insert) {
        if (typeof entry.id === 'string') keys.push(entry.id)
      }
    } else if (typeof row.id === 'string') {
      keys.push(row.id)
    }
  }
  return keys
}

/** Remove rows owned by keys (drop defining insert rows too). */
function withoutRows(patches, keys) {
  return patches.filter((row) => {
    if (Array.isArray(row.insert)) {
      return !row.insert.some((entry) => typeof entry.id === 'string' && keys.has(entry.id))
    }
    return !(typeof row.id === 'string' && keys.has(row.id))
  })
}

/** Remove only id-targeted rows (overrides/disables), keeping defining inserts. */
function withoutIdRows(patches, keys) {
  const cleaned = patches.map((row) => {
    if (!Array.isArray(row.insert)) return row
    const insert = row.insert.map((entry) => {
      if (!(typeof entry.id === 'string' && keys.has(entry.id))) return entry
      const { disabled: _residue, ...rest } = entry
      return rest
    })
    return { ...row, insert }
  })
  return cleaned.filter((row) => !(typeof row.id === 'string' && keys.has(row.id)))
}

/** First colliding key between an existing layer and incoming keys. */
function findCollision(patches, keys) {
  const present = new Set()
  for (const row of patches) {
    if (Array.isArray(row.insert)) {
      for (const entry of row.insert) {
        if (typeof entry.id === 'string' && keys.has(entry.id)) return entry.id
        if (typeof entry.id === 'string') present.add(entry.id)
      }
    } else if (typeof row.id === 'string') {
      if (keys.has(row.id)) return row.id
      present.add(row.id)
    }
  }
  for (const key of keys) {
    if (present.has(key)) return key
  }
  return undefined
}

/* ------------------------------------------------------------------ */
/* state file                                                          */
/* ------------------------------------------------------------------ */

function emptyState() {
  return { bundles: [], disables: {} }
}

function readState(dir) {
  try {
    const parsed = JSON.parse(readFileSync(join(dir, STATE_FILENAME), 'utf8'))
    if (parsed && Array.isArray(parsed.bundles)) return parsed
  } catch { /* fall through */ }
  return emptyState()
}

function writeState(dir, state) {
  writeFileAtomic(join(dir, STATE_FILENAME), `${JSON.stringify(state, undefined, 2)}\n`)
}

function withBundle(state, bundle) {
  return { ...state, bundles: [...state.bundles.filter((b) => b.packageName !== bundle.packageName), bundle] }
}

function withoutBundle(state, packageName) {
  return { ...state, bundles: state.bundles.filter((b) => b.packageName !== packageName) }
}

function withoutBundles(state, packageNames) {
  const set = new Set(packageNames)
  return { ...state, bundles: state.bundles.filter((b) => !set.has(b.packageName)) }
}

function replaceBundle(state, packageName, bundle) {
  return { ...state, bundles: state.bundles.map((b) => (b.packageName === packageName ? bundle : b)) }
}

function withDisable(state, entryId, disabled) {
  return { ...state, disables: { ...state.disables, [entryId]: disabled } }
}

function withoutDisables(state, entryIds) {
  const disables = { ...state.disables }
  for (const id of entryIds) delete disables[id]
  return { ...state, disables }
}

/* ------------------------------------------------------------------ */
/* manifest / package resolution                                        */
/* ------------------------------------------------------------------ */

function readPkgManifest(dir) {
  try {
    const parsed = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
    return parsed && typeof parsed === 'object' ? parsed : undefined
  } catch {
    return undefined
  }
}

function resolvePkgDir(profileDir, packageName) {
  const dir = join(profileDir, 'node_modules', packageName)
  return existsSync(join(dir, 'package.json')) ? dir : undefined
}

/** Read the profile's dsh.profile.bundles list (bundles managed by dsh plugin CLI). */
function readProfileBundles(profileDir) {
  const manifest = readPkgManifest(profileDir)
  const bundles = manifest?.dsh?.profile?.bundles
  return Array.isArray(bundles) ? bundles.filter((name) => typeof name === 'string') : []
}

function installationPackageDir(packageName) {
  try {
    return dirname(managerRequire.resolve(`${packageName}/package.json`))
  } catch {
    return undefined
  }
}

/** The bundle-declaring package pnpm most recently wrote into the profile. */
function findNewestBundle(profileDir) {
  const nodeModules = join(profileDir, 'node_modules')
  if (!existsSync(nodeModules)) return undefined
  let best
  const visit = (dir, prefix) => {
    let entries
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      if (entry.name.startsWith('.')) continue
      if (!entry.isDirectory()) continue
      if (entry.name.startsWith('@')) {
        visit(join(dir, entry.name), `${prefix}${entry.name}/`)
        continue
      }
      const pkgDir = join(dir, entry.name)
      const manifest = readPkgManifest(pkgDir)
      if (manifest?.dsh?.bundle?.patch === undefined) continue
      let mtime
      try {
        mtime = statSync(pkgDir).mtimeMs
      } catch {
        continue
      }
      if (best === undefined || mtime > best.mtime) best = { name: `${prefix}${entry.name}`, mtime }
    }
  }
  visit(nodeModules, '')
  return best?.name
}

/** Base package name of a bare npm spec. */
function nameFromNpmSpec(spec) {
  if (!/^@?[a-zA-Z0-9][a-zA-Z0-9._-]*(?:\/[a-zA-Z0-9][a-zA-Z0-9._-]*)?(?:@[a-zA-Z0-9._^~-]+)?$/.test(spec)) return undefined
  const at = spec.indexOf('@', spec.startsWith('@') ? spec.indexOf('/') + 1 : 0)
  return at < 0 ? spec : spec.slice(0, at)
}

function scopeWildcard(packageName) {
  if (packageName.startsWith('@')) {
    const slash = packageName.indexOf('/')
    return slash < 0 ? packageName : `${packageName.slice(0, slash)}/*`
  }
  return packageName
}

/* pnpm 11 supply-chain gate remediations --------------------------------- */

function isReleaseAgeViolation(tail) {
  return /ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION/.test(tail)
}

function ageViolationPackage(tail) {
  const match = tail.match(/^\s*(@?[\w.-]+(?:\/[\w.-]+)?)(?:@[^\s]+)? was published at/m)
  return match === null ? undefined : match[1]
}

function isBuildsNotAllowed(tail) {
  return /ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED|ERR_PNPM_IGNORED_BUILDS/.test(tail)
}

function buildsNotAllowedSpec(tail) {
  const match = tail.match(/^\s*['"]?([@\w][^\s:]*@git\+[^\s']+(?:#[0-9a-f]+)?)['"]?\s*:\s*.+?\s*$/m)
  return match === null ? undefined : match[1]
}

/** Read the profile's pnpm-workspace.yaml and ensure a key is allowed. */
export function ensureWorkspaceAllowed(profileDir, key, kind) {
  // kinds: 'allowBuilds' | 'minimumReleaseAgeExclude'.
  // allowBuilds is written by dsh-market as a name→boolean OBJECT (its own
  // "set this to true or false" template) and by us as a legacy LIST — merge
  // into the existing shape instead of overwriting, so the two tools coexist
  // on the same file. Placeholder/missing keys are set to true on demand.
  const wsPath = join(profileDir, 'pnpm-workspace.yaml')
  let doc = {}
  try {
    const parsed = yaml.load(readFileSync(wsPath, 'utf8'))
    if (parsed && typeof parsed === 'object') doc = parsed
  } catch { /* file missing or unparsable — start fresh */ }
  const field = kind === 'allowBuilds' ? 'allowBuilds' : 'minimumReleaseAgeExclude'
  const existing = doc[field]
  if (kind === 'allowBuilds' && existing !== undefined && !Array.isArray(existing) && typeof existing === 'object') {
    // dsh-market 对象风格：name -> boolean。合并不覆盖；已允许则跳过。
    if (existing[key] === true) return false // already allowed
    doc[field] = { ...existing, [key]: true }
  } else {
    const list = Array.isArray(existing) ? existing : []
    if (list.includes(key)) return false // already allowed
    doc[field] = [...list, key]
  }
  const body = yaml.dump(doc, { lineWidth: -1 })
  writeFileAtomic(wsPath, body)
  return true
}

function ensureMinimumReleaseAgeExclude(profileDir, scope) {
  return ensureWorkspaceAllowed(profileDir, scope, 'minimumReleaseAgeExclude')
}

function ensureAllowBuilds(profileDir, specKey) {
  return ensureWorkspaceAllowed(profileDir, specKey, 'allowBuilds')
}

/* ------------------------------------------------------------------ */
/* bundle resolution                                                    */
/* ------------------------------------------------------------------ */

/** Read a bundle's patch rows from its installed package. */
function bundleRows(profileDir, packageName) {
  const pkgDir = resolvePkgDir(profileDir, packageName)
  const manifest = pkgDir === undefined ? undefined : readPkgManifest(pkgDir)
  const patchPath = manifest?.dsh?.bundle?.patch
  if (patchPath === undefined || pkgDir === undefined) {
    return { error: `${packageName} declares no dsh.bundle — it is not a plugin bundle` }
  }
  try {
    const raw = readFileSync(join(pkgDir, patchPath), 'utf8')
    const parsed = yaml.load(raw)
    if (parsed === undefined) return { rows: [] }
    if (!Array.isArray(parsed)) return { error: `bundle patch ${patchPath} must be a top-level YAML array` }
    return { rows: parsed }
  } catch (error) {
    return { error: `failed to read bundle patch: ${error instanceof Error ? error.message : String(error)}` }
  }
}

/* ------------------------------------------------------------------ */
/* include hot-apply                                                    */
/* ------------------------------------------------------------------ */

/**
 * Hot-apply a delta to the mounted composition by updating the root Include
 * entry. Returns an error string when the include entry is absent, else
 * undefined on success.
 */
async function applyToInclude(ctx, ownedKeys, addedRows, removal = 'insert-rows') {
  const include = [...ctx.loader.entries()].find((entry) => entry.options.id === 'include')
  if (include === undefined) {
    return 'no root include entry in the mounted tree — the change is written to the profile and applies on restart'
  }
  const config = include.options.config ?? {}
  const current = Array.isArray(config.patches) ? config.patches : []
  const { patches: _previous, ...rest } = config
  const filtered = removal === 'insert-rows' ? withoutRows(current, ownedKeys) : withoutIdRows(current, ownedKeys)
  const next = [...filtered, ...structuredClone(addedRows)]
  await include.update({ config: { ...rest, patches: next } })
  return undefined
}

/* ------------------------------------------------------------------ */
/* public operations                                                    */
/* ------------------------------------------------------------------ */

/** Install one bundle: pnpm as a real dependency, rows into the user patch layer, hot apply. */
export async function installBundle(ctx, profileDir, spec) {
  const invalid = validatePackageSpec(spec)
  if (invalid !== undefined) return { ok: false, message: invalid }
  // 冲突防护：若目标包已作为 bundle 存在（由 dsh plugin CLI 管理，自带
  // cordis.patch.yml 自动挂载），再热装会重复 insert 相同 id → 启动崩溃
  // （duplicate loader entry id）。此时拒绝热装，提示改用 dsh plugin 管理。
  const existingName = nameFromNpmSpec(spec)
  if (existingName !== undefined && readProfileBundles(profileDir).includes(existingName)) {
    return {
      ok: false,
      message: `${existingName} 已在 dsh.profile.bundles 中（由 dsh plugin 管理，自带 bundle patch 自动挂载）。请用 'dsh plugin --profile web add|remove ${existingName}' 管理，不要走热装，否则重复挂载会导致启动崩溃。`,
    }
  }
  let pnpm = await runPnpmSafe(['add', spec], profileDir)
  if (pnpm.exitCode !== 0) {
    const tail = pnpm.tail
    let remedied = false
    if (isReleaseAgeViolation(tail)) {
      const offender = ageViolationPackage(tail)
      remedied = offender !== undefined && ensureMinimumReleaseAgeExclude(profileDir, scopeWildcard(offender))
    } else if (isBuildsNotAllowed(tail)) {
      const specKey = buildsNotAllowedSpec(tail)
      remedied = specKey !== undefined && ensureAllowBuilds(profileDir, specKey)
    }
    if (remedied) pnpm = await runPnpmSafe(['add', spec], profileDir)
  }
  if (pnpm.exitCode !== 0) {
    return { ok: false, message: `pnpm add failed (exit ${pnpm.exitCode}) — see the output tail`, exitCode: pnpm.exitCode, tail: pnpm.tail }
  }
  const packageName = findNewestBundle(profileDir) ?? (/^(?:file|link):/.test(spec) ? undefined : nameFromNpmSpec(spec))
  if (packageName === undefined) {
    return { ok: false, message: 'could not resolve the installed package name', tail: pnpm.tail }
  }
  const resolved = bundleRows(profileDir, packageName)
  if (resolved.error !== undefined) {
    // Roll back the dependency so no residue stays in package.json.
    let rollback
    try {
      rollback = await runPnpm(['remove', packageName], profileDir)
    } catch {
      rollback = undefined
    }
    return {
      ok: false,
      message: rollback !== undefined && rollback.exitCode === 0
        ? resolved.error
        : `${resolved.error} (and pnpm remove rollback failed — remove ${packageName} from the profile manually)`,
      tail: pnpm.tail,
    }
  }
  const rows = resolved.rows
  const keys = new Set(rowKeys(rows))
  const patchFile = join(profileDir, PROFILE_PATCH_FILENAME)
  const current = readUserLayer(patchFile)
  const collision = findCollision(current, keys)
  if (collision !== undefined) {
    return { ok: false, message: `row id ${collision} already exists in the user patch layer — another bundle or a user row owns it` }
  }
  const state = readState(profileDir)
  const failed = await applyToInclude(ctx, new Set(), structuredClone(rows))
  if (failed !== undefined) {
    // Roll back: the hot apply failed, so forget the bundle and restore the
    // patch layer — the dependency stays (pnpm add already wrote package.json)
    // but the profile is left composable.
    writeState(profileDir, withoutBundle(state, packageName))
    writeUserLayer(patchFile, current)
    return { ok: false, message: failed }
  }
  writeState(profileDir, withBundle(state, { packageName, spec, rowIds: [...keys] }))
  writeUserLayer(patchFile, [...current, ...structuredClone(rows)])
  return { ok: true, message: `installed ${packageName}: ${rows.length} patch rows written and hot-applied` }
}

/** Uninstall one bundle: remove the dependency, drop rows, hot-unmount, forget state. */
export async function uninstallBundle(ctx, profileDir, packageName) {
  const state = readState(profileDir)
  const managed = state.bundles.find((bundle) => bundle.packageName === packageName)
  if (managed === undefined) {
    return { ok: false, message: `${packageName} is not installed through dsh-web-hot` }
  }
  let pnpm
  try {
    pnpm = await runPnpm(['remove', packageName], profileDir)
  } catch (error) {
    return { ok: false, message: error instanceof Error ? error.message : String(error) }
  }
  if (pnpm.exitCode !== 0) {
    return { ok: false, message: `pnpm remove failed (exit ${pnpm.exitCode}) — nothing was changed; see the output tail`, exitCode: pnpm.exitCode, tail: pnpm.tail }
  }
  const patchFile = join(profileDir, PROFILE_PATCH_FILENAME)
  const keys = new Set(managed.rowIds)
  writeState(profileDir, withoutDisables(withoutBundle(state, packageName), keys))
  writeUserLayer(patchFile, withoutRows(readUserLayer(patchFile), keys))
  const failed = await applyToInclude(ctx, keys, [])
  if (failed !== undefined) return { ok: false, message: failed }
  return { ok: true, message: `uninstalled ${packageName}: rows hot-unmounted and the dependency removed` }
}

/** Update one managed bundle (or all when packageName is empty). */
export async function updateBundle(ctx, profileDir, packageName) {
  const state = readState(profileDir)
  const targets = packageName === '' ? state.bundles : state.bundles.filter((b) => b.packageName === packageName)
  if (targets.length === 0) {
    return {
      ok: false,
      message: packageName === '' ? 'no bundles are installed through dsh-web-hot' : `${packageName} is not installed through dsh-web-hot`,
    }
  }
  for (const bundle of targets) {
    const local = /^(?:file|link):/.test(bundle.spec)
    let pnpm
    try {
      if (local) {
        await runPnpm(['remove', bundle.packageName], profileDir)
        pnpm = await runPnpm(['add', bundle.spec], profileDir)
      } else {
        pnpm = await runPnpm(['update', bundle.packageName], profileDir)
      }
    } catch (error) {
      return { ok: false, message: error instanceof Error ? error.message : String(error) }
    }
    if (pnpm.exitCode !== 0) {
      return { ok: false, message: `pnpm update failed (exit ${pnpm.exitCode}) — see the output tail`, exitCode: pnpm.exitCode, tail: pnpm.tail }
    }
    const resolved = bundleRows(profileDir, bundle.packageName)
    if (resolved.error !== undefined) return { ok: false, message: resolved.error, tail: pnpm.tail }
    const rows = resolved.rows
    const patchFile = join(profileDir, PROFILE_PATCH_FILENAME)
    const current = readUserLayer(patchFile)
    const leftover = withoutRows(current, new Set(bundle.rowIds))
    const collision = findCollision(leftover, new Set(rowKeys(rows)))
    if (collision !== undefined) {
      return { ok: false, message: `row id ${collision} collides after update — another bundle or a user row owns it` }
    }
    writeState(profileDir, replaceBundle(state, bundle.packageName, {
      packageName: bundle.packageName,
      spec: bundle.spec,
      rowIds: rowKeys(rows),
    }))
    writeUserLayer(patchFile, [...leftover, ...structuredClone(rows)])
    const failed = await applyToInclude(ctx, new Set(bundle.rowIds), rows)
    if (failed !== undefined) return { ok: false, message: failed }
  }
  return { ok: true, message: `updated ${targets.map((b) => b.packageName).join(', ')}` }
}

/** List bundles installed in the profile. */
export function listBundles(profileDir) {
  const state = readState(profileDir)
  const bundles = state.bundles.map((bundle) => {
    const manifest = resolvePkgDir(profileDir, bundle.packageName) === undefined
      ? undefined
      : readPkgManifest(join(profileDir, 'node_modules', bundle.packageName))
    return {
      packageName: bundle.packageName,
      version: manifest?.version,
      spec: bundle.spec,
      rowIds: bundle.rowIds,
      disabled: bundle.rowIds.some((id) => state.disables[id] === true),
    }
  })
  return bundles
}

/** Enable or disable one entry: persist a user-layer disable row and hot-apply it. */
export async function setEnabled(ctx, profileDir, entryId, enabled) {
  const patchFile = join(profileDir, PROFILE_PATCH_FILENAME)
  const current = readUserLayer(patchFile)
  const without = current.filter((row) => !(typeof row.id === 'string' && row.id === entryId))
  const disableRow = { id: entryId, disabled: true }
  const next = enabled ? without : [...without, disableRow]
  writeUserLayer(patchFile, next)
  const state = readState(profileDir)
  writeState(profileDir, withDisable(state, entryId, !enabled))
  const failed = await applyToInclude(ctx, new Set([entryId]), enabled ? [] : [disableRow], 'id-rows')
  if (failed !== undefined) return { ok: false, message: failed }
  return { ok: true, message: enabled ? `enabled ${entryId}` : `disabled ${entryId}` }
}

/**
 * Startup/periodic self-heal: when a bundle we hot-managed has since been
 * adopted by `dsh.profile.bundles` (external takeover, e.g. via `dsh plugin
 * add`), drop its patch-layer rows and state records so the next boot cannot
 * crash with `duplicate loader entry id`. Safe no-op when there is nothing to
 * heal. The bash half (dsh-web.sh preflight) runs the same check before every
 * boot; this covers running-process drift (HMR reloads, manual state edits)
 * so the next boot is clean even if preflight never ran.
 */
export async function selfHeal(ctx, profileDir) {
  const state = readState(profileDir)
  if (state.bundles.length === 0) return { ok: true, healed: [] }
  const profileBundles = readProfileBundles(profileDir)
  const taken = state.bundles.filter((bundle) => profileBundles.includes(bundle.packageName))
  if (taken.length === 0) return { ok: true, healed: [] }
  const names = taken.map((bundle) => bundle.packageName)
  const keys = new Set(taken.flatMap((bundle) => bundle.rowIds))
  const patchFile = join(profileDir, PROFILE_PATCH_FILENAME)
  writeState(profileDir, withoutDisables(withoutBundles(state, names), [...keys]))
  writeUserLayer(patchFile, withoutRows(readUserLayer(patchFile), keys))
  const failed = await applyToInclude(ctx, keys, [])
  if (failed !== undefined) {
    return { ok: false, healed: names, message: failed }
  }
  return {
    ok: true,
    healed: names,
    message: `external takeover: ${names.join(', ')} now managed by dsh.profile.bundles — patch rows dropped`,
  }
}

/* ------------------------------------------------------------------ */
/* spec validation                                                      */
/* ------------------------------------------------------------------ */

/** Validate a package spec (npm name / git URL / file: / link:). */
function validatePackageSpec(spec) {
  if (typeof spec !== 'string' || spec.trim() === '') return 'spec is required'
  const s = spec.trim()
  // npm name (optionally with version), git URL, github shorthand, file/link
  if (/^@?[a-zA-Z0-9][a-zA-Z0-9._-]*(?:\/[a-zA-Z0-9][a-zA-Z0-9._-]*)?(?:@[^\s]+)?$/.test(s)) return undefined
  if (/^(https?:\/\/|git\+|github:|file:|link:|\.{1,2}\/)/.test(s)) return undefined
  return `unsupported package spec: ${s}`
}

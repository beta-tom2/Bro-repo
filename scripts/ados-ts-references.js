"use strict";

const fs = require("fs");
const path = require("path");

function parseArguments(values) {
  const result = {};
  for (let index = 2; index < values.length; index += 2) {
    const key = values[index];
    if (!key || !key.startsWith("--") || index + 1 >= values.length) continue;
    result[key.slice(2)] = values[index + 1];
  }
  return result;
}

const args = parseArguments(process.argv);
const root = path.resolve(args.root || ".");
const output = path.resolve(args.output || path.join(root, ".ai", "index", "compiler-references.raw.json"));
const maxProjects = Math.max(1, Math.min(80, Number(args.maxProjects || 40)));
const maxFiles = Math.max(1, Math.min(10000, Number(args.maxFiles || 4000)));
const maxSymbols = Math.max(1, Math.min(10000, Number(args.maxSymbols || 1200)));
const maxReferences = Math.max(1, Math.min(50000, Number(args.maxReferences || 12000)));
const maxMilliseconds = Math.max(1000, Math.min(120000, Number(args.maxMilliseconds || 30000)));
const started = Date.now();

function isWithin(candidate, parent) {
  const relative = path.relative(parent, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

const allowedOutputRoot = path.join(root, ".ai", "index");
if (!isWithin(output, allowedOutputRoot)) {
  process.stderr.write("Output must stay under .ai/index.\n");
  process.exit(2);
}

function relativePath(value) {
  return path.relative(root, value).split(path.sep).join("\\");
}

function writeResult(result) {
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, JSON.stringify(result, null, 2), "utf8");
}

function finish(status, reason, extra = {}) {
  writeResult({
    schemaVersion: 1,
    status,
    reason,
    resolver: "typescript-language-service",
    durationMs: Date.now() - started,
    limits: { maxProjects, maxFiles, maxSymbols, maxReferences, maxMilliseconds },
    ...extra,
  });
}

let typescriptPath;
try {
  const resolved = require.resolve("typescript", { paths: [root] });
  const localModuleRoot = path.join(root, "node_modules") + path.sep;
  if (!path.resolve(resolved).startsWith(localModuleRoot)) throw new Error("resolved TypeScript is not project-local");
  typescriptPath = resolved;
} catch (_) {
  finish("SKIP", "project-local TypeScript dependency not found", { references: [] });
  process.exit(0);
}

let ts;
try {
  ts = require(typescriptPath);
} catch (error) {
  finish("ERROR", `unable to load project TypeScript: ${error.message}`, { references: [] });
  process.exit(0);
}

const ignoredDirectories = new Set([
  "node_modules", ".git", ".ai", "dist", "build", "coverage", ".next", ".expo", "vendor", "target", "bin", "obj",
]);

function findConfigs(directory, results) {
  if (results.length >= maxProjects || Date.now() - started >= maxMilliseconds) return;
  let entries;
  try {
    entries = fs.readdirSync(directory, { withFileTypes: true });
  } catch (_) {
    return;
  }
  for (const entry of entries) {
    if (results.length >= maxProjects || Date.now() - started >= maxMilliseconds) return;
    if (entry.isFile() && (entry.name === "tsconfig.json" || entry.name === "jsconfig.json")) {
      results.push(path.join(directory, entry.name));
    } else if (entry.isDirectory() && !ignoredDirectories.has(entry.name)) {
      findConfigs(path.join(directory, entry.name), results);
    }
  }
}

const configs = [];
findConfigs(root, configs);
configs.sort();
if (configs.length === 0) {
  finish("SKIP", "no tsconfig.json or jsconfig.json found", { typescriptVersion: ts.version, references: [] });
  process.exit(0);
}

const referenceMap = new Map();
const visitedDefinitions = new Set();
const visitedFiles = new Set();
const configErrors = [];
let symbolsAnalyzed = 0;
let truncated = false;

function isProjectFile(fileName) {
  const normalized = path.resolve(fileName);
  return isWithin(normalized, root) && !normalized.includes(`${path.sep}node_modules${path.sep}`) && !/\.d\.ts$/i.test(normalized);
}

function isNamedDeclaration(node) {
  return (
    ts.isFunctionDeclaration(node) || ts.isClassDeclaration(node) || ts.isInterfaceDeclaration(node) ||
    ts.isTypeAliasDeclaration(node) || ts.isEnumDeclaration(node) || ts.isVariableDeclaration(node) ||
    ts.isMethodDeclaration(node) || ts.isPropertyDeclaration(node)
  ) && node.name && ts.isIdentifier(node.name);
}

function addReference(symbol, definitionFile, definitionStart, reference, program) {
  if (!isProjectFile(reference.fileName)) return;
  const referenceFile = path.resolve(reference.fileName);
  const referenceStart = Number(reference.textSpan && reference.textSpan.start) || 0;
  if (referenceFile === definitionFile && referenceStart === definitionStart) return;
  const key = `${definitionFile}|${definitionStart}|${referenceFile}|${referenceStart}`;
  if (referenceMap.has(key)) return;
  const sourceFile = program.getSourceFile(referenceFile);
  let line = 0;
  let character = 0;
  if (sourceFile) {
    const location = sourceFile.getLineAndCharacterOfPosition(referenceStart);
    line = location.line + 1;
    character = location.character + 1;
  }
  referenceMap.set(key, {
    symbol,
    definitionFile: relativePath(definitionFile),
    definitionStart,
    referenceFile: relativePath(referenceFile),
    referenceStart,
    line,
    character,
    isWriteAccess: Boolean(reference.isWriteAccess),
  });
}

for (const configPath of configs) {
  if (truncated || Date.now() - started >= maxMilliseconds) {
    truncated = true;
    break;
  }
  const config = ts.readConfigFile(configPath, ts.sys.readFile);
  if (config.error) {
    configErrors.push(relativePath(configPath));
    continue;
  }
  const parsed = ts.parseJsonConfigFileContent(config.config, ts.sys, path.dirname(configPath), undefined, configPath);
  const fileNames = parsed.fileNames.filter(isProjectFile).slice(0, maxFiles);
  if (parsed.fileNames.length > maxFiles) truncated = true;
  if (fileNames.length === 0) continue;
  const versions = new Map(fileNames.map((fileName) => [fileName, "0"]));
  const host = {
    getScriptFileNames: () => fileNames,
    getScriptVersion: (fileName) => versions.get(fileName) || "0",
    getScriptSnapshot: (fileName) => {
      if (!fs.existsSync(fileName)) return undefined;
      return ts.ScriptSnapshot.fromString(fs.readFileSync(fileName, "utf8"));
    },
    getCurrentDirectory: () => path.dirname(configPath),
    getCompilationSettings: () => parsed.options,
    getDefaultLibFileName: (options) => ts.getDefaultLibFilePath(options),
    fileExists: ts.sys.fileExists,
    readFile: ts.sys.readFile,
    readDirectory: ts.sys.readDirectory,
    directoryExists: ts.sys.directoryExists,
    getDirectories: ts.sys.getDirectories,
  };
  const service = ts.createLanguageService(host, ts.createDocumentRegistry());
  const program = service.getProgram();
  if (!program) continue;
  for (const sourceFile of program.getSourceFiles()) {
    if (truncated || Date.now() - started >= maxMilliseconds) {
      truncated = true;
      break;
    }
    if (!isProjectFile(sourceFile.fileName)) continue;
    visitedFiles.add(path.resolve(sourceFile.fileName));
    function visit(node) {
      if (truncated || Date.now() - started >= maxMilliseconds) {
        truncated = true;
        return;
      }
      if (isNamedDeclaration(node)) {
        const definitionFile = path.resolve(sourceFile.fileName);
        const definitionStart = node.name.getStart(sourceFile);
        const definitionKey = `${definitionFile}|${definitionStart}`;
        if (!visitedDefinitions.has(definitionKey)) {
          visitedDefinitions.add(definitionKey);
          symbolsAnalyzed += 1;
          if (symbolsAnalyzed > maxSymbols) {
            truncated = true;
            return;
          }
          const references = service.getReferencesAtPosition(sourceFile.fileName, definitionStart) || [];
          for (const reference of references) {
            addReference(node.name.text, definitionFile, definitionStart, reference, program);
            if (referenceMap.size >= maxReferences) {
              truncated = true;
              return;
            }
          }
        }
      }
      ts.forEachChild(node, visit);
    }
    visit(sourceFile);
  }
  service.dispose();
}

const status = truncated ? "PARTIAL" : "PASS";
const reason = truncated ? "bounded compiler scan reached a configured limit" : "compiler references resolved";
finish(status, reason, {
  typescriptVersion: ts.version,
  projectCount: configs.length,
  configErrors,
  filesAnalyzed: visitedFiles.size,
  symbolsAnalyzed: Math.min(symbolsAnalyzed, maxSymbols),
  referenceCount: referenceMap.size,
  references: Array.from(referenceMap.values()).sort((left, right) =>
    left.definitionFile.localeCompare(right.definitionFile) || left.referenceFile.localeCompare(right.referenceFile) || left.referenceStart - right.referenceStart
  ),
  safety: "Read-only project-local TypeScript language service; no dependency installation or network call.",
});

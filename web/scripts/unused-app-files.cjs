const ts = require("typescript"),
  fs = require("fs"),
  path = require("path"),
  cp = require("child_process")
const root = process.cwd()
const files = cp
  .execFileSync("git", ["ls-files", "--cached", "--others", "--exclude-standard"], { encoding: "utf8" })
  .trim()
  .split("\n")
  .filter((f) => /\.[cm]?[jt]sx?$/.test(f) && fs.existsSync(f))
const tracked = new Set(files.map((f) => path.resolve(f)))
const incoming = new Map(files.map((f) => [f, []]))
const config = ts.readConfigFile("tsconfig.json", ts.sys.readFile).config
const options = ts.parseJsonConfigFileContent(config, ts.sys, root).options
for (const file of files) {
  const source = fs.readFileSync(file, "utf8")
  for (const imp of ts.preProcessFile(source, true, true).importedFiles) {
    const resolved = ts.resolveModuleName(imp.fileName, path.resolve(file), options, ts.sys).resolvedModule
      ?.resolvedFileName
    if (resolved && tracked.has(path.resolve(resolved))) incoming.get(path.relative(root, resolved))?.push(file)
  }
}
const test = (f) => /(__tests__|\.test\.|\.spec\.|^tests\/)/.test(f)
const rows = files
  .filter(
    (f) =>
      f.startsWith("app/") &&
      /\.tsx?$/.test(f) &&
      !test(f) &&
      !/(^|\/)(page|layout|route|loading|error|not-found|global-error|template|default|sitemap|robots|manifest|opengraph-image|twitter-image|icon|apple-icon)\./.test(
        f,
      ),
  )
  .map((file) => ({
    file,
    lines: fs.readFileSync(file, "utf8").split("\n").length,
    consumers: incoming.get(file) || [],
  }))
  .filter((x) => x.consumers.every(test))
  .sort((a, b) => b.lines - a.lines)
const reviewed = JSON.parse(fs.readFileSync("config/unused-app-files.json", "utf8"))
const unexpected = rows.filter((row) => !reviewed[row.file])
console.log(JSON.stringify({ reviewedCandidates: rows.length, unexpected }, null, 2))
if (unexpected.length) process.exitCode = 1

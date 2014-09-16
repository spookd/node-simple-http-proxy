httpProxy = require("http-proxy")
watch     = require("watch")
http      = require("http")
path      = require("path")
fs        = require("fs")
_         = require("lodash")
Entry     = require("./entry")

getPackageDirs = (root, dirs = []) ->
  files  = fs.readdirSync(root)

  hasPackage = file for file in files when not fs.statSync(path.join(root, file)).isDirectory() and path.basename(file) is "package.json"
  hasNodeMod = file for file in files when fs.statSync(path.join(root, file)).isDirectory() and path.basename(file) is "node_modules"

  if not hasPackage and not hasNodeMod then for file in files
    continue if file[0] is "."
    stat = fs.statSync(path.join(root, file))
    if stat.isDirectory()
      dirs = _.merge(dirs, getPackageDirs(path.join(root, file), dirs))
  else if hasPackage
    dirs.push(root)

  return dirs

module.exports = exports = class extends require("events").EventEmitter
  constructor: (@opts) ->
    @entries = []
    @proxy   = httpProxy.createServer(xfwd: true)
    @http    = http.createServer(@clientDidConnect)
    @http.listen(3000)

    process.on "exit", =>
      for entry in @entries
        entry.abort()

    @proxy.on "error", (error) ->
      console.error "!! PROXY:", error.toString()

    dirs = getPackageDirs(@opts.root)
    for dir in dirs
      @entries.push(new Entry(dir))

    watch.createMonitor(
      @opts.root, 
      ignoreDirectoryPattern: "/node_modules/",
      ignoreUnreadableDir: true,
      @didCreateMonitor
    )

  # Proxy events

  clientDidConnect: (req, res) =>
    url = req.url
    url = "#{url}/" if url.substr(-1) isnt "/"

    for entry in @entries when entry.port
      dir = "#{entry.dir.substr(@opts.root.length)}/"
      if dir.toLowerCase() is url.substr(0, dir.length).toLowerCase()
        if dir.length is url.length
          req.url = "/"
        else
          req.url = req.url.substr(dir.length)

        req.headers["X-Forwarded-Path"] = dir

        isCSS  = req.url.substr(-4) is ".css"
        isJS   = req.url.substr(-3) is ".js"
        isHTML = false

        origWriteHead = res.writeHead
        res.writeHead = (code, headers = {}) ->
          for key, value of headers
            lowerCaseKey = key.toLowerCase()
            if lowerCaseKey is "content-type"
              isHTML = value.substr(0, 9) is "text/html" unless isHTML
              isCSS  = value.substr(0, 8) is "text/css" unless isCSS
              isJS   = value.substr(0, 14) is "text/javascript" unless isJS

          origWriteHead.apply(res, [code, headers])

        origSetHeader = res.setHeader
        res.setHeader = (key, value) ->
          lowerCaseKey = key.toLowerCase()
          if lowerCaseKey is "content-type"
            isHTML = value.substr(0, 9) is "text/html" unless isHTML
            isCSS  = value.substr(0, 8) is "text/css" unless isCSS
            isJS   = value.substr(0, 14) is "text/javascript" unless isJS

          origWriteHead.apply(res, [key, value])

        origWrite = res.write
        res.write = (buffer) ->
          if buffer and (isHTML or isJS or isCSS)
            buffer = buffer.toString()
            buffer = buffer.replace(/(src|href|action)=("|')\/(\w)/gi, "$1=$2#{dir}$3") if isHTML
            buffer = buffer.replace(/url\(("|')~\/(\w)(.*)("|')\)/gi, "url($1#{dir}$2$3$4)") if isCSS
            buffer = buffer.replace(/("|')~\/(\w)(.*)("|')/gi, "$1#{dir}$2$3$4") if isJS

          origWrite.apply(res, [buffer])

        return @proxy.web(req, res, target: "http://127.0.0.1:#{entry.port}")

    res.writeHead(404, "Content-type": "text/plain")
    res.write("Nope, nope, nope.")
    res.end()

  # Folder monitoring

  didCreateMonitor: (@monitor) =>
    @monitor.on "error", (error) ->
      console.error "!! MONITOR:", error

    @monitor.on("created", @monitorFileCreated)
    @monitor.on("removed", @mointorFileDeleted)

  monitorFileCreated: (file, stat) =>
    return unless path.basename(file) is "package.json"

    for entry in @entries
      return if file.substr(0, entry.dir.length) is entry.dir

    dir = file.substr(0, file.length - path.basename(file).length)
    @entries.push(new Entry(dir))

  mointorFileDeleted: (file, stat) =>
    return unless path.basename(file) is "package.json" and file.indexOf("/node_modules/") is -1

    file = file.substr(0, file.length - path.basename(file).length)

    for entry, i in @entries
      if path.relative(entry.dir, file) is ""
        @entries.splice(i, 1)
        entry.abort()
        entry = null
        return
watch    = require("watch")
freeport = require("freeport")
forever  = require("forever-monitor")
spawn    = require("child_process").spawn
path     = require("path")
fs       = require("fs")

module.exports = exports = class extends require("events").EventEmitter
  constructor: (@dir, @socket) ->
    @beginMonitoring()
    @rebuild()

  abort: =>
    @forever.stop() if @forever
    @monitor.stop() if @monitor
    @proc.exit(0) if @proc

  rebuild: =>
    @endMonitoring()

    fs.readFile path.join(@dir, "package.json"), (error, @package) =>
      try
        @package = JSON.parse(@package)

        npm   = if process.platform is "win32" then "npm.cmd" else "npm"
        @proc = spawn(npm, ["install", "--production"], cwd: @dir)
        @proc.on "exit", (code, signal) =>
          return @reload() if not signal and not code
          console.error "!! NPM (#{@dir}): Exited with code #{code}" if code
          console.error "!! NPM (#{@dir}): Killed with signal #{signal}" if signal
      catch e
        @package = {}

  reload: =>
    @forever.stop() if @forever

    return console.error "Invalid or no package.json" if not @package? or typeof @package.main isnt "string"

    freeport (error, @port) =>
      return console.error "!!", error.toString() if error

      @foreverOpts =
        silent:   true
        pidFile:  path.join(@dir, "forever.pid")
        max:      10
        killTree: true

        minUptime:     5000
        spinSleepTime: 2000

        command:   "node"
        sourceDir: @dir
        watch:     false # We're already watching

        cwd: @dir
        env:
          PORT: @port
          NODE_ENV: "production"

        logFile: path.join(@dir, "proxy.log")
        outFile: path.join(@dir, "proxy.stdout.log")
        errFile: path.join(@dir, "proxy.stderr.log")

      @forever = new (forever.Monitor)(@package.main, @foreverOpts)

      @forever.on "error", (error) ->
        console.log "!! FOREVER:", error.toString() if error

      @forever.start()

  # File monitoring -- reload on new files

  beginMonitoring: =>
    @endMonitoring()
    watch.createMonitor(@dir, ignoreDirectoryPattern: "/node_modules/", ignoreUnreadableDir: true, @monitoring)

  endMonitoring: =>
    @monitor.stop() if @monitor

  monitoring: (@monitor) =>
    @monitor.on("created", @handleFileEvent)
    @monitor.on("changed", @handleFileEvent)
    @monitor.on("removed", @handleFileEvent)

  handleFileEvent: (file, stat) =>
    lowerCaseFile = file.toLowerCase()
    lowerCaseDir  = @dir.toLowerCase()

    # Rebuild if package.json changed
    return @rebuild() if lowerCaseFile is path.join(lowerCaseDir, "package.json")

    # Reload
    if not stat.isDirectory() and (file.match(/\.js$/gi) or file.match(/\.coffee$/gi))
      @reload()



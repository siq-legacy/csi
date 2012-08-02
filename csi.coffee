fs = require "fs"
{join, basename, resolve, normalize, dirname} = require "path"
exists = fs.existsSync or require("path").existsSync
crypto = require "crypto"
extend = require "node.extend"
_ = require "underscore"
t = require "t"
wrench = require "wrench"
yaml = require "js-yaml"
{cssmin} = require "css-compressor"
testServer = require "./server"
{updateCssPaths} = require "./lib/css_rewrite"
child_process = require "child_process"
requirejs = require "requirejs" # that's a mouthfull...
{parser, uglify} = require "uglify-js"

read = (fname, encoding="utf8") ->
  fs.readFileSync(fname, encoding)
write = (fname, content, encoding="utf8") ->
  fs.writeFileSync(fname, content, encoding)
pathSep = normalize("/")
re = (s) -> new RegExp s
argv = usage = null

pkgJson = (dir = ".") ->
  JSON.parse read(join(dir, "package.json"))

componentName = (dir = ".", json = null) ->
  (json or pkgJson(dir)).csi?.name

sourceDirectory = (dir = ".") ->
  pkgJson(dir).csi?.sourceDirectory || "src"

testTemplate = (dir = ".") ->
  tt = pkgJson(dir).csi?.testTemplate
  if tt then read join(dir,tt) else ""

isComponent = (dir = ".", json = null) ->
  if json
    return not not componentName(dir, json)
  exists(join dir, "package.json") and (not not componentName(dir))

requirejsConfig = (filename, dir = ".") ->
  filename ||= join(dir, "requirejs-config.json")
  if exists filename then JSON.parse read(filename) else {}

makePathsAbsolute = (rjsConfigObj = {}, root = "components") ->
  fullPath = (root) -> root.replace /\/$/, ""
  rootBase = (root) -> basename(root).replace /\/$/, ""
  relativize = (pth, fn = rootBase) -> pth.replace /^\.(\/?)/, "#{fn(root)}$1"

  extend rjsConfigObj,
    paths: _.reduce(rjsConfigObj.paths or {}, ((memo, v, k) ->
      memo[relativize(k)] = relativize(v, fullPath)
      memo
    ), {})
    shim: _.reduce(rjsConfigObj.shim or {}, ((memo, shim, shimPath) ->
      memo[relativize shimPath] = extend shim,
        deps: _.map(shim.deps or [], (d) -> relativize(d))
      memo
    ), {})

addComponentToConfig = (rjsConfigObj = {}, dir = ".", root = "components") ->
  paths = {}
  paths[componentName()] = join root, componentName()
  extend true, {paths: paths}, rjsConfigObj

installTo = (tgtDir, link = false, src, name = null) ->
  src ||= sourceDirectory()
  name ||= componentName()
  if exists(src) and not exists(join(tgtDir, name))
    if link
      log "link-installing #{name} to #{tgtDir}"
      orig = resolve process.cwd()
      process.chdir tgtDir
      # there's a chance that "csi" is a dead link (so exists() returns false,
      # but there's actually a link in the directory).  remove that here.
      try
        fs.unlinkSync name
      fs.symlinkSync join(orig, src), name, "dir"
      process.chdir orig
    else
      log "installing #{name} to #{tgtDir}"
      wrench.copyDirSyncRecursive src, join(tgtDir, name)

hasBuildProfile = (filename = "app.build.js", dir = ".") ->
  exists join(dir, "app.build.js")

appBuildProfile = (filename = "app.build.js", dir = ".") ->
  eval read(join(dir, filename))

allNodeModules = () ->
  modules = {}
  t.bfs directories = {path: "."}, (n) ->
    if exists join(n.path, "package.json")
      n.json = pkgJson n.path
    if exists join(n.path, "requirejs-config.json")
      n.config = requirejsConfig null, n.path
    if exists join(n.path, "app.build.js")
      n.build = appBuildProfile null, n.path
    modulesDir = join n.path, "node_modules"
    if exists modulesDir
      n.children = _(fs.readdirSync(modulesDir)).map((d) ->
        full = join modulesDir, d
        fs.statSync(full).isDirectory() and d isnt ".bin" and full
      ).filter(_.identity).map (d) -> {path: d}
  directories

allComponents = () ->
  results = []
  names = () -> component.json.name for component in results
  t.bfs allNodeModules(), (m) ->
    if m.json and isComponent(null, m.json) and m.json.name not in names()
      results.push(m)
  _.filter results, (m) -> m.path isnt "."

provide = (pth) ->
  if not exists pth
    log "recursively creating directory #{pth}"
    start = if pth[0] is pathSep then pathSep else ""
    _.reduce [start].concat(pth.split(pathSep)), (soFar, dir) ->
      fs.mkdirSync join(soFar, dir) if not exists(join(soFar, dir))
      soFar += (if soFar then pathSep else "") + dir

discoverTests = (dir) ->
  dir = argv.staticpath
  return [] if not exists dir
  results = []
  t.bfs dirTree = {path: "."}, (n) ->
    if /test[^\/]*\.js$/.test(n.path) and basename(n.path)[0] isnt "."
      results.push(n.path)
    if exists(join(dir, n.path)) and fs.statSync(join(dir, n.path)).isDirectory()
      n.children = fs.readdirSync(join(dir, n.path)).map (d) ->
        path: join n.path, d
  results

getConfig = (root = "components") ->
  components = allComponents()
  componentPath = (c) ->
    ret = {paths: {}}
    ret.paths[c.json.csi.name] = join root, c.json.csi.name
    ret
  componentConfig = (c) ->
    makePathsAbsolute(c.config, join(root, componentName(c.path)))
  thisComponentConfig = () ->
    if not isComponent() then return {}
    destPath = join(root, componentName())
    addComponentToConfig(makePathsAbsolute(requirejsConfig(), destPath))
  baseUrl = if argv.baseurlSpecified then {baseUrl: argv.baseurl} else {}
  extend.apply this, [true, baseUrl]
    .concat(componentPath(c) for c in components)
    .concat(componentConfig(c) for c in components)
    .concat([thisComponentConfig()])

getTestTemplate = () ->
  components = allComponents().concat([{path: "."}])
  (testTemplate(component.path) for component in components).join("\n")

getTestMiddleware = () ->
  components = allComponents()
  components.push({path: ".", json: pkgJson()}) if isComponent()
  require(resolve(join(component.path, component.json.csi.testMiddleware))) \
    for component in components when component.json.csi.testMiddleware

componentsPath = () ->
  join argv.staticpath, "components"

stringBundles = (dir = ".") ->
  stringsYml = join(dir, "strings.yml")
  stringsYaml = join(dir, "strings.yaml")
  if exists stringsYml
    yaml.load read(stringsYml)
  else if exists stringsYaml
    yaml.load read(stringsYaml)
  else
    {}

allStringBundles = () ->
  _.reduce(allComponents().concat([{path: "."}]), ((strings, component) ->
    extend true, strings, stringBundles(component.path)
  ), {})

stringBundlesAsRequirejsModule = () ->
  bundles = JSON.stringify(allStringBundles(), null, "    ")
    .replace(/\n/g, "\n      ")
  """
  <script>
    define('strings', [], function() {
        return #{bundles};
    });
  </script>
  """

defaultStaticpath = () ->
  json = try
    pkgJson()
  catch e
    {}
  base = json.csi?.testDirectory or (exists("static") and ".") or ".test"
  join base, "static"

withOutStaticPath = (path) ->
  path.replace re('^' + argv.staticpath), ''

updateWithPathsConfig = (config, name) ->
  for prefix, path of config.paths
    if name[..prefix.length] is prefix + "/"
      return path + name[prefix.length..]
  name

listTests = (tests, host, port) ->
  for test in tests
    console.log("http://#{host}:#{port}/#{test.replace(/\.js$/, "")}")

configCommands =
  requirejs: (config) ->
    join config.baseUrl || "", config.paths.csi, "require.js"
  extra: () -> ''
  strings: (config) ->
    JSON.stringify(allStringBundles(), null, "  ")
  config: (config) ->
    JSON.stringify config, null, "  "
  optimizations: (config) ->
    return {} if not hasBuildProfile(argv.buildprofile)
    ext = (fname, newExt) -> fname.match(/\.(css|js)$/)[1]
    names = (m.name for m in (appBuildProfile().modules or []))
    names.reduce (optimizations, module) ->
      module = updateWithPathsConfig config, module
      filesInDir = fs.readdirSync dirname(join(argv.staticpath, module))
      fileNamesRe = re "^" + basename(module) + "-[a-f0-9]{32}(\.min)?\.(js|css)"
      for filename in filesInDir
        if fileNamesRe.test(filename)
          optimizations[module] ||= {}
          subKey = if /\.min\./.test(filename) then "minified" else "optimized"
          (optimizations[module][subKey] ||= {})[ext(filename)] = filename
      optimizations
    , {}
  baseurl: (config) -> argv.baseurl
  all: (config, which) ->
    _.reduce(configCommands, ((configObj, cmd, name) ->
      return configObj if name is "all"
      if which == null or which[name]
        configObj[name] = configCommands[name](config)
      configObj
    ), {})

buildProfile = () ->
  eval read(argv.buildprofile)

minify = (text) ->
  uglify.gen_code(uglify.ast_squeeze(uglify.ast_mangle(parser.parse(text))))

exports.commands = commands =
  install:
    description: """
    install component dependencies to [staticpath]
    """
    action: () ->
      provide argv.staticpath
      components = allComponents()
      provide componentsPath()
      for component in components
        src = join(component.path, sourceDirectory(component.path))
        name = componentName(null, component.json)
        installTo componentsPath(), argv.link, src, name
      if isComponent()
        installTo componentsPath(), argv.link, sourceDirectory(), componentName()

  doc:
    description: """
        builds client side code documentation
        """
    action: () ->
      log "building client side code docs"
      docco_lib = require.resolve("docco-husky")
      docco = docco_lib.substring(0, docco_lib.lastIndexOf "node_modules") +
              "node_modules/.bin/docco-husky"
      child_process.execFile(docco, [sourceDirectory()],
          (error, stdout, stderr) ->
            if error?
              console.log(error)
            else
              console.log(stdout)
      )

  test:
    description: """
    start up a test server
    """
    action: () ->
      components = allComponents()
      if argv.listtests
        return listTests(discoverTests(argv.staticpath), argv.host, argv.port)
      commands.install.action()
      tests = discoverTests argv.staticpath
      extraHtml = getTestTemplate() + "\n" + stringBundlesAsRequirejsModule()
      testServer.createServer(
          argv.staticpath,
          getConfig(),
          extraHtml,
          getTestMiddleware())
        .listen(argv.port, argv.host)
      log "serving at http://#{argv.host}:#{argv.port}"
      log "available tests:"
      listTests tests, argv.host, argv.port

  config:
    description: """
    output html snippets for things like the require.js path, can be any of:
    #{(" - " + cmd + "\n" for cmd of configCommands).join("")}
    """.replace(/\n$/, "")
    action: (cmd, args...) ->
      console.log configCommands[cmd](getConfig())

  build:
    description: """
    the build command is used to do some set of the following actions:
     - copy everything to a build directory (if different than
       #{defaultStaticpath()})
     - install dependencies to the build directory
     - write the runtime config if the [templatepath] option is given (stuff
       like the require.js config, string bundles, etc.)
     - optimize the resources into a single .js and .css file if the [optimize]
       flag is set
    """
    action: () ->
      config = getConfig()

      if resolve(argv.staticpath) isnt resolve(defaultStaticpath()) and not argv.nocopy
        log "installing default static path (#{defaultStaticpath()}) to #{argv.staticpath}"
        provide argv.staticpath
        wrench.copyDirSyncRecursive defaultStaticpath(), argv.staticpath

      commands.install.action()

      if argv.optimize
        profile = buildProfile()

        # returns the on-disk filename for a css dep like "css!100:foo.css"
        cssFilename = (moduleName) ->
          _.compose.apply(_, [
            # remove plugin prefix css!100:
            (n) -> n.replace /^css!(\d+:)?/, ""

            # check the paths config, replace the path if it's in there
            (n) -> updateWithPathsConfig config, n

            # add the .css extension
            (n) -> if n[-4..] isnt ".css" then n + ".css" else n

            # prefix the path with the path to the static directory on disk
            (n) -> join argv.staticpath, n
          ].reverse())(moduleName)

        # returns the order for a css dep like "css!100:foo.css"
        cssOrder = (moduleName) ->
          +(moduleName.match(/^css!((\d+):)?/)[2] or "0")

        # get the css text from the css object compiled during the build
        compileCss = (allCss) ->
          ordered = (css for n,css of allCss).sort (a, b) -> 
            if a.order > b.order
                return 1
            if a.order < b.order
                return -1
            return 0
          (css.contents for css in ordered).join("\n")

        # return the contents of `filename` w/ the css url(...) paths
        # re-written appropriately
        cssWithPathsReWritten = (fname) ->
          updateCssPaths read(fname), (u) ->
            if u[0] isnt "/" and u[0..4] isnt "data:"
              join(argv.baseurl, dirname(withOutStaticPath(fname)), u)
            else
              u

        # go through all the components build configs and create a "paths"
        # config for the require.js optimizer that includes empty modules for
        # all excluded files
        pathsConfig = () ->
          base = {strings: "empty:"}
          base[excluded] = "empty:" for excluded in (profile.exclude or [])
          allComponents().reduce (paths, component) ->
            if component.build?.exclude
              paths[module] = "empty:" for module in component.build.exclude
            paths
          , extend(true, base, config.paths)

        output = (text, opts) ->
          text = minify(text) if opts.minify
          cssText = if opts.minify then cssmin(opts.css) else opts.css
          hash = crypto.createHash("md5").update(text + cssText).digest("hex")
          id = "#{module.name}-#{hash}#{if opts.minify then ".min" else ""}"
          rId = re('(define\\([\'"])' + module.name)
          text = text.replace rId, "$1" + id

          name = join argv.staticpath, "#{id}.js"
          write name, text
          log "writing optimized#{opts.minify and "/minified" or ""} file to #{name}"

          cssName = join argv.staticpath, "#{id}.css"
          write cssName, cssText
          log "writing optimized#{opts.minify and "/minified" or ""} file to #{cssName}"

        for module in profile.modules
          css = {}
          if isComponent() and /^\.[\/\\]/.test(module.name)
            module.name = join(config.paths[componentName()], module.name[2..])
          module.name = updateWithPathsConfig config, module.name
          requirejs.optimize
            baseUrl: argv.staticpath
            paths: pathsConfig()
            shim: extend(true, {}, config.shim) # r.js optimizer modifies shim
            name: module.name
            optimize: "none"
            keepBuildDir: true
            onBuildWrite: (moduleName, path, contents) ->
              if moduleName[..3] is "css!"
                filename = cssFilename moduleName
                css[moduleName] =
                  name: moduleName
                  order: cssOrder moduleName
                  path: path
                  filename: filename
                  contents: cssWithPathsReWritten filename, moduleName, path
              contents
            out: (text) ->
              cssText = compileCss css
              output text, module: module, css: cssText
              if argv.minify
                output text, minify: true, module: module, css: cssText

      # this must be after the optimization step, since it checks for optimized
      # files and includes them in the config
      if argv.templatepath
        provide argv.templatepath

        templateObj = configCommands.all config,
          requirejs: true
          extra: true
          config: true
          baseurl: true
        templateContextName = join argv.templatepath, "csi-template-context.json"
        log "writing template context to #{templateContextName}"
        write templateContextName, JSON.stringify(templateObj, null, "    ")

        stringBundleName = join(argv.templatepath, "strings.json")
        log "writing string bundle to #{stringBundleName}"
        write stringBundleName, JSON.stringify(allStringBundles(), null, "    ")

        contextObj = configCommands.all config, optimizations: true
        contextName = join argv.templatepath, "csi-context.json"
        log "writing context to #{contextName}"
        write contextName, JSON.stringify(contextObj, null, "    ")

  completion:
    description: """
    spits out a bash completion command.  something you can run like this:
      $ csi completion > /tmp/cc.bash && source /tmp/cc.bash
    """
    action: () ->
      console.log "complete -W \"#{(c for c of commands).join(" ")}\" csi"

  uninstall:
    description: """
    just does the opposite of the `csi install` command -- it removes
    directories (or links) from [staticpath] that would have been installed
    """
    action: () ->
      components = allComponents()
      if isComponent()
        components.push {json: {csi: {name: componentName()}}}
      for component in components
        installedTo = join(componentsPath(), component.json.csi.name)
        if exists installedTo
          if fs.lstatSync(installedTo).isSymbolicLink()
            log "removing link #{installedTo}"
            fs.unlinkSync installedTo
          else
            log "removing directory #{installedTo}"
            wrench.rmdirSyncRecursive installedTo

log = (msg, level="info") ->
  console.log "[#{basename process.argv[1]} #{argv._[0]}] #{msg}"

usage = """#{("node $0 "+cmd+"\n" for cmd of commands).join("")}
`csi` is a utility that's used for installing javascript components and
their dependencies -- imagine that!

commands:

"""
for name, command of commands
  usage += "
  #{name}:\n
    #{command.description.replace(/\n/g, "\n    ")}\n"

exports.parseArgs = parseArgs = () ->
  argv = require("optimist")
    .usage(usage)

    .option "link",
      boolean: true
      alias: "l"
      describe: "install components as links (useful for dev.. on *nix systems)"

    .option "port",
      alias: "p"
      default: process.argv.PORT || 1335
      describe: "test server port, overrides $PORT env variable\n(cmd: test)"

    .option "host",
      alias: "H"
      default: process.argv.HOST || "localhost"
      describe: "test server host, overrides $HOST env variable\n(cmd: test)"

    .option "listtests",
      boolean: true
      describe: "just list tests\n(cmd: test)"

    .option "templatepath",
      string: true
      alias: "t"
      describe: "specify the templatepath\n(cmd: build)"

    .option "contextjsonname",
      string: true
      alias: "j"
      "default": "csi-context.json"
      describe: "specify the name of the context json\n(cmd: build)"

    .option "staticpath",
      string: true
      alias: "s"
      "default": defaultStaticpath()
      describe: """
      specify the installation path.  the default for this value is dynamically determined:
       - if there is a package.json file with a csi.testDirectory property, staticpath is set to that
       - otherwise if the "./static" directory exits, staticpath is set to "static"
       - finally if nothing else csi will create a ".test" directory and use it as the staticpath
       (cmd: build)
       """
    .option "baseurl",
      string: true
      alias: "b"
      "default": "/static"
      describe: "specify the baseurl\n(cmd: build)"

    .option "nocopy",
      boolean: true
      alias: "n"
      "default": false
      describe: "don't copy default static dir when performing a build\n(cmd: build)"

    .option "buildprofile",
      string: true
      alias: "P"
      "default": "app.build.js"
      describe: """
      this is a file containing parameters for running the r.js optimizer to produce a single file.  for example:
          ({ modules: [ {name: "static/index"} ] })
      (cmd: build)
      """
    .option "optimize",
      boolean: true
      alias: "o"
      "default": false
      describe: "compile everything into one .js and one .css file\n(cmd: build)"

    .option "minify",
      boolean: true
      alias: "m"
      "default": false
      describe: "minify javascript in optimized builds\n(cmd: build)"

    .alias("h", "help")

    .wrap(80)

    .argv

  specified = (argName, shorthand) ->
    argv[argName+"Specified"] = _.any process.argv, (arg) ->
      RegExp("^-{1,2}" + argName).test(arg) or (arg is "-" + shorthand)

  specified("templatepath", "t")
  specified("staticpath", "s")
  specified("baseurl", "b")

  [argv, argv._[0]]


exports.run = () ->
  [argv, command] = parseArgs()
  if argv.help
    console.log require("optimist").help()
    process.exit 0
  if not commands[command]
    console.error "ERROR: command must be one of: #{k for k,v of commands}\n"
    require("optimist").showHelp()
    process.exit 1

  commands[command].action(argv._[1..]...)


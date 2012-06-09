'use strict'

async = require 'async'
{EventEmitter} = require 'events'
Asset = require './asset'
SourceFile = require './source_file'
helpers = require '../helpers'
logger = require '../logger'
sysPath = require 'path'

call = (fn, arg) ->
  fn arg

initQueue = (onDrain) ->
  ioWaitQueue = []

  cpuQueue = async.queue call, 1
  cpuQueue.drain = onDrain

  ioQueue = async.queue call, 128
  ioQueue.drain = =>
    ioWaitQueue.forEach (task) =>
      process.nextTick =>
        cpuQueue.push task
    ioWaitQueue = []

  queue = async.queue (task, callback) =>
    ioQueue.push task.io
    ioWaitQueue.push task.cpu if task.cpu?
    callback()
  , 1
  queue

# A list of `fs_utils.SourceFile` or `fs_utils.Asset`
# with some additional methods used to simplify file reading / removing.
module.exports = class FileList extends EventEmitter
  # Maximum time between changes of two files that will be considered
  # as a one compilation.
  RESET_TIME: 65

  constructor: (@config) ->
    @files = []
    @assets = []
    @queue = initQueue @_resetTimer
    @on 'change', @_change
    @on 'unlink', @_unlink

  # Files that are not really app files.
  _ignored: (path, test = @config.paths.ignored) ->
    switch toString.call(test)
      when '[object RegExp]'
        path.match test
      when '[object Function]'
        test path
      when '[object String]'
        helpers.startsWith(sysPath.normalize(path), sysPath.normalize(test))
      when '[object Array]'
        test.some((subTest) => @_ignored path, subTest)
      else
        no

  _isAsset: (path) ->
    @config.paths.assets.some((dir) -> helpers.startsWith(path, dir))

  # Called every time any file was changed.
  # Emits `ready` event after `RESET_TIME`.
  _resetTimer: =>
    clearTimeout @timer if @timer?
    @timer = setTimeout (=> @emit 'ready'), @RESET_TIME

  _findByPath: (path) ->
    @files.filter((file) -> file.path is path)[0]

  _findAssetByPath: (path) ->
    @assets.filter((file) -> file.path is path)[0]

  _compileDependentFiles: (path) ->
    @files
      .filter (dependent) =>
        dependent.cache.dependencies.length
      .filter (dependent) =>
        path in dependent.cache.dependencies
      .forEach(@_compile)

  _compile: (file) =>
    @queue.push io: file.read, cpu: (callback) =>
      file.compile (error) =>
        logger.debug 'info', "Compiled file '#{file.path}'"
        if error?
          return logger.error "#{file.compilerName} failed in '#{file.path}' -- 
  #{error}"
        @_compileDependentFiles file.path
        callback()

  _copy: (asset) =>
    @queue.push io: (callback) =>
      asset.copy (error) =>
        logger.debug 'info', "Copied asset '#{asset.path}'"
        if error?
          return logger.error "Copying of '#{asset.path}' failed -- #{error}"
        callback()

  _add: (path, compiler, isHelper) ->
    isVendor = helpers.startsWith(path, @config.paths.vendor)
    file = new SourceFile path, compiler, isHelper, isVendor
    @files.push file
    file

  _addAsset: (path) ->
    file = new Asset path, @config
    @assets.push file
    file

  _change: (path, compiler, isHelper) =>
    if @_isAsset path
      @_copy (@_findAssetByPath(path) ? @_addAsset path)
    else if @_ignored(path) or not compiler
      @_compileDependentFiles path
    else
      @_compile (@_findByPath(path) ? @_add path, compiler, isHelper)

  _unlink: (path) =>
    if @_isAsset path
      @assets.splice(@assets.indexOf(path), 1)
    else if @_ignored path
      @_compileDependentFiles path
    else
      file = @_findByPath path
      @files.splice(@files.indexOf(file), 1)
    @_resetTimer()

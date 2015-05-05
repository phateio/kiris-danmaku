#!/bin/env node

express    = require('express')
bodyParser = require('body-parser')
fs         = require('fs')
mongodb    = require('mongodb')
url        = require('url')
dns        = require('dns')
emitter    = require('events').EventEmitter
crypto     = require('crypto')
irc        = require('irc')

$DEBUG  = not process.env.OPENSHIFT_APP_NAME

process.env.TZ = 'Asia/Taipei'

DEBUG = () ->
  parameters = Array.prototype.slice.call(arguments)
  parameters[0] = "%s [DEBUG] #{parameters[0]}"
  parameters.splice(1, 0, getTimeString('Y-m-d H:i:s'))
  console.log.apply(console, parameters)

INFO = () ->
  parameters = Array.prototype.slice.call(arguments)
  parameters[0] = "%s [INFO] #{parameters[0]}"
  parameters.splice(1, 0, getTimeString('Y-m-d H:i:s'))
  console.info.apply(console, parameters)

WARN = () ->
  parameters = Array.prototype.slice.call(arguments)
  parameters[0] = "%s [WARN] #{parameters[0]}"
  parameters.splice(1, 0, getTimeString('Y-m-d H:i:s'))
  console.warn.apply(console, parameters)

ERROR = () ->
  parameters = Array.prototype.slice.call(arguments)
  parameters[0] = "%s [ERROR] #{parameters[0]}"
  parameters.splice(1, 0, getTimeString('Y-m-d H:i:s'))
  console.error.apply(console, parameters)
  console.trace()

Array::last = ->
  @[@length - 1]

String::strip = ->
  @replace(/^\s+|\s+$/g, '')

String::insert_each_char = (separator) ->
  @match(new RegExp('.{1}', 'g')).join(separator)

String::insert_each_char_with_index = (separator) ->
  string_with_index = (if @length then @[0] else '')
  i = 1
  while i < @length
    string_with_index += separator + i + @[i]
    i++
  string_with_index

getTimeString = (format, datetime = (new Date())) ->
  Year   = datetime.getFullYear()
  Month  = datetime.getMonth() + 1
  Day    = datetime.getDate()
  Hour   = datetime.getHours()
  Minute = datetime.getMinutes()
  Second = datetime.getSeconds()
  format.replace('Y', Year)
        .replace('m', ('0' + Month).substr(-2))
        .replace('n', Month)
        .replace('d', ('0' + Day).substr(-2))
        .replace('j', Day)
        .replace('H', ('0' + Hour).substr(-2))
        .replace('i', ('0' + Minute).substr(-2))
        .replace('s', ('0' + Second).substr(-2))

strip_irc_colors = (text) ->
  text.replace(/[\x02\x1f\x16\x0f]|\x03\d{0,2}(?:,\d{0,2})?/g, '')

strip_hyper_links = (text) ->
  text.replace(/http(s?):\/\//g, 'ttp$1://')

get_ip_with_tripcode = (address, masked = false) ->
  tripcode = crypto.createHash('md5').update(address.toString()).digest('hex').substr(28, 4).toUpperCase()
  address.toString().replace /\.[0-9]+\.[0-9]+$/, '.' + if masked then '*' else tripcode

get_client_remote_address = (req) ->
  forwarded_for = req.header('X-FORWARDED-FOR')
  forwarded_for_last = if forwarded_for then forwarded_for.split(/\s*,\s*/).last() else null
  forwarded_for_last or req.connection.remoteAddress

get_client_forwarded_ips = (req) ->
  forwarded_for = req.header('X-FORWARDED-FOR')
  forwarded_for_match = if forwarded_for then forwarded_for.split(/\s*,\s*/) else null
  forwarded_for_match or [req.connection.remoteAddress]

jsonp_stringify = (object, callback = 'callback') ->
  callback = 'callback' if not (callback && callback.match(/^[A-Za-z0-9_\$]+$/i)?)
  callback + '(' + JSON.stringify(object) + ')'

class nodeIRC
  constructor: ->
    self = this
    self.chanName = '#phateio'
    self.channels = if $DEBUG then [self.chanName] else ['#phatecc', self.chanName]
    self.names = null
    self.client = new irc.Client('irc.rizon.net', 'danmaku',
      autoRejoin: true
      autoConnect: true
      channels: self.channels
      stripColors: true
    )

    INFO('node-irc initialize ...')

    self.client.addListener 'kill', (nick, reason, channels, message) ->
      DEBUG('%s has been killed. (%s)', nick, reason)

    self.client.addListener 'notice', (nick, to, text, message) ->
      DEBUG('<%s>(notice): %s', nick, text)

    self.client.addListener 'ctcp', (from, to, text, type, message) ->
      # DEBUG('<%s>(ctcp): %s', from, text)

    self.client.addListener 'ctcp-notice', (from, to, text, message) ->
      DEBUG('<%s>(ctcp-notice): %s', from, text)

    self.client.addListener 'ctcp-privmsg', (from, to, text, message) ->
      # DEBUG('<%s>(ctcp-privmsg): %s', from, text)

    self.client.addListener 'ctcp-version', (from, to, message) ->
      DEBUG('<%s>(ctcp-version): VERSION', from)
      self.client.ctcp(from, 'notice', 'VERSION node-irc 0.3.5')

    self.client.addListener '+mode', (channel, by_, mode, argument, message) ->
      DEBUG('%s mode %s', by_, argument)

    self.client.addListener '-mode', (channel, by_, mode, argument, message) ->
      DEBUG('%s mode %s', by_, argument)

    self.client.addListener 'nick', (oldnick, newnick, channels, message) ->
      DEBUG('%s is now known as %s', oldnick, newnick)

    self.client.addListener 'quit', (nick, reason, channels, message) ->
      DEBUG('%s has quit (%s)', nick, reason)

    self.client.addListener 'join' + self.chanName, (nick, message) ->
      DEBUG('%s has joined', nick)

    self.client.addListener 'part' + self.chanName, (nick, reason, message) ->
      DEBUG('%s has left (%s)', nick, reason)

    self.client.addListener 'kick' + self.chanName, (nick, by_, reason, message) ->
      DEBUG('%s has been kicked. %s (%s)', by_, nick, reason)

    self.client.addListener 'names' + self.chanName, (nicks) ->
      self.names = nicks

    self.client.addListener 'action', (from, to, text, message) ->
      DEBUG('%s %s', from, text)

    self.client.addListener 'message' + '#phatecc', (nick, text, message) ->
      DEBUG('<%s>: %s', nick, text)
      if match = text.match(/^!([A-Za-z]+)\s*(?:\s+(.+?)\s*(?:\s+(.+))?\s*)?$/)
        prefix = match[1] || ''
        action = match[2] || ''
        param1 = match[3] || ''

      prefix = prefix.toLowerCase() if prefix
      action = action.toLowerCase() if action

      if prefix == 'hang'
        target = strip_hyper_links(strip_irc_colors(text.slice(5).strip()))
        if target && (target.toUpperCase() == 'KEY君' || target.toUpperCase() == 'SUGISAKI')
          reasons = [
           '被丟出了窗外！'
          ]
          reason = reasons[Math.floor(Math.random() * reasons.length)]
          self.client.action('#phatecc', "\u000304[IRC] #{target} #{reason}")
        else if target
          reasons = [
           '和 KEY君 一起被丟出了窗外！'
          ]
          reason = reasons[Math.floor(Math.random() * reasons.length)]
          self.client.action('#phatecc', "\u000304[IRC] #{target} #{reason}")
        else
          self.client.say('#phatecc', "[IRC] Syntax: !hang <TARGET>")

    self.client.addListener 'message' + self.chanName, (nick, text, message) ->
      DEBUG('<%s>: %s', nick, text)
      if match = text.match(/^!([A-Za-z]+)\s*(?:\s+(.+?)\s*(?:\s+(.+))?\s*)?$/)
        prefix = match[1] || ''
        action = match[2] || ''
        param1 = match[3] || ''

      prefix = prefix.toLowerCase() if prefix
      action = action.toLowerCase() if action

      return if prefix != 'danmaku'

      switch action
        when 'boom'
          target = param1
          fragdata = danmaku.fragtable[target]
          uid = if fragdata then get_ip_with_tripcode(fragdata.ip) else null
          if uid
            danmaku.ban(uid, nick, 'IRC Report', null)
          else if target
            self.client.say(self.chanName, "IP address '#{target}' not found.")
          else
            self.client.say(self.chanName, "Syntax: !danmaku boom <TARGET>")
          return
        when 'unboom'
          target = param1
          uid = target
          if uid && danmaku.blacklist[uid]
            danmaku.unban(uid, nick)
          else if target
            self.client.say(self.chanName, "IP address '#{target}' not in the banlist.")
          else
            self.client.say(self.chanName, "Syntax: !danmaku unboom <TARGET>")
          return
        else
          self.client.say(self.chanName, "Syntax: !danmaku <boom|unboom> <TARGET>")
          return

    self.client.addListener 'pm', (nick, text, message) ->
      DEBUG('<%s>(private): %s', nick, text)
      if match = text.match(/^([A-Za-z]+)(?:\s+(.+?)(?:\s+(.+))?)?$/)
        action = match[1] || ''
        param1 = match[2] || ''
        param2 = match[3] || ''

      action = action.toLowerCase() if action

      switch action
        when 'banlist'
          blacklist = danmaku.blacklist
          for uid, item of blacklist
            time = getTimeString('Y-m-d H:i:s', new Date(item.timestamp))
            by_ = item.moderator
            message = "\u000306#{uid} \u000313due \u000304#{time} \u000313by \u000303#{by_}"
            self.client.notice(nick, message)
          self.client.ctcp(nick, 'notice', ':End of Danmaku Ban List')
          return
        when 'status'
          listener_count = danmaku.listener_count
          message = "There are \u000304#{listener_count} \u0003listeners online."
          self.client.ctcp(nick, 'notice', message)
          return

      if self.names[nick] != '@'
        self.client.ctcp(nick, 'notice', 'Permission denied')
        return

      switch action
        when 'ban'
          target = param1
          duration = parseInt(param2) || null
          danmaku.ban(target, nick, 'IRC Command', duration)
          return
        when 'unban'
          target = param1
          danmaku.unban(target, nick)
          return
        when 'say'
          message = if param2 then "#{param1} #{param2}" else param1
          danmaku.say message, '127.0.0.1',
            color: '0,255,0,0.9'
          return
        when 'mute'
          danmaku.mute = true
          message = "node-irc muted."
          self.client.ctcp(nick, 'notice', message)
          return
        when 'unmute'
          danmaku.mute = false
          message = "node-irc unmuted."
          self.client.ctcp(nick, 'notice', message)
          return
        when 'lookup'
          target = param1
          fragdata = danmaku.fragtable[target]
          userip = if fragdata then fragdata.ip else 'unknow'
          message = "User \u000306#{target} \u0003IP is \u000305#{userip}"
          dns.lookup userip, null, (err, address) ->
            message += " (#{address})" if not err
            self.client.ctcp(nick, 'notice', message)
          return
        when 'msg'
          target = param1
          message = param2
          self.client.say(target, message)
          return
        when 'notice'
          target = param1
          message = param2
          self.client.notice(target, message)
          return

    self.client.addListener 'error', (message) ->
      ERROR(message)

  say: (message) =>
    self = this
    self.client.say(self.chanName, message)

  action: (message) =>
    self = this
    self.client.action(self.chanName, message)

class Danmaku
  constructor: ->
    self = this
    self.listener_count = 0
    self.last_response_id = 0
    self.last_record_id = 0

    self.blacklist = {}
    self.fragtable = {}
    self.sensitive_words = []
    self.last_response_uid = 0
    self.last_blacklist_uid = 0

    self.history_limit = 50
    self.polliing_timeout = 60000

    self.mute = false
    self.last_response_time = (new Date()).getTime()
    self.metadata = {}
    self.metadata_updated = false
    self.secret_key = process.env.DANMAKU_SECRET_KEY || 'secret'

    self.sensitive_word_file_dir = './sensitive_words'
    self.html_path = './htdocs'

    if $DEBUG
      self.dbServer = new mongodb.Server('localhost', 27017)
      self.db = new mongodb.Db('database_demo', self.dbServer,
        auto_reconnect: true
      )
    else
      self.dbServer = new mongodb.Server(process.env.OPENSHIFT_MONGODB_DB_HOST,
                                parseInt(process.env.OPENSHIFT_MONGODB_DB_PORT))
      self.db = new mongodb.Db(process.env.OPENSHIFT_APP_NAME, self.dbServer,
        auto_reconnect: true
      )

    self.dbUser = process.env.OPENSHIFT_MONGODB_DB_USERNAME
    self.dbPass = process.env.OPENSHIFT_MONGODB_DB_PASSWORD
    self.dbMessageName = 'messages'
    self.dbConfigName = 'configurations'
    self.emitter = new emitter()

  setupVariables: =>
    self = this
    self.ipaddress = process.env.OPENSHIFT_NODEJS_IP
    self.port = process.env.OPENSHIFT_NODEJS_PORT or 8080
    if typeof self.ipaddress == 'undefined'
      WARN('No OPENSHIFT_NODEJS_IP var, using 127.0.0.1')
      self.ipaddress = '127.0.0.1'

  populateCache: =>
    self = this
    self.zcache = {'index.html': ''} if typeof self.zcache == 'undefined'
    self.zcache['403.html'] = fs.readFileSync("#{self.html_path}/403.html")

  cache_get: (key) =>
    self = this
    return self.zcache[key] if self.zcache[key]
    if $DEBUG
      fs.readFileSync("#{self.html_path}/#{key}")
    else
      self.zcache[key] = fs.readFileSync("#{self.html_path}/#{key}")

  terminator: (sig) =>
    self = this
    if typeof sig == 'string'
      INFO('Received %s - terminating sample app ...', sig)
      process.exit(1)
    INFO('Node server stopped.')

  setupTerminationHandlers: =>
    self = this
    process.on 'exit', ->
      self.terminator()

    [
      'SIGHUP'
      'SIGINT'
      'SIGQUIT'
      'SIGILL'
      'SIGTRAP'
      'SIGABRT'
      'SIGBUS'
      'SIGFPE'
      'SIGUSR1'
      'SIGSEGV'
      'SIGUSR2'
      'SIGTERM'
    ].forEach (element, index, array) ->
      process.on element, ->
        self.terminator(element)

  connectDb: (callback) =>
    self = this
    self.db.open (err, db) ->
      throw err if err
      if $DEBUG
        self.db.collection(self.dbMessageName).remove()
        callback()
      else
        self.db.authenticate self.dbUser, self.dbPass, (err, res) ->
          throw err if err
          self.db.collection(self.dbMessageName).remove()
          callback()

  loadStringFilter: (sensitive_word_file) =>
    self = this
    sensitive_word_array = fs.readFileSync(sensitive_word_file, 'utf8').split("\n")
    for sensitive_word_line in sensitive_word_array
      sensitive_word = sensitive_word_line.split('|')
      continue if sensitive_word.length != 3
      self.sensitive_words.push
        s: sensitive_word[0].strip()
        r: sensitive_word[1].strip()
        type: sensitive_word[2].strip()
    DEBUG('Load %d sensitive words from %s', self.sensitive_words.length, sensitive_word_file)

  stringFilter: (text) =>
    self = this
    safe_text = text
    for sensitive_word in self.sensitive_words
      switch sensitive_word.type
        when 'wildcard'
          pattern = new RegExp(sensitive_word.s.insert_each_char('(.*?)'), 'ig')
          replace = sensitive_word.r
          safe_text = safe_text.replace(pattern, replace)
        when 'partial'
          pattern = new RegExp(sensitive_word.s.insert_each_char('(.*?)'), 'ig')
          replace = sensitive_word.r.insert_each_char_with_index('$')
          safe_text = safe_text.replace(pattern, replace)
        when 'explicit'
          pattern = new RegExp(sensitive_word.s, 'ig')
          replace = sensitive_word.r
          safe_text = safe_text.replace(pattern, replace)
        else
          pattern = new RegExp(sensitive_word.s, 'ig')
          replace = sensitive_word.r
          safe_text = safe_text.replace(pattern, replace)
          if sensitive_word.type == 'ignore' && safe_text.indexOf(replace) != -1
            safe_text = "#{safe_text}\u0000"
    safe_text

  query: (last_id, callback) =>
    self = this
    self.db.collection(self.dbMessageName).find(
      id:
        $gt: last_id
    ,
      ip: 0
      _id: 0
    ).sort(id: 1).toArray (err, items) ->
      throw err if err
      callback(items)

  polling: =>
    self = this
    setInterval(->
      timestamp = (new Date()).getTime()
      if timestamp > self.last_response_time + self.polliing_timeout
        self.last_response_time = timestamp
        self.cleanfraglist()
        self.emitter.emit 'onmessage', []
        self.listener_count = 0
      return if self.last_response_id == self.last_record_id
      self.query self.last_response_id, (items) ->
        DEBUG('Return %d rows. (%d listeners)', items.length, self.listener_count)
        self.emitter.emit('onmessage', items)
        self.listener_count = 0
        self.last_response_id = self.last_record_id
      return
    , 200)

  cleanfraglist: =>
    self = this
    timestamp = (new Date()).getTime()
    for i of self.blacklist
      delete self.blacklist[i] if self.blacklist[i].timestamp <= timestamp
    for i of self.fragtable
      delete self.fragtable[i] if self.fragtable[i].timestamp <= timestamp - 60 * 60 * 1000

  browserCheck: (req) =>
    self = this
    useragent = req.header('USER-AGENT')
    referer = req.header('REFERER')
    throw 'REFERRAL_DENIED' if not referer
    domain = url.parse(referer, true).hostname
    return if $DEBUG
    if not (domain && domain.match(/^(?:[A-Za-z0-9\-\.]+\.)?phate\.(?:io|cc|us|tw|org)$/i)?)
      safe_referer = strip_hyper_links(strip_irc_colors(referer))
      throw "REFERRAL_DENIED: #{safe_referer}"

  loadBlacklist: =>
    self = this
    self.db.collection(self.dbConfigName).find(
      name: 'blacklist'
    ).sort(id: 1).toArray (err, items) ->
      throw err if err
      return if items.length == 0
      self.blacklist = JSON.parse(items[0].text)
      DEBUG('Load %d blacklist items from database.', Object.keys(self.blacklist).length)

  saveBlacklist: =>
    self = this
    criteria =
      name: 'blacklist'
    data =
      name: 'blacklist'
      text: JSON.stringify(self.blacklist)
    options =
      upsert: true
    self.db.collection(self.dbConfigName).update criteria, data, options, (err, count, status) ->
      throw err if err
      DEBUG('Save blacklist to database. Returned %s', status)

  blacklistCheck: (ip) =>
    self = this
    uid = get_ip_with_tripcode(ip)
    mid = get_ip_with_tripcode(ip, true)
    timestamp = (new Date()).getTime()
    if self.blacklist[uid]
      throw 'BLACKLIST'
    else if self.blacklist[mid]
      throw 'BLACKLIST'

  fragtableCheck: (ip) =>
    self = this
    uid = get_ip_with_tripcode(ip)
    timestamp = (new Date()).getTime()
    if self.fragtable[uid]
      if self.fragtable[uid].timestamp > timestamp - 60 * 1000
        if self.fragtable[uid].count >= 30
          self.fragtable[uid].timestamp = timestamp
          throw 'FREQUENCY_PERIOD_' + self.fragtable[uid].count
        if self.last_response_uid == uid && self.fragtable[uid].combo >= 10
          self.fragtable[uid].timestamp = timestamp
          throw 'FREQUENCY_SERISE_' + self.fragtable[uid].combo
        self.fragtable[uid].combo++ if self.last_response_uid == uid
        self.fragtable[uid].count++
      else
        self.fragtable[uid].combo = 1
        self.fragtable[uid].count = 1
        self.fragtable[uid].timestamp = timestamp
    else
      self.fragtable[uid] =
        timestamp: timestamp
        ip: ip
        combo: 1
        count: 1
    self.last_response_uid = uid

  ignoredWordsCheck: (text) =>
    self = this
    throw 'IGNORED' if text.indexOf("\u0000") != -1

  say: (text, address, attributes = {}, callback = false) =>
    self = this
    uid = get_ip_with_tripcode(address)
    timestamp = (new Date()).getTime()

    top = attributes.top || Math.random()
    color = attributes.color || '255,255,255,0.9'
    size = attributes.size || 1.0
    weight = attributes.weight || 'bold'
    speed = attributes.speed || 1.0

    item =
      id: self.last_record_id + 1
      text: text
      top: top
      color: color.split(',')
      size: size
      weight: weight
      speed: speed
      uid: uid
      ip: address
      timestamp: timestamp

    self.db.collection(self.dbMessageName).insert item, (result) ->
      DEBUG('Insert id %d (%s)', self.last_record_id, address)
      callback() if callback
    self.last_record_id++

    if not self.mute
      if self.metadata_updated
        title = self.metadata.title
        artist = self.metadata.artist
        tags = self.metadata.tags
        nodeirc.say("\u000306Now playing: \u000314#{artist} - #{title} (#{tags})")
        self.metadata_updated = false
      nodeirc.action("\u000306[#{uid}] \u000314#{text}")

  system_say: (text) =>
    self = this
    self.say text, '127.0.0.1',
      color: '255,0,0,0.9'
      size: 0.5
      speed: 0.75

  ban: (uid, by_, reason, duration = 3600) =>
    self = this
    now_time = (new Date()).getTime()
    timestamp = if self.blacklist[uid] then self.blacklist[uid].timestamp else now_time
    new_timestamp = timestamp + duration * 1000
    self.blacklist[uid] =
      moderator: by_
      timestamp: new_timestamp
    duration_hours = parseInt((new_timestamp - now_time) / 3600 / 1000)
    if not self.mute
      nodeirc.action("\u000304#{uid} has been banned #{duration_hours} hours. (#{reason} by #{by_})")
      self.system_say("#{uid} has been banned #{duration_hours} hours. (#{reason})")
    self.saveBlacklist()

  unban: (uid, by_) =>
    self = this
    delete self.blacklist[uid] if self.blacklist[uid]
    nodeirc.action("\u000303#{uid} has been unbanned.") if not self.mute

  createRoutes: =>
    self = this
    self.routes =
      GET: {}
      POST: {}

    self.routes['GET']['/'] = (req, res) ->
      res.setHeader('Content-Type', 'text/html')
      if $DEBUG
        res.send(self.cache_get('index.html'))
      else
        res.send(self.cache_get('403.html'))

    self.routes['GET']['/robots.txt'] = (req, res) ->
      res.setHeader('Content-Type', 'text/plain')
      res.send(self.cache_get('robots.txt'))

    self.routes['GET']['/post'] = (req, res) ->
      res.setHeader('Content-Type', 'text/javascript; charset=utf-8')
      ret =
        code: 200
        status: 'OK'
        data: []

      params = url.parse(req.url, true).query
      timestamp = (new Date()).getTime()
      ip = get_client_remote_address(req)
      forwarded_ips = get_client_forwarded_ips(req)
      uid = get_ip_with_tripcode(ip)
      callback = params.callback
      text = params.text

      text = text.substr(0, 64)
      text = strip_hyper_links(strip_irc_colors(self.stringFilter(text)))

      try
        self.browserCheck(req)
        self.blacklistCheck(ip)
        self.fragtableCheck(address) for address in forwarded_ips
        self.ignoredWordsCheck(text)
        self.say(text, ip)
      catch error
        switch error
          when 'BLACKLIST'
            ret.code = 418
            ret.status = 'I\'m a teapot'
          else
            ret.code = 500
            ret.status = error
        WARN('%s (%s)', error, ip)
        if not self.mute && self.last_blacklist_uid != uid
          nodeirc.action("\u000306[#{uid}]\u000301,01 #{text} \u000304(#{error})")
        self.last_blacklist_uid = uid
      res.send(jsonp_stringify(ret, callback))

    self.routes['GET']['/poll'] = (req, res) ->
      res.setHeader('Content-Type', 'text/javascript; charset=utf-8')
      ret =
        code: 200
        status: 'OK'
        data: []

      params = url.parse(req.url, true).query
      user_last_id = parseInt(params.last_id) || parseInt(params.lastid) # Deprecated
      callback = params.callback
      if not (user_last_id && user_last_id >= self.last_record_id - self.history_limit && user_last_id <= self.last_record_id)
        user_last_id = self.last_record_id

      if user_last_id < self.last_record_id
        self.query user_last_id, (items) ->
          ret.data = items
          res.send(jsonp_stringify(ret, callback))
          return
      else
        # DEBUG('Hook from %s', ip)
        self.listener_count++
        self.emitter.once 'onmessage', (items) ->
          ret.data = []
          for item in items
            ret.data.push(item) if item.id > user_last_id
          res.send(jsonp_stringify(ret, callback))

    self.routes['GET']['/report'] = (req, res) ->
      res.setHeader('Content-Type', 'text/javascript; charset=utf-8')
      ret =
        code: 200
        status: 'OK'

      params = url.parse(req.url, true).query
      timestamp = (new Date()).getTime()
      ip = get_client_remote_address(req)
      forwarded_ips = get_client_forwarded_ips(req)
      uid = get_ip_with_tripcode(ip)
      target_uid = params.target_uid
      callback = params.callback

      try
        self.browserCheck(req)
        self.blacklistCheck(ip)
        self.fragtableCheck(address) for address in forwarded_ips
        fragdata = self.fragtable[target_uid]
        target_uid = if fragdata then get_ip_with_tripcode(fragdata.ip) else null
        throw 'UID Not Found' if not target_uid
        self.ban(target_uid, uid, 'Online Report', null)
      catch error
        switch error
          when 'BLACKLIST'
            ret.code = 418
            ret.status = 'I\'m a teapot'
          else
            ret.code = 500
            ret.status = error
        WARN('%s (%s)', error, ip)
        if not self.mute && self.last_blacklist_uid != uid
          nodeirc.action("\u000306#{uid}\u000314 is trying to report #{target_uid} \u000304(#{error})")
        self.last_blacklist_uid = uid
      res.send(jsonp_stringify(ret, callback))

    self.routes['POST']['/metadata'] = (req, res) ->
      res.setHeader 'Content-Type', 'text/javascript; charset=utf-8'
      ret =
        code: 200
        status: 'OK'
        data: []

      params = url.parse(req.url, true).query
      ip = get_client_remote_address(req)
      callback = params.callback
      title = req.body.title
      artist = req.body.artist
      tags = req.body.tags
      authorized = self.secret_key && self.secret_key == req.body.secret_key

      try
        throw 'Permission_denied' if not authorized
        self.metadata =
          title: title
          artist: artist
          tags: tags
        self.metadata_updated = true
      catch error
        ret.code = 403
        ret.status = error
        WARN('%s (%s)', error, ip)

      res.send(jsonp_stringify(ret, callback))

  initializeServer: =>
    self = this
    self.createRoutes()
    self.app = express()
    self.app.use(bodyParser.urlencoded(extended: true))
    for r of self.routes['GET']
      self.app.get(r, self.routes['GET'][r])
    for r of self.routes['POST']
      self.app.post(r, self.routes['POST'][r])

  initialize: =>
    self = this
    self.setupVariables()
    self.populateCache()
    self.setupTerminationHandlers()
    self.emitter.setMaxListeners(1000)
    self.initializeServer()

  start: =>
    self = this
    self.loadBlacklist()
    sensitive_word_files = fs.readdirSync(self.sensitive_word_file_dir)
    for sensitive_word_file in sensitive_word_files
      self.loadStringFilter("#{self.sensitive_word_file_dir}/#{sensitive_word_file}")
    self.polling()
    self.app.listen self.port, self.ipaddress, ->
      INFO('Node server started on %s:%d ...', self.ipaddress, self.port)

danmaku = new Danmaku()
nodeirc = new nodeIRC()
danmaku.initialize()
danmaku.connectDb(danmaku.start)

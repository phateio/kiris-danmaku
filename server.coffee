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

$DEBUG  = not process.env.SHELL

process.env.TZ = 'Asia/Taipei'
process.stdin.resume()
process.stdin.setEncoding('utf8')

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

object_length = (obj) ->
  Object.keys(obj).length

strip_irc_colors = (text) ->
  text.replace(/[\x02\x1f\x16\x0f]|\x03\d{0,2}(?:,\d{0,2})?/g, '')

strip_hyper_links = (text) ->
  text.replace(/http(s?):\/\//g, 'ttp$1://')

get_ip_with_tripcode = (address, masked = false) ->
  hashed_address = crypto.createHash('md5').update(address.toString()).digest('hex')
  ip_with_tripcode = null
  if address.match(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)?
    tripcode = hashed_address.substr(28, 4).toUpperCase()
    ip_with_tripcode = address.toString().replace(/\.[0-9]+\.[0-9]+$/, '.' + if masked then '*' else tripcode)
  else
    tripcode = hashed_address.substr(24, 8).toLowerCase()
    ip_with_tripcode = address.toString().replace(/^(\w+\:\w+|\w+|)(?:\:\w*)+$/, '\$1::' + if masked then '*' else tripcode)
  ip_with_tripcode

get_client_remote_address = (req) ->
  req.header('X-Real-IP') or req.connection.remoteAddress

get_client_remote_addresses = (req) ->
  real_ip_address = req.header('X-Real-IP') or req.connection.remoteAddress
  forwarded_for = req.header('X-FORWARDED-FOR')
  if forwarded_for
    forwarded_for_match = forwarded_for.split(/\s*,\s*/)
    forwarded_for_match.shift
    forwarded_for_match.push(real_ip_address)
  else
    forwarded_for_match = null
  forwarded_for_match or [real_ip_address]

jsonp_stringify = (object, callback = 'callback') ->
  callback = 'callback' if not (callback && callback.match(/^[A-Za-z0-9_\$]+$/i)?)
  callback + '(' + JSON.stringify(object) + ')'

class nodeIRC
  constructor: ->
    self = this
    self.chanName = '#phateio'
    self.channels = if $DEBUG then [self.chanName] else ['#phatecc', self.chanName]
    self.channel_names = {}
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
      DEBUG('%s sets mode +%s on %s', by_, mode, argument)
      if mode == 'o'
        self.channel_names[channel][argument] = '@'

    self.client.addListener '-mode', (channel, by_, mode, argument, message) ->
      DEBUG('%s sets mode -%s on %s', by_, mode, argument)
      if mode == 'o'
        self.channel_names[channel][argument] = ''

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

    self.client.addListener 'names', (channel, nicks) ->
      self.channel_names[channel] = nicks

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
            danmaku.ban(uid, nick, 'IRC Report', 86400 * 3)
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
            response = "\u000306#{uid} \u000313due \u000304#{time} \u000313by \u000303#{by_}"
            self.client.notice(nick, response)
          self.client.ctcp(nick, 'notice', ':End of Danmaku Ban List')
          return
        when 'status'
          addresses_count = object_length(danmaku.addresslist)
          response = "There are \u000304#{addresses_count} \u0003unique IP addresses online."
          self.client.ctcp(nick, 'notice', response)
          return

      if self.channel_names[self.chanName][nick] != '@'
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
        when 'lookup'
          target = param1
          fragdata = danmaku.fragtable[target]
          if fragdata
            userip = fragdata.ip
            message = "User \u000306#{target} \u0003IP is \u000305#{userip}"
            dns.reverse userip, (err, hostnames) ->
              message += " (#{hostnames.join(', ')})" if not err
              self.client.ctcp(nick, 'notice', message)
          else
            message = "User \u000306#{target} \u0003IP is \u000305Unknow"
            self.client.ctcp(nick, 'notice', message)
          return
        when 'onlines'
          fragtable = danmaku.fragtable
          for uid, item of fragtable
            item_json_string = JSON.stringify(item)
            message = "\u000306#{uid} \u000313#{item_json_string}"
            self.client.notice(nick, message)
          self.client.ctcp(nick, 'notice', ':End of Danmaku online List')
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
      console.log(message)

  say: (message) =>
    self = this
    self.client.say(self.chanName, message)

  action: (message) =>
    self = this
    self.client.action(self.chanName, message)

  send: () =>
    self = this
    parameters = Array.prototype.slice.call(arguments)
    self.client.send.apply(self.client, parameters)

class Danmaku
  constructor: ->
    self = this
    self.listener_count = 0
    self.last_response_id = 0
    self.last_record_id = 0

    self.blacklist = {}
    self.fragtable = {}
    self.addresslist = {}
    self.sensitive_words = []
    self.last_response_uid = 0
    self.last_blacklist_uid = 0

    self.history_limit = 50
    self.polliing_timeout = 60000

    self.last_response_time = (new Date()).getTime()
    self.metadata = {}
    self.metadata_updated = false
    self.secret_key = process.env.DANMAKU_SECRET_KEY || 'secret'

    self.sensitive_word_file_dir = './sensitive_words'
    self.html_path = './htdocs'

    self.dbServer = new mongodb.Server('localhost', 27017)
    self.db = new mongodb.Db('nodedanmaku', self.dbServer,
      auto_reconnect: true
    )

    self.dbMessageName = 'messages'
    self.dbConfigName = 'configurations'
    self.emitter = new emitter()

  setupVariables: =>
    self = this
    self.ipaddress = '127.0.0.1'
    self.port = 8124

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
      self.db.collection(self.dbMessageName).remove()
      callback()

  loadSensitiveWordList: (sensitive_word_file) =>
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

  replaceSensitiveWords: (text) =>
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

  findMessage: (id, callback) =>
    self = this
    query =
      id: id
    projection =
      _id: 0
    self.db.collection(self.dbMessageName).find(
      query,
      projection
    ).limit(1).toArray (err, items) ->
      throw err if err
      callback(items)

  findUnreadMessages: (id, callback) =>
    self = this
    query =
      id:
        $gt: id
    projection =
      ip: 0
      _id: 0
    self.db.collection(self.dbMessageName).find(
      query,
      projection
    ).sort(id: 1).toArray (err, items) ->
      throw err if err
      callback(items)

  polling: =>
    self = this
    setInterval(->
      timestamp = (new Date()).getTime()
      if timestamp > self.last_response_time + self.polliing_timeout
        self.last_response_time = timestamp
        self.expireLists()
        self.emitter.emit 'onmessage', []
        self.listener_count = 0
      return if self.last_response_id == self.last_record_id
      self.findUnreadMessages self.last_response_id, (items) ->
        DEBUG('Return %d rows. (%d listeners)', items.length, self.listener_count)
        self.emitter.emit('onmessage', items)
        self.listener_count = 0
        self.last_response_id = self.last_record_id
      return
    , 200)

  expireLists: =>
    self = this
    timestamp = (new Date()).getTime()
    for i of self.blacklist
      delete self.blacklist[i] if self.blacklist[i].timestamp <= timestamp
    for i of self.fragtable
      delete self.fragtable[i] if self.fragtable[i].timestamp <= timestamp - 60 * 60 * 1000
    for i of self.addresslist
      delete self.addresslist[i] if self.addresslist[i].timestamp <= timestamp - 90 * 1000

  browserCheck: (req) =>
    self = this
    useragent = req.header('USER-AGENT')
    referer = req.header('REFERER')
    throw 'REFERRAL_DENIED' if not referer
    domain = url.parse(referer, true).hostname
    return if $DEBUG
    if not (domain && domain.match(/^(?:[A-Za-z0-9\-\.]+\.)?phate\.io$/i)?)
      safe_referer = strip_hyper_links(strip_irc_colors(referer))
      throw "REFERRAL_DENIED: #{safe_referer}"

  loadBlacklist: =>
    self = this
    self.db.collection(self.dbConfigName).find(
      name: 'blacklist'
    ).limit(1).toArray (err, items) ->
      throw err if err
      return if items.length == 0
      self.blacklist = JSON.parse(items[0].text)
      DEBUG('Load %d blacklist items from database.', object_length(self.blacklist))

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
        flag: {}
    self.last_response_uid = uid

  addresslistCheck: (ip) =>
    self = this
    timestamp = (new Date()).getTime()
    self.addresslist[ip] = 
      timestamp: timestamp
      ip: ip

  ignoredWordsCheck: (text) =>
    self = this
    throw 'IGNORED' if text.indexOf("\u0000") != -1

  say: (text, address, attributes = {}, callback = false) =>
    self = this
    id = self.last_record_id + 1
    uid = get_ip_with_tripcode(address)
    timestamp = (new Date()).getTime()

    top = if attributes.top == undefined then Math.random() else attributes.top
    color = attributes.color || '255,255,255,0.9'
    size = attributes.size || 1.0
    weight = attributes.weight || 'bold'
    speed = attributes.speed || 1.0

    item =
      id: id
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

    if self.metadata_updated
      title = self.metadata.title
      artist = self.metadata.artist
      tags = self.metadata.tags
      nodeirc.say("\u000306Now playing: \u000314#{artist} - #{title} (#{tags})")
      self.metadata_updated = false
    nodeirc.action("\u000306~#{uid} \u000310##{id} \u000314#{text}")

  system_say: (text, attributes = {}) =>
    self = this
    attributes.color ||= '255,0,0,0.9'
    attributes.size ||= 0.75
    attributes.speed ||= 0.75
    attributes.address ||= '127.0.0.1'
    self.say(text, attributes.address, attributes)

  ban: (uid, by_, reason, duration = 3600, message = '') =>
    self = this
    now_time = (new Date()).getTime()
    timestamp = if self.blacklist[uid] then self.blacklist[uid].timestamp else now_time
    new_timestamp = timestamp + duration * 1000
    self.blacklist[uid] =
      moderator: by_
      timestamp: new_timestamp
    duration_hours = parseInt((new_timestamp - now_time) / 3600 / 1000)
    self.system_say("“#{message}” has been banned #{duration_hours} hours. (#{reason})") if message
    nodeirc.action("\u000301,04#{uid} has been banned #{duration_hours} hours. (#{reason})")
    self.saveBlacklist()

  unban: (uid, by_) =>
    self = this
    delete self.blacklist[uid] if self.blacklist[uid]
    nodeirc.action("\u000301,03#{uid} has been unbanned.")
    self.saveBlacklist()

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
      addresses = get_client_remote_addresses(req)
      uid = get_ip_with_tripcode(ip)
      callback = params.callback
      text = params.text || ''

      text = text.substr(0, 64)
      text = strip_hyper_links(strip_irc_colors(self.replaceSensitiveWords(text)))

      try
        self.browserCheck(req)
        self.blacklistCheck(ip)
        self.fragtableCheck(address) for address in addresses
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
        if self.last_blacklist_uid != uid
          nodeirc.action("\u000306~#{uid} \u000310#BAKA \u000301,01 #{text} \u000304(#{error})")
        self.last_blacklist_uid = uid
      res.send(jsonp_stringify(ret, callback))

    self.routes['GET']['/poll'] = (req, res) ->
      res.setHeader('Content-Type', 'text/javascript; charset=utf-8')
      ret =
        code: 200
        status: 'OK'
        data: []

      params = url.parse(req.url, true).query
      timestamp = (new Date()).getTime()
      ip = get_client_remote_address(req)
      user_last_id = parseInt(params.last_id)
      callback = params.callback
      unless user_last_id && user_last_id >= self.last_record_id - self.history_limit \
      && user_last_id <= self.last_record_id
        user_last_id = self.last_record_id
      self.addresslistCheck(ip)

      if user_last_id < self.last_record_id
        self.findUnreadMessages user_last_id, (items) ->
          ret.data = items
          res.send(jsonp_stringify(ret, callback))
      else
        # DEBUG('Hook from %s', ip)
        self.listener_count++
        self.emitter.once 'onmessage', (items) ->
          ret.data = items
          res.send(jsonp_stringify(ret, callback))

    self.routes['GET']['/report'] = (req, res) ->
      res.setHeader('Content-Type', 'text/javascript; charset=utf-8')
      ret = {}

      params = url.parse(req.url, true).query
      timestamp = (new Date()).getTime()
      ip = get_client_remote_address(req)
      addresses = get_client_remote_addresses(req)
      uid = get_ip_with_tripcode(ip)
      target_id = parseInt(params.target_id)
      callback = params.callback

      self.findMessage target_id, (items) ->
        try
          self.browserCheck(req)
          self.blacklistCheck(ip)
          self.fragtableCheck(address) for address in addresses
          throw 'Message ID Not Found' if items.length == 0
          item = items[0]
          target_uid = item.uid
          target_message = item.text
          throw 'Target UID Not Found' unless self.fragtable[target_uid]
          if self.fragtable[target_uid].flag[uid]
            nodeirc.action("\u000307#{target_uid} has been reported by #{uid} (duplicated)")
          else
            self.fragtable[target_uid].flag[uid] = 1
            if object_length(self.fragtable[target_uid].flag) >= 2
              self.ban(target_uid, uid, "Online Report by #{uid}", 86400, target_message)
            else
              self.system_say(
                "“#{target_message}” has been reported (Online Report by #{uid})",
                color: '255,128,0,0.9'
              )
              nodeirc.action("\u000301,07“#{target_message}” has been reported by #{uid}")
        catch error
          switch error
            when 'BLACKLIST'
              ret['message'] = 'I\'m a teapot'
            else
              ret['message'] = error
          WARN('%s (%s)', error, ip)
          if self.last_blacklist_uid != uid
            nodeirc.action("\u000306#{uid}\u000314 is trying to report ##{target_id} \u000304(#{error})")
          self.last_blacklist_uid = uid
        res.send(jsonp_stringify(ret, callback))

    self.routes['GET']['/status'] = (req, res) ->
      res.setHeader('Content-Type', 'application/json; charset=utf-8')
      ret = {}
      ret['date'] = new Date()
      ret['onlines'] = object_length(self.addresslist)
      res.send(JSON.stringify(ret))

    self.routes['POST']['/metadata'] = (req, res) ->
      res.setHeader 'Content-Type', 'application/json; charset=utf-8'
      ret = {}

      ip = get_client_remote_address(req)
      title = req.body.title
      artist = req.body.artist
      tags = req.body.tags
      authorized = self.secret_key && self.secret_key == req.body.secret_key

      try
        throw 'Permission denied' if not authorized
        self.metadata =
          title: title
          artist: artist
          tags: tags
        self.metadata_updated = true
      catch error
        ret['message'] = error
        WARN('%s (%s)', error, ip)
      res.send(JSON.stringify(ret))

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
      self.loadSensitiveWordList("#{self.sensitive_word_file_dir}/#{sensitive_word_file}")
    self.polling()
    self.app.listen self.port, self.ipaddress, ->
      INFO('Node server started on %s:%d ...', self.ipaddress, self.port)

danmaku = new Danmaku()
nodeirc = new nodeIRC()
danmaku.initialize()
danmaku.connectDb(danmaku.start)

process.stdin.on 'data', (chunk) ->
  text = chunk.strip()
  nodeirc.send.apply(this, text.split(/\0+/))

_     = require("lodash")
Proxy = require("./proxy")

defaults =
  root: "/var/www"

module.exports = exports = (opts = {}) ->
  opts = _.merge(defaults, opts)
  return new Proxy(opts)
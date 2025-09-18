const {ecsSettings, serverSettings} = require('./config')
const {initDI} = require('./di')
const init = initDI.bind(null, {serverSettings, ecsSettings})

module.exports = Object.assign({}, {init})

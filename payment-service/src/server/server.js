const express = require('express')
const morgan = require('morgan')
const helmet = require('helmet')
const bodyparser = require('body-parser')
const cors = require('cors')
const _api = require('../api/payment')

const start = (options) => {
  return new Promise((resolve, reject) => {
    if (!options.repo) {
      reject(new Error('The server must be started with a connected repository'))
    }
    if (!options.port) {
      reject(new Error('The server must be started with an available port'))
    }

    const app = express()
    app.use(morgan('dev'))
    app.use(bodyparser.json())
    app.use(cors())
    app.use(helmet())
    app.use((err, req, res, next) => {
      reject(new Error('Something went wrong!, err:' + err))
      res.status(500).send('Something went wrong!')
      next()
    })

    const api = _api.bind(null, {repo: options.repo})
    api(app)

    const server = app.listen(options.port, () => resolve(server))
  })
}

module.exports = Object.assign({}, {start})

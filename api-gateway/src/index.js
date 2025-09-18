'use strict'
const {EventEmitter} = require('events')
const server = require('./server/server')
const ecs = require('./ecs/ecs')
const di = require('./config')
const mediator = new EventEmitter()

console.log('--- API Gateway Service ---')
console.log('Connecting to API repository...')
console.log('Environment:', {
  NODE_ENV: process.env.NODE_ENV,
  PORT: process.env.PORT,
  MOVIES_SERVICE_URL: process.env.MOVIES_SERVICE_URL,
  BOOKING_SERVICE_URL: process.env.BOOKING_SERVICE_URL
})

process.on('uncaughtException', (err) => {
  console.error('Unhandled Exception', err)
  process.exit(1)
})

process.on('uncaughtRejection', (err, promise) => {
  console.error('Unhandled Rejection', err)
  process.exit(1)
})

mediator.on('di.ready', (container) => {
  console.log('DI Container ready, starting route discovery...')
  
  ecs.discoverRoutes(container)
    .then(routes => {
      console.log('Routes discovered successfully:', Object.keys(routes))
      console.log('Connected. Starting Server')
      container.registerValue({routes})
      return server.start(container)
    })
    .then(app => {
      console.log(`Connected to ECS services: ${Object.keys(container.cradle.ecsSettings.services).join(', ')}`)
      console.log(`Server started succesfully, API Gateway running on port: ${container.cradle.serverSettings.port}.`)
      app.on('close', () => {
        console.log('Server finished')
      })
    })
    .catch(error => {
      console.error('Error starting API Gateway:', error)
      console.error('Error stack:', error.stack)
      // Avvia comunque il server con routes vuote per permettere l'health check
      console.log('Starting server with empty routes for health check...')
      container.registerValue({routes: {}})
      return server.start(container)
    })
    .then(app => {
      if (app) {
        console.log(`API Gateway running on port: ${container.cradle.serverSettings.port} (with fallback mode)`)
        app.on('close', () => {
          console.log('Server finished')
        })
      }
    })
    .catch(error => {
      console.error('Fatal error starting API Gateway:', error)
      console.error('Fatal error stack:', error.stack)
      process.exit(1)
    })
})

di.init(mediator)

mediator.emit('init')

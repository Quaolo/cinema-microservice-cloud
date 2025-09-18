'use strict'
const server = require('./server/server')
const repository = require('./repository/repository')
const di = require('./config')
const config = require('./config/')
const { connectToMongoDB } = require('./config/mongodb-atlas')

console.log('--- Notification Service ---')
console.log('Connecting to notification repository...')

process.on('uncaughtException', (err) => {
  console.error('Unhandled Exception', err)
  process.exit(1)
})

process.on('uncaughtRejection', (err, promise) => {
  console.error('Unhandled Rejection', err)
  process.exit(1)
})

// Connessione a MongoDB Atlas
connectToMongoDB().then(() => {
  const {EventEmitter} = require('events')
  const mediator = new EventEmitter()
  
  // Inizializza DI
  di.init(mediator)
  
  mediator.on('di.ready', (container) => {
    repository.connect(container)
      .then(repo => {
        console.log('Connected. Starting Server')
        container.registerValue({repo})
        return server.start(container)
      })
      .then(app => {
        console.log(`Server started succesfully, running on port: ${container.cradle.serverSettings.port}.`)
        app.on('close', () => {
          container.resolve('repo').disconnect()
        })
      })
      .catch(err => {
        console.error('Error starting server:', err)
        process.exit(1)
      })
  })
  
  mediator.emit('init')
}).catch(err => {
  console.error('Error connecting to MongoDB Atlas:', err)
  process.exit(1)
})

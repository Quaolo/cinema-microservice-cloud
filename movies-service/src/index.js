'use strict'
const server = require('./server/server')
const repository = require('./repository/repository')
const config = require('./config/')
const { connectToMongoDB } = require('./config/mongodb-atlas')

console.log('--- Movies Service ---')
console.log('Connecting to MongoDB Atlas...')

process.on('uncaughtException', (err) => {
  console.error('Unhandled Exception', err)
  process.exit(1)
})

process.on('uncaughtRejection', (err, promise) => {
  console.error('Unhandled Rejection', err)
  process.exit(1)
})

// Connessione diretta a MongoDB Atlas con Mongoose
connectToMongoDB()
  .then(() => {
    console.log('Connected to MongoDB Atlas. Starting Server')
    
    // Crea il repository (ora non dipende più dal parametro db)
    return repository.connect(null)
  })
  .then(rep => {
    console.log('Repository created successfully')
    
    return server.start({
      port: config.serverSettings.port,
      ssl: config.serverSettings.ssl,
      repo: rep
    })
  })
  .then(app => {
    console.log(`Server started successfully, running on port: ${config.serverSettings.port}.`)
    app.on('close', () => {
      console.log('Server closing...')
    })
  })
  .catch(err => {
    console.error('Failed to start server:', err)
    process.exit(1)
  })

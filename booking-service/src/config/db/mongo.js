const { MongoClient } = require('mongodb')

let client

async function connect(options, mediator) {
  mediator.once('boot.ready', async () => {
    try {
      // Usa atlasUri se disponibile, altrimenti costruisci URL locale
      const connectionString = options.atlasUri || getMongoURL(options)
      
      console.log('Connecting to MongoDB:', connectionString.includes('mongodb+srv://') ? 'MongoDB Atlas' : 'Local MongoDB')
      
      // MongoDB 4.x connection options
      const clientOptions = {
        writeConcern: options.dbParameters(),
        serverSelectionTimeoutMS: 30000,
        connectTimeoutMS: 30000,
        socketTimeoutMS: 30000,
        maxPoolSize: 10,
        retryWrites: true
      }

      client = new MongoClient(connectionString, clientOptions)
      await client.connect()
      
      // Get database
      const db = client.db(options.db)
      
      // Skip authentication for MongoDB Atlas (handled in connection string)
      if (connectionString.includes('mongodb+srv://')) {
        console.log('Connected to MongoDB Atlas successfully')
        mediator.emit('db.ready', db)
      } else {
        // Local MongoDB authentication
        try {
          await db.admin().authenticate(options.user, options.pass)
          console.log('Connected to local MongoDB successfully')
          mediator.emit('db.ready', db)
        } catch (authErr) {
          console.error('MongoDB authentication error:', authErr)
          mediator.emit('db.error', authErr)
        }
      }
    } catch (err) {
      console.error('MongoDB connection error:', err)
      mediator.emit('db.error', err)
    }
  })
}

// Funzione per costruire URL MongoDB locale
const getMongoURL = (options) => {
  const url = options.servers
    .reduce((prev, cur) => prev + cur + ',', 'mongodb://')

  return `${url.substr(0, url.length - 1)}/${options.db}`
}

function close() {
  if (client) {
    return client.close()
  }
}

module.exports = { connect, close }
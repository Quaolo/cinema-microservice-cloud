const { MongoClient } = require('mongodb')

const getMongoURL = (options) => {
  const url = options.servers
    .reduce((prev, cur) => prev + cur + ',', 'mongodb://')

  return `${url.substr(0, url.length - 1)}/${options.db}`
}

const connect = async (options, mediator) => {
  mediator.once('boot.ready', async () => {
    try {
      // Use MongoDB Atlas if available, otherwise use local MongoDB
      const connectionString = options.atlasUri || getMongoURL(options)
      
      console.log('MongoDB Configuration:')
      console.log('- Atlas URI:', options.atlasUri ? 'SET' : 'NOT SET')
      console.log('- Connection String:', connectionString.includes('mongodb+srv://') ? 'MongoDB Atlas' : 'Local MongoDB')
      console.log('- Database:', options.db)
      
      // MongoDB 4.x connection options
      const clientOptions = {
        writeConcern: options.dbParameters(),
        serverSelectionTimeoutMS: 30000,
        connectTimeoutMS: 30000,
        socketTimeoutMS: 30000,
        maxPoolSize: 10,
        retryWrites: true
      }

      const client = new MongoClient(connectionString, clientOptions)
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

module.exports = Object.assign({}, {connect})

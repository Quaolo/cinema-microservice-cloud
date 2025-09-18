const fs = require('fs')
const path = require('path')

// Check if SSL files exist, otherwise return null
const sslConfig = {}

try {
  const keyPath = path.join(__dirname, 'server.key')
  const certPath = path.join(__dirname, 'server.crt')
  
  if (fs.existsSync(keyPath) && fs.existsSync(certPath)) {
    sslConfig.key = fs.readFileSync(keyPath)
    sslConfig.cert = fs.readFileSync(certPath)
    console.log('SSL certificates loaded successfully')
  } else {
    console.log('SSL certificates not found, running without SSL')
    sslConfig.key = null
    sslConfig.cert = null
  }
} catch (error) {
  console.log('Error loading SSL certificates:', error.message)
  sslConfig.key = null
  sslConfig.cert = null
}

module.exports = sslConfig

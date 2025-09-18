const fs = require('fs')
const path = require('path')

// Check if SSL files exist, otherwise return null
const sslConfig = {}

try {
  const keyPath = path.join(__dirname, 'server.key')
  const certPath = path.join(__dirname, 'server.crt')
  
  // Forza HTTP per compatibilità con ALB
  console.log('Forcing HTTP mode for ALB compatibility')
  sslConfig.key = null
  sslConfig.cert = null
} catch (error) {
  console.log('Error loading SSL certificates:', error.message)
  sslConfig.key = null
  sslConfig.cert = null
}

module.exports = sslConfig

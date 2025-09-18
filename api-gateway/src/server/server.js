'use strict'
const express = require('express')
const { createProxyMiddleware } = require('http-proxy-middleware')
const spdy = require('spdy')

const start = (container) => {
  return new Promise((resolve, reject) => {
    const {port, ssl} = container.resolve('serverSettings')
    const routes = container.resolve('routes')

    if (!routes) {
      reject(new Error('The server must be started with routes discovered'))
    }
    if (!port) {
      reject(new Error('The server must be started with an available port'))
    }

    const app = express()

    // Health check endpoint - more robust
    app.get('/health', (req, res) => {
      try {
        const routes = container.resolve('routes')
        const serviceCount = routes ? Object.keys(routes).length : 0
        
        res.status(200).json({ 
          status: 'OK', 
          service: 'api-gateway',
          routes: serviceCount,
          timestamp: new Date().toISOString()
        })
      } catch (error) {
        // Fallback se le routes non sono ancora disponibili
        res.status(200).json({ 
          status: 'STARTING', 
          service: 'api-gateway',
          routes: 0,
          message: 'Service is starting up...',
          timestamp: new Date().toISOString()
        })
      }
    })

    // Debug endpoint per vedere le route configurate
    app.get('/debug/routes', (req, res) => {
      try {
        const routes = container.resolve('routes')
        res.status(200).json({
          status: 'OK',
          routes: routes || {},
          timestamp: new Date().toISOString()
        })
      } catch (error) {
        res.status(500).json({
          error: 'Internal Server Error',
          message: error.message,
          timestamp: new Date().toISOString()
        })
      }
    })

    // Aggiungi routes solo se disponibili
    if (routes && typeof routes === 'object') {
      for (let id of Reflect.ownKeys(routes)) {
        const {route, target} = routes[id]
        if (route && target) {
          console.log(`Setting up route: ${route} -> ${target}`)
          app.use(route, createProxyMiddleware({
            target,
            changeOrigin: true,
            logLevel: 'debug',
            onError: (err, req, res) => {
              console.error(`Proxy error for ${route}:`, err.message)
              res.status(502).json({
                error: 'Bad Gateway',
                message: `Service ${id} is not available`,
                target: target,
                timestamp: new Date().toISOString()
              })
            },
            onProxyReq: (proxyReq, req, res) => {
              console.log(`Proxying ${req.method} ${req.url} to ${target}`)
            }
          }))
        }
      }
    } else {
      // Fallback: aggiungi route di default per indicare che il servizio è in avvio
      app.get('*', (req, res) => {
        res.status(503).json({
          status: 'SERVICE_UNAVAILABLE',
          message: 'API Gateway is starting up. Please try again in a few moments.',
          timestamp: new Date().toISOString()
        })
      })
    }

    console.log(`Starting server on port ${port}...`)
    
    if (process.env.NODE === 'test') {
      console.log('Starting in test mode')
      const server = app.listen(port, () => {
        console.log(`Test server listening on port ${port}`)
        resolve(server)
      })
    } else if (ssl && ssl.key && ssl.cert) {
      // Use SPDY/HTTPS only if SSL certificates are available
      console.log('Starting HTTPS server with SSL certificates')
      const server = spdy.createServer(ssl, app)
        .listen(port, () => {
          console.log(`HTTPS server listening on port ${port}`)
          resolve(server)
        })
    } else {
      // Use HTTP if no SSL certificates
      console.log('No SSL certificates found, starting HTTP server')
      const server = app.listen(port, (err) => {
        if (err) {
          console.error('Error starting HTTP server:', err)
          reject(err)
        } else {
          console.log(`HTTP server listening on port ${port}`)
          resolve(server)
        }
      })
      
      server.on('error', (err) => {
        console.error('HTTP server error:', err)
        reject(err)
      })
    }
  })
}

module.exports = Object.assign({}, {start})

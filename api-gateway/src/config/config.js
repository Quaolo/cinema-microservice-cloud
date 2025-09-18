const serverSettings = {
  port: process.env.PORT || 8080,
  ssl: require('./ssl')
}

// ECS Service Discovery - Static configuration
const ecsSettings = {
  services: {
    'booking-service': {
      id: 'booking-service',
      route: '/bookings',
      target: process.env.BOOKING_SERVICE_URL || 'http://booking-service.cinema-cluster.local:3003'
    },
    'cinema-catalog-service': {
      id: 'cinema-catalog-service', 
      route: '/cinemas',
      target: process.env.CINEMA_CATALOG_SERVICE_URL || 'http://cinema-catalog-service.cinema-cluster.local:3001'
    },
    'movies-service': {
      id: 'movies-service',
      route: '/movies', 
      target: process.env.MOVIES_SERVICE_URL || 'http://movies-service.cinema-cluster.local:3000'
    },
    'notification-service': {
      id: 'notification-service',
      route: '/notifications',
      target: process.env.NOTIFICATION_SERVICE_URL || 'http://notification-service.cinema-cluster.local:3004'
    },
    'payment-service': {
      id: 'payment-service',
      route: '/payments',
      target: process.env.PAYMENT_SERVICE_URL || 'http://payment-service.cinema-cluster.local:3002'
    }
  }
}

module.exports = Object.assign({}, { serverSettings, ecsSettings })
